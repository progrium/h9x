//! `h9x build`: write the output directory, `NAME.h9` in the cwd for a
//! directory source and `$cache/builds/KEY` for a remote one.
//!
//! `build` is the engine end to end, for `run`, `shell`, `pack`, and
//! `export` to call too: the source, its config, the bootstrap and the
//! builder root, the plan (kept, or Railpack in a machine), the roots with
//! the plan's apt packages, the layers, and the artifact.

const std = @import("std");
const build_options = @import("build_options");
const cli = @import("../cli.zig");
const types = @import("../types.zig");
const cache = @import("../cache.zig");
const config = @import("../config.zig");
const source = @import("../source.zig");
const policy = @import("../policy.zig");
const plan = @import("../plan.zig");
const wolfi = @import("../wolfi.zig");
const roots = @import("../roots.zig");
const layers = @import("../layers.zig");
const artifact = @import("../artifact.zig");

const Dir = std.Io.Dir;

pub fn run(ctx: *cli.Context, opts: cli.BuildOptions) !u8 {
    if (ctx.common.print) return @import("print.zig").phases(ctx, .{ .source = opts.source, .command = .build, .out = opts.out });
    if (opts.poc) ctx.events.log("warning: h9x [-o OUT] DIR is deprecated; use h9x build DIR [-o OUT]", .{});
    const r = try build(ctx, .{ .source = opts.source, .out = opts.out, .replan = opts.replan });
    ctx.result_out = r.out;
    return 0;
}

pub const Options = struct {
    source: []const u8 = ".",
    /// The output directory; null for the default.
    out: ?[]const u8 = null,
    /// Plan again even when the source hasn't changed.
    replan: bool = false,
    /// The source, already resolved, for the library: `source` is then
    /// only its spec.
    resolved: ?types.Source = null,
    /// Without `out`, write to `$cache/builds/KEY` for a directory source
    /// too, rather than `NAME.h9` in the cwd: the library's default.
    cache_out: bool = false,
};

pub const Result = struct {
    /// The output directory, absolute.
    out: []const u8,
    source: types.Source,
    artifact: types.Artifact,
    env: roots.Env,
    plan: types.Plan,
    /// The builder root the layers were built on, for `shell`.
    builder: types.Root,
    /// Every layer, built or kept, bottom first, with absolute paths.
    all: [3]types.Layer,
};

/// The builder root for fetching a remote source, before the source's
/// own config is known: the default package set.
fn fetchBuilder(ctx: *cli.Context) anyerror![]const u8 {
    var e = try roots.Env.init(ctx, .{});
    e.cfg.railpack = null;
    const boot = try roots.bootstrap(e);
    const b = try roots.make(e, boot, .builder, try roots.packagesFor(e, .builder, &.{}));
    return b.path;
}

pub fn build(ctx: *cli.Context, o: Options) !Result {
    const pr = try prepare(ctx, o);
    return finish(pr);
}

/// What a build has made by the time it has a plan: the source, its
/// config, the output directory, the roots, and the plan. `h9x plan` stops
/// here; `build` goes on with `finish`.
pub const Prepared = struct {
    ctx: *cli.Context,
    /// The output directory, absolute.
    out: []const u8,
    cache_dir: []const u8,
    source: types.Source,
    env: roots.Env,
    boot: roots.Bootstrap,
    builder: types.Root,
    tools: []const u8,
    guest_dir: []const u8,
    /// A guest path under the source to hide: the output directory, when
    /// it's inside the source.
    hide: ?[]const u8,
    plan: types.Plan,
};

/// The output directory a build of `spec` writes, when it can be known
/// without fetching: `-o`'s, or `NAME.h9` in the cwd for a directory.
/// Null for a remote source without `-o`, whose output is keyed by what
/// it fetches.
pub fn defaultOut(ctx: *cli.Context, spec: []const u8, given: ?[]const u8) !?[]const u8 {
    const a = ctx.arena;
    const io = ctx.io;
    if (given) |x| return try absolute(a, io, x);
    const parsed = source.parse(a, spec) catch null;
    if (parsed == null or parsed.? == .dir) {
        if (Dir.cwd().realPathFileAlloc(io, spec, a)) |abs| {
            return try absolute(a, io, try std.fmt.allocPrint(a, "{s}.h9", .{std.fs.path.basename(abs)}));
        } else |_| {}
    }
    return null;
}

