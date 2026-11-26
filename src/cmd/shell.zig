//! `h9x shell`: the build stage's layers (or the run stage's, with
//! `--stage run`), the source writable at /app, and a scratch up layer on
//! top, running `sh` or the given command.
//!
//! The build stage is what the app layer's steps run on: the builder root,
//! the runtime layer, and the deps layer, read-only, with every step's
//! variables, PATH, and package manager caches set up by `build.sh shell`,
//! so the project's toolchain is on PATH and `npm install` is warm.
//!
//! The scratch layer is the stack's up layer, and an up layer takes every
//! write to the stack, so the source isn't a member of it. It's mounted
//! outside the Linux tree and bound over /app as a one-level union, before
//! the stack's /app and taking creates: a file the source has is the
//! source's, and edits and new files at /app land in it, while what the
//! deps layer put under /app (`node_modules`, `.venv`) is still there, and
//! changes to it land in the scratch layer. The output directory is bound
//! the same way at /h9x/src, which every root has empty, for build.sh's
//! plan and the package managers' caches. A remote source's tree in the
//! cache is never written, so it's bound read-only and edits to it land in
//! the scratch layer. The scratch layer is removed at exit unless `--keep`
//! (where it was made, in the output directory) or `--keep=DIR`.

const std = @import("std");
const cli = @import("../cli.zig");
const types = @import("../types.zig");
const cache = @import("../cache.zig");
const session = @import("../session.zig");
const build = @import("build.zig");
const input = @import("input.zig");
const run_cmd = @import("run.zig");
const print = @import("print.zig");

const Dir = std.Io.Dir;

pub fn run(ctx: *cli.Context, opts: cli.ShellOptions) !u8 {
    if (ctx.common.print) return print.phases(ctx, .{ .source = opts.source, .command = .shell, .shell = opts });
    return switch (opts.stage) {
        .build => buildStage(ctx, opts),
        .run => runStage(ctx, opts),
    };
}

/// `--stage run`: the run stage, as `h9x run` starts it, with a shell or
/// the given command in place of the start command.
fn runStage(ctx: *cli.Context, opts: cli.ShellOptions) !u8 {
    if (opts.keep != .no) return ctx.events.fail(error.Usage, "--keep is for the build stage: the run stage's writes are thrown away", .{});
    const in = try input.resolve(ctx, opts.source);
    ctx.result_out = in.dir;
    const trust = run_cmd.trustFor(ctx, in.cfg, opts.source, in.remote, false);
    const argv: []const []const u8 = if (opts.argv.len > 0) opts.argv else &.{"/bin/sh"};
    const p = try run_cmd.policyFor(ctx, in.cfg, trust, try session.runDelta(ctx.arena, in.base, in.layers, in.art.env, in.art.cwd), .{ .argv = argv }, in.art.start);
    return session.interactive(ctx, try run_cmd.hostFor(ctx), p, null);
}

fn buildStage(ctx: *cli.Context, opts: cli.ShellOptions) !u8 {
    const a = ctx.arena;
    const io = ctx.io;
    const cwd = Dir.cwd();
    const r = try build.build(ctx, .{ .source = opts.source });
    ctx.result_out = r.out;

    // The scratch layer, in the output directory.
    var nonce: [4]u8 = undefined;
    io.random(&nonce);
    const scratch = try std.fmt.allocPrint(a, "{s}/scratch-{x}", .{ r.out, &nonce });
    try cwd.createDirPath(io, scratch);

    const p = try policy(ctx, r, scratch, opts.argv);
    const code = session.interactiveWith(ctx, try run_cmd.hostFor(ctx), p, null, try extraFor(a, r.source.path, r.source.remote(), r.out)) catch |e| {
        cache.removeTree(io, scratch) catch {};
        return e;
    };
    switch (opts.keep) {
        .no => cache.removeTree(io, scratch) catch {},
        .yes => ctx.events.log("kept the scratch layer: {s}", .{scratch}),
        .dir => |d| {
            const to = try std.fs.path.resolve(a, &.{ try cwd.realPathFileAlloc(io, ".", a), d });
            if (std.fs.path.dirname(to)) |parent| try cwd.createDirPath(io, parent);
            Dir.rename(cwd, scratch, cwd, to, io) catch |e| {
                ctx.events.log("couldn't move the scratch layer to {s}: {t}; it's at {s}", .{ d, e, scratch });
                return code;
            };
            ctx.events.log("kept the scratch layer: {s}", .{to});
        },
    }
    return code;
}

