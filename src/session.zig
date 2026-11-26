//! Interactive machines (design/prototype.md, "Commands"): the machines
//! `run` and `shell` start, with the terminal's stdin, the program's own
//! stdout, and its stderr as `output` events under `--json`.
//!
//! The build's machines (roots.zig's `guest`) take no stdin and report
//! through events. These are the app's: what the person types goes to the
//! guest, and the guest's exit status is the command's.

const std = @import("std");
const h9 = @import("h9");
const Stdin = @import("h9_stdin").Stdin;
const types = @import("types.zig");
const cli = @import("cli.zig");
const policy = @import("policy.zig");
const machine = @import("machine.zig");

const Io = std.Io;

/// The run stage's machine, without config or flags: the base root and
/// the run layers read-only over it, a tree in memory at /tmp, the run
/// environment, and the app's cwd. Writes go to an overlay that's thrown
/// away, as the run phase's default `write overlay` says.
pub fn runDelta(
    arena: std.mem.Allocator,
    base: []const u8,
    layers: []const types.Layer,
    env_lines: []const []const u8,
    cwd: []const u8,
) error{OutOfMemory}!policy.Delta {
    var mounts: std.ArrayList(types.Mount) = .empty;
    try mounts.append(arena, .{ .kind = .dir, .src = base, .dst = "#L", .access = .ro });
    for (layers) |l| try mounts.append(arena, .{ .kind = .dir, .src = l.path, .dst = "#L", .access = .ro });
    try mounts.append(arena, .{ .kind = .tmp, .dst = "/tmp" });
    return .{ .mounts = mounts.items, .env = try envVars(arena, env_lines), .cwd = cwd };
}

/// `NAME=VALUE` lines as variables, with `HOME=/root` unless they set it.
/// `H9X_START` stays: it's how a shell in the run stage finds the start
/// command.
pub fn envVars(arena: std.mem.Allocator, lines: []const []const u8) error{OutOfMemory}![]const types.EnvVar {
    var out: std.ArrayList(types.EnvVar) = .empty;
    var home = false;
    for (lines) |l| {
        const eq = std.mem.indexOfScalar(u8, l, '=') orelse continue;
        if (eq == 0) continue;
        if (std.mem.eql(u8, l[0..eq], "HOME")) home = true;
        try out.append(arena, .{ .name = l[0..eq], .value = l[eq + 1 ..] });
    }
    if (!home) try out.append(arena, .{ .name = "HOME", .value = "/root" });
    return out.items;
}

/// What runs: the command after `--`, or the start command through
/// `/bin/sh -c`, as Railpack's start commands are shell. Null when there's
/// neither.
pub fn program(arena: std.mem.Allocator, argv: []const []const u8, start: ?[]const u8) error{OutOfMemory}!?[]const []const u8 {
    if (argv.len > 0) return argv;
    const s = start orelse return null;
    return try arena.dupe([]const u8, &.{ "/bin/sh", "-c", s });
}

/// Starts a machine with policy `p` and runs its `run` line, in its `cwd`,
/// with the terminal's stdin. Returns the program's exit code, as h9 maps
/// its status (124 for a timeout). error.MachineFailed, logged, when h9
/// couldn't start it (exit 125); error.PolicyConflict when h9 would refuse
/// the policy (exit 2).
///
/// `host_cwd` is a host directory the guest sees as `/mnt/term/cwd`,
/// writable, as the build's machines have the output directory.
pub fn interactive(ctx: *cli.Context, host: machine.Host, p: types.Policy, host_cwd: ?[]const u8) !u8 {
    return interactiveWith(ctx, host, p, host_cwd, .{});
}

/// What a machine needs beyond its policy's lines: host directories mounted
/// outside the Linux tree, and binds of them into it, run after every
/// mount. `shell` uses them for the source, so it's a one-level union over
/// /app rather than a member of the stack, whose up layer takes every
/// write below it.
pub const Extra = struct {
    mounts: []const h9.Machine.Mount = &.{},
    binds: []const h9.Machine.Bind = &.{},
};