pub fn prepare(ctx: *cli.Context, o: Options) !Prepared {
    const a = ctx.arena;
    const io = ctx.io;
    const cwd = Dir.cwd();
    const cache_dir = try cache.dir(a, ctx.env);

    // A directory source's output is decided first, so its hash and the
    // build's machines can leave it out when it's inside the source.
    var out: ?[]const u8 = if (o.cache_out and o.out == null) null else try defaultOut(ctx, o.source, o.out);
    const src = if (o.resolved) |r| r else source.resolve(ctx, o.source, .{
        .builder = &fetchBuilder,
        .exclude = if (out) |x| try a.dupe([]const u8, &.{x}) else &.{},
    }) catch |e| return switch (e) {
        error.SourceNotFound => error.BadSource,
        else => e,
    };
    const cfg = config.load(ctx, src) catch |e| return switch (e) {
        error.Config => error.BadConfig,
        else => e,
    };
    var env = try roots.Env.init(ctx, cfg);
    env.trust = if (src.remote()) .untrusted else .trusted;
    if (out == null) {
        const k = try roots.shortHash(a, try std.fmt.allocPrint(a, "build {s} {s}\n", .{ env.arch.linuxName(), src.hash }));
        out = try env.path(.builds, k);
    }
    const out_dir = out.?;
    try cwd.createDirPath(io, out_dir);
    cache.touch(io, out_dir);

    // The output inside the source is hidden from the machines that read
    // the source, and from the plan's keys.
    var ignore: []const []const u8 = &.{};
    var hide: ?[]const u8 = null;
    if (inside(out_dir, src.path)) |rel| {
        ignore = try a.dupe([]const u8, &.{rel});
        hide = try std.fmt.allocPrint(a, "/h9x/src/{s}/{s}", .{ src.name, rel });
    }

    // The bootstrap, Railpack, and the builder root.
    ctx.events.emit(.{ .phase = .{ .phase = .root, .state = .start } });
    const boot = try roots.bootstrap(env);
    const railpack = try roots.railpack(env);
    const tools = try env.path(.tools, "");
    try cwd.createDirPath(io, tools);
    const guest_dir = try roots.guestDir(env);
    var builder = try roots.make(env, boot, .builder, try roots.packagesFor(env, .builder, &.{}));
    ctx.events.emit(.{ .phase = .{ .phase = .root, .state = .done } });

    // The plan: kept, or Railpack's in a machine on the builder root.
    const p = try getPlan(env, .{
        .out = out_dir,
        .src = src,
        .builder = builder.path,
        .tools = tools,
        .railpack = railpack,
        .ignore = ignore,
        .hide = hide,
        .replan = o.replan or cfg.replan,
    });

    // The plan's build packages, as Wolfi packages in the builder root.
    if (p.apt_build.len > 0) {
        ctx.events.log("build packages: {s}", .{try std.mem.join(a, " ", p.apt_build)});
        builder = try roots.make(env, boot, .builder, try roots.packagesFor(env, .builder, try wolfi.names(a, p.apt_build)));
    }
    return .{
        .ctx = ctx,
        .out = out_dir,
        .cache_dir = cache_dir,
        .source = src,
        .env = env,
        .boot = boot,
        .builder = builder,
        .tools = tools,
        .guest_dir = guest_dir,
        .hide = hide,
        .plan = p,
    };
}

/// The rest of a build: the base root with the plan's runtime packages,
/// the layers, and the artifact.
pub fn finish(pr: Prepared) !Result {
    const ctx = pr.ctx;
    const a = ctx.arena;
    const io = ctx.io;
    const env = pr.env;
    const p = pr.plan;
    const out_dir = pr.out;
    const base = try roots.make(env, pr.boot, .base, try roots.packagesFor(env, .base, try wolfi.names(a, p.apt_runtime)));

    ctx.events.emit(.{ .phase = .{ .phase = .build, .state = .start } });
    const built = try layers.build(.{
        .env = env,
        .plan = p,
        .source = pr.source,
        .builder = pr.builder,
        .out = out_dir,
        .tools = pr.tools,
        .guest_dir = pr.guest_dir,
        .hide = pr.hide,
    });
    ctx.events.emit(.{ .phase = .{ .phase = .build, .state = .done } });

    // artifact.json: the base root and the layers the run stacks.
    var stack: std.ArrayList(types.Layer) = .empty;
    for (built.stack) |name| for (built.all) |l| if (l.name == name) {
        try stack.append(a, .{ .name = l.name, .key = l.key, .path = try artifact.storedPath(a, out_dir, pr.cache_dir, l.path) });
    };
    const art: types.Artifact = .{
        .arch = env.arch,
        .base = .{ .path = try artifact.storedPath(a, out_dir, pr.cache_dir, base.path), .packages = base.packages },
        .layers = stack.items,
        .env = built.env,
        .start = p.start,
    };
    try artifact.write(a, io, out_dir, art);
    try artifact.writeRun(a, io, out_dir);
    return .{ .out = out_dir, .source = pr.source, .artifact = art, .env = env, .plan = p, .builder = pr.builder, .all = built.all };
}