/// The shell phase's policy for a build: the builder root, the tools and
/// guest scripts, the runtime and deps layers read-only, the scratch layer
/// as the up layer, and the source at /app on top.
pub fn policy(ctx: *cli.Context, r: build.Result, scratch: []const u8, argv: []const []const u8) !types.Policy {
    var lowers: std.ArrayList([]const u8) = .empty;
    for (r.all) |l| if (l.name != .app) try lowers.append(ctx.arena, l.path);
    return policyFrom(r.env, .{
        .builder = r.builder.path,
        .tools = try r.env.path(.tools, ""),
        .guest_dir = try @import("../roots.zig").guestDir(r.env),
        .source = r.source.path,
        .remote = r.source.remote(),
        .lowers = lowers.items,
        .scratch = scratch,
        .out = r.out,
        .provider = r.plan.provider,
        .argv = argv,
    });
}

/// What a shell machine runs on, by host path.
pub const Machine = struct {
    builder: []const u8,
    tools: []const u8,
    guest_dir: []const u8,
    source: []const u8,
    remote: bool,
    /// The runtime and deps layers, bottom first.
    lowers: []const []const u8,
    scratch: []const u8,
    /// The build's output directory, where build.sh finds the plan and the
    /// package managers' caches.
    out: []const u8,
    provider: []const u8 = "",
    argv: []const []const u8 = &.{},
};

/// Where the source and the output directory are mounted outside the
/// Linux tree, and where they're bound into it.
pub const src_mount = "/mnt/h9x/src";
pub const work_mount = "/mnt/h9x/work";
pub const work_dst = "/h9x/src";

/// The source and output directory's mounts and binds (see the file's
/// comment).
pub fn extraFor(a: std.mem.Allocator, src: []const u8, remote: bool, out: []const u8) !session.Extra {
    return .{
        .mounts = try a.dupe(@import("h9").Machine.Mount, &.{
            .{ .kind = .dir, .src = src, .dst = src_mount, .access = if (remote) .ro else .rw },
            .{ .kind = .dir, .src = out, .dst = work_mount, .access = .rw },
        }),
        .binds = try a.dupe(@import("h9").Machine.Bind, &.{
            .{ .src = src_mount, .dst = "#L/app", .order = .before, .create = !remote },
            .{ .src = work_mount, .dst = "#L" ++ work_dst, .order = .before, .create = true },
        }),
    };
}

/// `extraFor`'s lines, as comments for `--print`: h9x's policy lines have
/// no bind, and h9's plan format writes these as `bind` lines.
pub fn extraText(a: std.mem.Allocator, src: []const u8, remote: bool, out: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\# and, outside the policy's lines:
        \\#   dir {s} {s} {s}
        \\#   dir rw {s} {s}
        \\#   bind -b{s} {s} '#L/app'
        \\#   bind -bc {s} '#L{s}'
        \\
    , .{ if (remote) "ro" else "rw", src, src_mount, out, work_mount, if (remote) "" else "c", src_mount, work_mount, work_dst });
}

pub fn policyFrom(e: @import("../roots.zig").Env, m: Machine) !types.Policy {
    const a = e.ctx.arena;
    var mounts: std.ArrayList(types.Mount) = .empty;
    try mounts.appendSlice(a, &.{
        .{ .kind = .dir, .src = m.builder, .dst = "#L", .access = .ro },
        .{ .kind = .dir, .src = m.tools, .dst = "/h9x/tools", .access = .ro },
        .{ .kind = .dir, .src = m.guest_dir, .dst = "/h9x/guest", .access = .ro },
    });
    for (m.lowers) |l| try mounts.append(a, .{ .kind = .dir, .src = l, .dst = "#L", .access = .ro });
    try mounts.appendSlice(a, &.{
        .{ .kind = .dir, .src = m.scratch, .dst = "#L", .access = .up },
        .{ .kind = .tmp, .dst = "/tmp" },
    });
    var program: std.ArrayList([]const u8) = .empty;
    try program.appendSlice(a, &.{ "/bin/sh", "/h9x/guest/build.sh", "shell" });
    try program.appendSlice(a, m.argv);
    return e.policyFor(.{
        .phase = .shell,
        .trust = e.trust,
        .providers = if (m.provider.len > 0) try a.dupe([]const u8, &.{m.provider}) else &.{},
        .machine = .{
            .mounts = mounts.items,
            .env = &.{
                .{ .name = "HOME", .value = "/root" },
                .{ .name = "H9X_SRC", .value = "/app" },
                .{ .name = "H9X_WORK", .value = work_dst },
                .{ .name = "TERM", .value = e.ctx.env.get("TERM") orelse "xterm" },
            },
            .netallow_add = try e.proxyAllow(),
            .run = program.items,
        },
    });
}
