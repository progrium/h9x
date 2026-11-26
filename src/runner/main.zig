//! h9x-runner: the program a packed executable starts as
//! (design/prototype.md, "Packs"). It reads the trailer from its own file
//! and the pack's index and pack.json through it, extracts the pack once
//! into `${XDG_CACHE_HOME:-~/.cache}/h9x/packs/DIGEST` after checking its
//! seal, and runs `/.h9x/run` with its own arguments, under the policy
//! sealed in pack.json, the extracted tree read-only with writes to an
//! overlay thrown away at exit.
//!
//! It reads one variable of its own, `H9X_PACK`: `info` prints the pack's
//! digest, layers, and policy, and `shell` opens a shell in it, unless the
//! pack was made with `--no-debug`. `H9X_PACK_NET` narrows the sealed
//! `net`; nothing widens it. As `h9x` does, it takes `H9X_BACKEND`, and
//! passes the host's proxy and `SSL_CERT_FILE` into the guest.
//!
//! A run that finds `packs/DIGEST` reads pack.json from it, the copy that
//! was checked, so it neither hashes the pack again nor trusts what's in
//! the executable now beyond the digest that names it.
//!
//! Owned by W8.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const h9 = @import("h9");
const h9x = @import("h9x");
const Stdin = @import("h9_stdin").Stdin;
const pack = h9x.pack;
const policy = h9x.policy;
const machine = h9x.machine;
const Exit = h9x.types.Exit;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;
    var err_buf: [1024]u8 = undefined;
    var err_w = Io.File.stderr().writerStreaming(io, &err_buf);
    const err = &err_w.interface;
    defer err.flush() catch {};

    const r = run(init, arena, io, env, err) catch |e| {
        err.print("h9x-runner: {t}\n", .{e}) catch {};
        return Exit.setup.code();
    };
    return r;
}

fn fail(err: *Io.Writer, code: Exit, comptime fmt: []const u8, args: anytype) u8 {
    err.print("h9x-runner: " ++ fmt ++ "\n", args) catch {};
    return code.code();
}

fn run(init: std.process.Init, arena: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, err: *Io.Writer) !u8 {
    const args = try init.minimal.args.toSlice(arena);
    const self = try std.process.executablePathAlloc(io, arena);
    const file = try Io.Dir.cwd().openFile(io, self, .{});
    defer file.close(io);
    const t = h9x.trailer.read(io, file) catch null orelse
        return fail(err, .setup, "no pack in {s}", .{self});
    const p = pack.open(arena, io, file, t.offset, t.length) catch |e|
        return fail(err, .setup, "the pack in {s} is damaged: {t}", .{ self, e });

    const mode: Mode = m: {
        const v = env.get("H9X_PACK") orelse break :m .app;
        if (!p.pack.debug or v.len == 0) break :m .app;
        break :m std.meta.stringToEnum(Mode, v) orelse
            return fail(err, .usage, "H9X_PACK={s}: want info or shell", .{v});
    };
    if (mode == .info) return info(io, file, p);

    // Extract once, after checking the seal.
    const hex = pack.digestHex(p.pack.digest);
    const cwd_dir = Io.Dir.cwd();
    // Its real path: h9 refuses a host path through a symlink, and on
    // macOS a temporary HOME is under /var, which is one.
    const state = s: {
        const s = try cacheDir(arena, env);
        try cwd_dir.createDirPath(io, s);
        break :s cwd_dir.realPathFileAlloc(io, s, arena) catch s;
    };
    const packs = try std.fs.path.join(arena, &.{ state, "packs" });
    const root = try std.fs.path.join(arena, &.{ packs, hex });
    const have = if (cwd_dir.access(io, try std.fs.path.join(arena, &.{ root, pack.json_path }), .{})) true else |_| false;
    if (!have) {
        if (!try pack.verify(io, file, p))
            return fail(err, .setup, "the pack in {s} doesn't match its digest {s}: it was changed after it was made", .{ self, p.pack.digest });
        try cwd_dir.createDirPath(io, packs);
        var rand: [6]u8 = undefined;
        io.random(&rand);
        const tmp = try std.fmt.allocPrint(arena, "{s}/.{s}.{x}.tmp", .{ packs, hex, &rand });
        try cwd_dir.createDirPath(io, tmp);
        errdefer cwd_dir.deleteTree(io, tmp) catch {};
        {
            var d = try cwd_dir.openDir(io, tmp, .{});
            defer d.close(io);
            try pack.extract(init.gpa, io, file, p, d);
        }
        cwd_dir.rename(tmp, cwd_dir, root, io) catch |e| switch (e) {
            // Another run extracted it first.
            error.DirNotEmpty => cwd_dir.deleteTree(io, tmp) catch {},
            else => |x| return x,
        };
    } else {
        cwd_dir.setTimestamps(io, root, .{ .modify_timestamp = .now }) catch {};
    }
    // The checked copy's pack.json.
    const json_file = try std.fs.path.join(arena, &.{ root, pack.json_path });
    const pj = try pack.parseJson(arena, try cwd_dir.readFileAlloc(io, json_file, arena, .limited(1 << 20)));

    const cwd = try std.process.currentPathAlloc(io, arena);
    var diag: policy.Diag = .{};
    const pol = pack.runPolicy(arena, pj, .{ .root = root, .cwd = cwd, .net = env.get("H9X_PACK_NET") }, &diag) catch |e| switch (e) {
        error.Syntax, error.Widens => return fail(err, .usage, "{s}", .{diag.msg}),
        error.OutOfMemory => return e,
    };
    var opts = policy.compile(arena, pol, &diag) catch |e| switch (e) {
        error.Conflict => return fail(err, .usage, "{s}", .{diag.msg}),
        error.OutOfMemory => return e,
    };
    if (mode == .shell) {
        var e: std.ArrayList(h9.EnvVar) = .empty;
        try e.appendSlice(arena, opts.env);
        try e.append(arena, .{ .name = "H9X_PACK", .value = "shell" });
        opts.env = e.items;
    }
    opts.guest_tools = false;
    opts.console_tty = (Io.File.stdin().isTty(io) catch false) and (Io.File.stdout().isTty(io) catch false);

    const host = machine.Host.init(arena, io, env, state) catch |e| switch (e) {
        error.BadBackend => return fail(err, .usage, "H9X_BACKEND={s}: not a backend h9 has", .{env.get("H9X_BACKEND").?}),
        else => |x| return x,
    };

    var in_buf: [4096]u8 = undefined;
    var in: Stdin = undefined;
    in.init(io, &in_buf);
    var out = Io.File.stdout().writerStreaming(io, &.{});
    var err_unbuf = Io.File.stderr().writerStreaming(io, &.{});
    try err.flush();
    opts.stdio = .{
        .in = in.reader(),
        .in_cancel = .{ .ctx = &in, .func = Stdin.cancel, .reset = Stdin.reset },
        .out = &out.interface,
        .err = &err_unbuf.interface,
    };

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "/bin/sh", "/" ++ pack.run_path });
    if (args.len > 1) try argv.appendSlice(arena, args[1..]);
    var m = h9.Machine.init(init.gpa, io, try host.options(arena, opts)) catch |e|
        return fail(err, .setup, "starting a machine: {t}", .{e});
    defer m.deinit();
    const status = m.run(.{ .guest = argv.items[0] }, argv.items) catch |e|
        return fail(err, .setup, "{s}", .{if (m.err_msg.len > 0) m.err_msg else @errorName(e)});
    return machine.exitCode(status);
}