/// `p` made absolute against the cwd, without needing it to exist.
fn absolute(a: std.mem.Allocator, io: std.Io, p: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(p)) return std.fs.path.resolve(a, &.{p});
    const here = try Dir.cwd().realPathFileAlloc(io, ".", a);
    return std.fs.path.resolve(a, &.{ here, p });
}

/// `p` relative to `dir`, when it's below it.
fn inside(p: []const u8, dir: []const u8) ?[]const u8 {
    if (p.len > dir.len + 1 and std.mem.startsWith(u8, p, dir) and p[dir.len] == '/') return p[dir.len + 1 ..];
    return null;
}

const PlanInput = struct {
    out: []const u8,
    src: types.Source,
    builder: []const u8,
    tools: []const u8,
    railpack: []const u8,
    ignore: []const []const u8,
    hide: ?[]const u8,
    replan: bool,
};

/// The plan kept in the output under the plan key, or a new one from
/// Railpack, kept for next time.
fn getPlan(env: roots.Env, in: PlanInput) !types.Plan {
    const ctx = env.ctx;
    const a = ctx.arena;
    const io = ctx.io;
    const key = try plan.key(a, env.arch, in.src.hash, try roots.railpackIdentity(env, in.railpack), build_options.version);
    var out = try Dir.cwd().openDir(io, in.out, .{});
    defer out.close(io);
    var src = try Dir.cwd().openDir(io, in.src.path, .{});
    defer src.close(io);

    if (!in.replan) {
        if (plan.load(a, io, out, src, in.ignore, key) catch null) |p| {
            ctx.events.emit(.{ .phase = .{ .phase = .plan, .state = .cached } });
            return p;
        }
    }
    ctx.events.emit(.{ .phase = .{ .phase = .plan, .state = .start } });
    plan.forget(io, out);

    var mounts: std.ArrayList(types.Mount) = .empty;
    if (in.hide) |h| try mounts.append(a, .{ .kind = .tmp, .dst = h });
    const pol = try env.policyFor(.{
        .phase = .plan,
        .trust = env.trust,
        .machine = .{ .mounts = mounts.items, .netallow_add = try env.proxyAllow(), .env = try env.passEnv() },
    });
    var diag: policy.Diag = .{};
    var base = policy.compile(a, pol, &diag) catch |e| switch (e) {
        error.Conflict => {
            ctx.events.log("plan policy: {s}", .{diag.msg});
            return error.PolicyConflict;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    var log: std.Io.Writer.Allocating = .init(a);
    var in_r: std.Io.Reader = .fixed("");
    base.stdio = .{ .in = &in_r, .out = &log.writer, .err = &log.writer };
    base.console_tty = false;
    base.guest_tools = false;
    var status: @import("../machine.zig").Status = undefined;
    var why: []const u8 = "";
    plan.run(ctx.gpa, a, io, env.host, base, .{
        .builder = in.builder,
        .tools = in.tools,
        .railpack = in.railpack,
        .source = in.src,
        .work = in.out,
    }, &status, &why) catch |e| {
        if (log.written().len > 0) ctx.events.emit(.{ .output = .{ .stream = .stderr, .text = log.written() } });
        switch (e) {
            error.Failed => {
                const code = @import("../machine.zig").exitCode(status);
                if (code == 124) return error.Timeout;
                ctx.events.log("railpack plan exited {d}", .{code});
                return error.StepFailed;
            },
            error.NoPlan => {
                ctx.events.log("railpack wrote no plan.json", .{});
                return error.StepFailed;
            },
            else => {
                ctx.events.log("plan: {s}", .{if (why.len > 0) why else @errorName(e)});
                return error.MachineFailed;
            },
        }
    };
    const pj = try out.readFileAlloc(io, "plan.json", a, .limited(64 << 20));
    const info = out.readFileAlloc(io, "info.json", a, .limited(64 << 20)) catch null;
    const p = plan.read(a, io, .{ .plan_json = pj, .info_json = info, .src = src, .key = key, .ignore = in.ignore }) catch |e| switch (e) {
        error.NoSteps => {
            ctx.events.log("Railpack made no build steps for {s}", .{in.src.spec});
            if (info) |i| for (try plan.logs(a, i)) |l| ctx.events.log("railpack: {s}", .{l});
            return error.NoSteps;
        },
        error.BadPlan => {
            ctx.events.log("plan.json: not a plan h9x can read", .{});
            return error.StepFailed;
        },
        else => |x| return x,
    };
    try plan.store(a, io, out, p);
    ctx.events.emit(.{ .phase = .{ .phase = .plan, .state = .done } });
    return p;
}
