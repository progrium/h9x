//! `--print` (design/prototype.md, "Policy"): the policy of each machine a
//! command would start, as h9 plan text, and nothing started.
//!
//! It fetches nothing, makes no root, and runs no planner, so what a build
//! decides later is shown by the path it would have: the builder and base
//! roots for the default package sets (the plan's apt packages can add to
//! them), a remote source's tree as `$cache/sources/tree/COMMIT`, and the
//! output's layers by name. A remote source's own h9x.toml isn't known
//! before it's fetched, so its lines are the defaults, the user's config,
//! and the environment's; the source's file can only narrow them. When
//! SOURCE is a build's output, or a directory source has one where `build`
//! writes it, the run stage is shown with its real layers.
//!
//! Without `--json`, each policy follows a `# PHASE` comment line; with it,
//! each is a `policy` event.

const std = @import("std");
const cli = @import("../cli.zig");
const types = @import("../types.zig");
const config = @import("../config.zig");
const policy = @import("../policy.zig");
const source = @import("../source.zig");
const roots = @import("../roots.zig");
const artifact = @import("../artifact.zig");
const session = @import("../session.zig");
const build = @import("build.zig");
const input = @import("input.zig");
const run_cmd = @import("run.zig");
const shell_cmd = @import("shell.zig");

pub const Request = struct {
    pub const Command = enum { build, plan, run, shell };
    source: []const u8,
    command: Command,
    out: ?[]const u8 = null,
    run: cli.RunOptions = .{},
    shell: cli.ShellOptions = .{},
};

pub fn phases(ctx: *cli.Context, req: Request) !u8 {
    const a = ctx.arena;
    const io = ctx.io;
    const run_stage = req.command == .run or (req.command == .shell and req.shell.stage == .run);

    // Every policy is worked out before any is printed, so a widening
    // flag is exit 2 with nothing on stdout.
    var out_list: List = .{};

    // A build's output given by path: only its run stage starts.
    if (run_stage) if (try input.output(ctx, req.source)) |in| {
        try out_list.add(a, try runPolicy(ctx, req, in.cfg, .trusted, in.base, in.layers, in.art), null);
        return out_list.flush(ctx);
    };

    const spec = source.parse(a, req.source) catch |e| switch (e) {
        error.BadSource => return ctx.events.failErr(error.BadSource, "{s}: {s}", .{ req.source, source.why }),
        error.OutOfMemory => return e,
    };
    var dir: ?[]const u8 = null;
    if (spec == .dir) dir = std.Io.Dir.cwd().realPathFileAlloc(io, spec.dir, a) catch
        return ctx.events.failErr(error.BadSource, "{s}: no such directory", .{req.source});
    const remote = dir == null;
    var diag: config.Diag = .{};
    const cfg = config.loadFrom(a, io, ctx.env, dir, &diag) catch |e| switch (e) {
        error.Config => return ctx.events.failErr(error.BadConfig, "{f}", .{diag}),
        else => |x| return x,
    };
    var env = try roots.Env.init(ctx, cfg);
    env.trust = if (remote) .untrusted else .trusted;

    // Where things would be.
    const builder = try env.path(.roots, try std.fmt.allocPrint(a, "builder-{s}", .{try roots.rootKey(a, env.arch, try roots.packagesFor(env, .builder, &.{}))}));
    const base = try env.path(.roots, try std.fmt.allocPrint(a, "base-{s}", .{try roots.rootKey(a, env.arch, try roots.packagesFor(env, .base, &.{}))}));
    const tools = try env.path(.tools, "");
    const guest_dir = try roots.guestPath(env);
    const name: []const u8, const src_path: []const u8 = switch (spec) {
        .dir => .{ std.fs.path.basename(dir.?), dir.? },
        .git => |g| .{ g.name, try env.path(.sources, "tree/COMMIT") },
        .tarball => |t| .{ t.name, try env.path(.sources, "tree/SHA256") },
    };
    const out = (try build.defaultOut(ctx, req.source, req.out)) orelse try env.path(.builds, "KEY");
    const layer_dir = struct {
        fn f(ar: std.mem.Allocator, o: []const u8, l: types.LayerName) ![]const u8 {
            return std.fs.path.join(ar, &.{ o, "layers", @tagName(l) });
        }
    }.f;

    // Fetching a remote source.
    switch (spec) {
        .dir => {},
        inline .git, .tarball => |s| {
            const p = try source.fetchPolicy(a, builder, try env.path(.sources, "WORK"), .{ .host = s.host, .port = s.port }, env.host.https_proxy);
            try out_list.add(a, p, null);
        },
    }

    if (req.command != .run or !run_stage or try outputAt(ctx, out) == null) {
        // The plan: Railpack on the builder root, as plan.zig mounts it.
        const src_dst = try std.fmt.allocPrint(a, "/h9x/src/{s}", .{name});
        const pp = try env.policyFor(.{
            .phase = .plan,
            .trust = env.trust,
            .machine = .{
                .mounts = &.{
                    .{ .kind = .dir, .src = builder, .dst = "#L", .access = .ro },
                    .{ .kind = .dir, .src = tools, .dst = "/h9x/tools", .access = .ro },
                    .{ .kind = .dir, .src = std.fs.path.dirname(try roots.railpackPath(env)) orelse "/", .dst = "/h9x/railpack", .access = .ro },
                    .{ .kind = .dir, .src = src_path, .dst = src_dst, .access = .ro },
                    .{ .kind = .tmp, .dst = "/tmp" },
                },
                .env = &.{
                    .{ .name = "HOME", .value = "/root" },
                    .{ .name = "H9X_SRC", .value = src_dst },
                },
                .netallow_add = try env.proxyAllow(),
            },
        });
        try out_list.add(a, pp, "the plan, in a machine that writes plan.json into the output directory");

        if (req.command != .plan) {
            // The build of the app layer, the one with every layer below it.
            const bp = try env.policyFor(.{
                .phase = .build,
                .trust = env.trust,
                .machine = .{
                    .mounts = &.{
                        .{ .kind = .dir, .src = builder, .dst = "#L", .access = .ro },
                        .{ .kind = .dir, .src = tools, .dst = "/h9x/tools", .access = .ro },
                        .{ .kind = .dir, .src = guest_dir, .dst = "/h9x/guest", .access = .ro },
                        .{ .kind = .dir, .src = src_path, .dst = src_dst, .access = .ro },
                        .{ .kind = .dir, .src = try env.path(.runtimes, "KEY"), .dst = "#L", .access = .ro },
                        .{ .kind = .dir, .src = try layer_dir(a, out, .deps), .dst = "#L", .access = .ro },
                        .{ .kind = .dir, .src = try std.fmt.allocPrint(a, "{s}.tmp", .{try layer_dir(a, out, .app)}), .dst = "#L", .access = .up },
                        .{ .kind = .tmp, .dst = "/tmp" },
                    },
                    .env = &.{
                        .{ .name = "HOME", .value = "/root" },
                        .{ .name = "H9X_SRC", .value = src_dst },
                    },
                    .netallow_add = try env.proxyAllow(),
                },
                .secrets = ctx.common.secrets,
            });
            try out_list.add(a, bp, "a layer's build; the runtime and deps layers' have fewer layers below them");
        }
    }

    switch (req.command) {
        .build, .plan => {},
        .run => {
            if (try outputAt(ctx, out)) |in| {
                try out_list.add(a, try runPolicy(ctx, req, cfg, env.trust, in.base, in.layers, in.art), null);
            } else {
                const layers = [_]types.Layer{
                    .{ .name = .runtime, .key = "", .path = try env.path(.runtimes, "KEY") },
                    .{ .name = .deps, .key = "", .path = try layer_dir(a, out, .deps) },
                    .{ .name = .app, .key = "", .path = try layer_dir(a, out, .app) },
                };
                const art: types.Artifact = .{ .arch = env.arch, .base = .{ .path = base, .packages = &.{} }, .layers = &layers, .env = &.{"PATH=…"}, .start = "START" };
                try out_list.add(a, try runPolicy(ctx, req, cfg, env.trust, base, &layers, art), "the run, with the layers layers.txt names; env and START are the plan's");
            }
        },
        .shell => if (req.shell.stage == .run) {
            const in = try outputAt(ctx, out);
            const layers: []const types.Layer = if (in) |i| i.layers else &.{};
            const art: types.Artifact = if (in) |i| i.art else .{ .arch = env.arch, .base = .{ .path = base, .packages = &.{} }, .layers = &.{}, .env = &.{}, .start = null };
            try out_list.add(a, try runPolicy(ctx, req, cfg, env.trust, if (in) |i| i.base else base, layers, art), null);
        } else {
            const p = try shell_cmd.policyFrom(env, .{
                .builder = builder,
                .tools = tools,
                .guest_dir = guest_dir,
                .source = src_path,
                .remote = remote,
                .lowers = &.{ try env.path(.runtimes, "KEY"), try layer_dir(a, out, .deps) },
                .scratch = try std.fs.path.join(a, &.{ out, "scratch-ID" }),
                .out = out,
                .argv = req.shell.argv,
            });
            try out_list.items.append(a, .{ p, null, try shell_cmd.extraText(a, src_path, remote, out) });
        },
    }
    return out_list.flush(ctx);
}