pub fn interactiveWith(ctx: *cli.Context, host: machine.Host, p: types.Policy, host_cwd: ?[]const u8, extra: Extra) !u8 {
    const a = ctx.arena;
    const io = ctx.io;
    var diag: policy.Diag = .{};
    var o = policy.compile(a, p, &diag) catch |e| switch (e) {
        error.Conflict => {
            ctx.events.log("{t} policy: {s}", .{ p.phase, diag.msg });
            return error.PolicyConflict;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    const argv = (try policy.command(a, p, &.{})) orelse {
        ctx.events.log("nothing to run: the plan has no start command; give one after --", .{});
        return error.Usage;
    };
    if (extra.mounts.len > 0) o.mounts = try std.mem.concat(a, h9.Machine.Mount, &.{ o.mounts, extra.mounts });
    if (extra.binds.len > 0) o.binds = try std.mem.concat(a, h9.Machine.Bind, &.{ o.binds, extra.binds });
    o.guest_tools = false;
    o.cwd = host_cwd;
    if (host_cwd != null) o.policy.cwd_writable = true;
    o.console_tty = (Io.File.stdin().isTty(io) catch false) and (Io.File.stdout().isTty(io) catch false);

    var in_buf: [4096]u8 = undefined;
    var in: Stdin = undefined;
    in.init(io, &in_buf);
    // The program's stdout is the command's own; its stderr is raw too,
    // unless --json, where it's `output` events between the others.
    try ctx.stdout.flush();
    var out = Io.File.stdout().writerStreaming(io, &.{});
    var raw_err = Io.File.stderr().writerStreaming(io, &.{});
    var ebuf: [4096]u8 = undefined;
    var ev_err = ctx.events.output(null, null, .stderr, &ebuf);
    const err_w: *Io.Writer = if (ctx.common.json) &ev_err.interface else &raw_err.interface;
    ctx.stderr.flush() catch {};
    o.stdio = .{
        .in = in.reader(),
        .in_cancel = .{ .ctx = &in, .func = Stdin.cancel, .reset = Stdin.reset },
        .out = &out.interface,
        .err = err_w,
    };
    defer err_w.flush() catch {};

    var m = h9.Machine.init(ctx.gpa, io, try host.options(a, o)) catch |e| {
        ctx.events.log("{t}: starting a machine: {t}", .{ p.phase, e });
        return error.MachineFailed;
    };
    defer m.deinit();
    const status = m.run(.{ .guest = argv[0] }, argv) catch |e| {
        ctx.events.log("{t}: {s}", .{ p.phase, if (m.err_msg.len > 0) m.err_msg else @errorName(e) });
        return error.MachineFailed;
    };
    return machine.exitCode(status);
}

test envVars {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const v = try envVars(a.allocator(), &.{ "PATH=/mise/bin:/usr/bin", "H9X_START=node server.js", "junk" });
    try std.testing.expectEqual(@as(usize, 3), v.len);
    try std.testing.expectEqualStrings("node server.js", v[1].value);
    try std.testing.expectEqualStrings("HOME", v[2].name);
}

test program {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const s = (try program(a.allocator(), &.{}, "node server.js")).?;
    try std.testing.expectEqualStrings("-c", s[1]);
    const g = (try program(a.allocator(), &.{ "npm", "test" }, "node server.js")).?;
    try std.testing.expectEqualStrings("npm", g[0]);
    try std.testing.expect(try program(a.allocator(), &.{}, null) == null);
}

test runDelta {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const d = try runDelta(a.allocator(), "/c/roots/base-k", &.{.{ .name = .app, .key = "k", .path = "/o/layers/app" }}, &.{"PATH=/bin"}, "/app");
    try std.testing.expectEqual(@as(usize, 3), d.mounts.len);
    try std.testing.expectEqualStrings("/o/layers/app", d.mounts[1].src);
    try std.testing.expectEqualStrings("/app", d.cwd.?);
}