const Mode = enum { app, info, shell };

/// `H9X_PACK=info`: the pack's digest and whether its bytes still match
/// it, its layers, start command, and sealed policy.
fn info(io: Io, file: Io.File, p: pack.Opened) !u8 {
    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writerStreaming(io, &buf);
    const o = &w.interface;
    defer o.flush() catch {};
    const sealed = try pack.verify(io, file, p);
    const pj = p.pack;
    try o.print("digest  {s} ({s})\n", .{ pj.digest, if (sealed) "sealed" else "CHANGED since it was made" });
    try o.print("arch    {t}\nsize    {d}\n", .{ pj.arch, p.len });
    for (pj.layers) |l| try o.print("layer   {t} {s}\n", .{ l.name, l.key });
    try o.print("cwd     {s}\nstart   {s}\n", .{ pj.cwd, pj.start orelse "(none)" });
    for (pj.env) |e| try o.print("env     {s}\n", .{e});
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, pj.policy, "\n"), '\n');
    while (lines.next()) |l| try o.print("policy  {s}\n", .{l});
    return if (sealed) 0 else Exit.failed.code();
}

/// `${XDG_CACHE_HOME:-~/.cache}/h9x`, or `%LOCALAPPDATA%\h9x` on
/// Windows: packs are extracted into its `packs/`.
fn cacheDir(arena: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("XDG_CACHE_HOME")) |x| if (x.len > 0) return std.fs.path.join(arena, &.{ x, "h9x" });
    if (builtin.os.tag == .windows) if (env.get("LOCALAPPDATA")) |l| return std.fs.path.join(arena, &.{ l, "h9x" });
    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse return error.NoHome;
    return std.fs.path.join(arena, &.{ home, ".cache", "h9x" });
}

test cacheDir {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/me");
    try std.testing.expectEqualStrings("/home/me/.cache/h9x", try cacheDir(a.allocator(), &env));
    try env.put("XDG_CACHE_HOME", "/x");
    try std.testing.expectEqualStrings("/x/h9x", try cacheDir(a.allocator(), &env));
}

test {
    _ = &h9.Machine.init;
    _ = &h9.Machine.run;
}