const List = struct {
    /// Each policy, a note for its header line, and lines after it.
    items: std.ArrayList(struct { types.Policy, ?[]const u8, []const u8 }) = .empty,

    fn add(l: *List, a: std.mem.Allocator, p: types.Policy, note: ?[]const u8) !void {
        try l.items.append(a, .{ p, note, "" });
    }

    fn flush(l: *List, ctx: *cli.Context) !u8 {
        for (l.items.items) |it| try emit(ctx, it[0], it[1], it[2]);
        return 0;
    }
};

/// The build's output at `out`, if one is there.
fn outputAt(ctx: *cli.Context, out: []const u8) !?input.Input {
    if (artifact.read(ctx.arena, ctx.io, out)) |_| {} else |_| return null;
    return input.output(ctx, out);
}

fn runPolicy(
    ctx: *cli.Context,
    req: Request,
    cfg: config.Config,
    trust: types.Trust,
    base: []const u8,
    layers: []const types.Layer,
    art: types.Artifact,
) !types.Policy {
    var opts = req.run;
    var t = trust;
    if (req.command == .shell) {
        opts = .{ .argv = if (req.shell.argv.len > 0) req.shell.argv else &.{"/bin/sh"} };
    } else t = run_cmd.trustFor(ctx, cfg, req.source, t == .untrusted, opts.trust);
    return run_cmd.policyFor(ctx, cfg, t, try session.runDelta(ctx.arena, base, layers, art.env, art.cwd), opts, art.start);
}

fn emit(ctx: *cli.Context, p: types.Policy, note: ?[]const u8, tail: []const u8) !void {
    const text = try std.mem.concat(ctx.arena, u8, &.{ try policy.toText(ctx.arena, p), tail });
    if (ctx.common.json) {
        ctx.events.emit(.{ .policy = .{ .phase = p.phase, .text = text } });
        return;
    }
    try ctx.stdout.print("# {t}, {t}", .{ p.phase, p.trust });
    if (note) |n| try ctx.stdout.print(": {s}", .{n});
    try ctx.stdout.print("\n{s}\n", .{text});
}
