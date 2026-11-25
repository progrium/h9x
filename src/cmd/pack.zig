//! `h9x pack`: a pack, or with `--exe` and `--target`, executables; and
//! `pack --inspect FILE`.
//!
//!   h9x pack OUT.h9 [-o FILE]                 a tar, NAME.tar by default
//!   h9x pack OUT.h9 --exe [-o FILE]           an executable for this host
//!   h9x pack OUT.h9 --target LIST|all [-o DIR] one per target, in DIR
//!                                             (dist/), with SHA256SUMS
//!
//! Owned by W8, with `--inspect` from W4.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const cli = @import("../cli.zig");
const types = @import("../types.zig");
const exe = @import("../exe/exe.zig");
const pack = @import("../pack.zig");
const policy = @import("../policy.zig");
const config = @import("../config.zig");
const runners = @import("../runners.zig");
const cache = @import("../cache.zig");
const embedded = @import("../embedded.zig");
const input = @import("input.zig");

pub fn run(ctx: *cli.Context, opts: cli.PackOptions) !u8 {
    if (opts.inspect) |path| return inspect(ctx, path);
    const arena = ctx.arena;
    const io = ctx.io;
    const in = try input.resolve(ctx, opts.source);

    // The sealed policy: the run's, for a local source, with the pack's
    // mounts. A mount's host path stays as given, so `.` is the runner's
    // cwd when the executable runs.
    var mounts: std.ArrayList(types.Mount) = .empty;
    try mounts.appendSlice(arena, opts.mounts);
    if (opts.mounts.len == 0) for (in.cfg.pack.mount) |s| {
        try mounts.append(arena, config.parseMount(s) orelse
            return ctx.events.fail(error.BadConfig, "[pack] mount {s}: want HOST:GUEST[:ro], with GUEST absolute", .{s}));
    };
    const pol = config.policyFor(ctx, in.cfg, .{ .phase = .run, .trust = .trusted, .host_mounts = mounts.items }) catch |e| switch (e) {
        error.Widens => return error.PolicyWidens,
        error.Config => return error.BadConfig,
        error.OutOfMemory => return e,
    };
    const text = try policy.toText(arena, pol);
    if (ctx.common.print) {
        if (ctx.common.json) {
            ctx.events.emit(.{ .policy = .{ .phase = .run, .text = text } });
        } else {
            try ctx.stdout.print("# run, sealed in the pack\n{s}", .{text});
        }
        return 0;
    }

    // What to make: a tar, one executable, or one per target.
    const Mode = enum { tar, one, many };
    var targets: std.ArrayList(types.Target) = .empty;
    const mode: Mode = if (!opts.exe) .tar else if (opts.targets.len == 0 and !opts.all_targets and in.cfg.pack.targets.len == 0 and !in.cfg.pack.all_targets) .one else .many;
    switch (mode) {
        .tar => {},
        .one => try targets.append(arena, runners.hostTarget() orelse
            return ctx.events.fail(error.BadTarget, "--exe: this host isn't one of h9's release targets; give --target", .{})),
        .many => {
            const all = opts.all_targets or (opts.targets.len == 0 and in.cfg.pack.all_targets);
            const list = if (opts.targets.len > 0) opts.targets else in.cfg.pack.targets;
            if (all) {
                for (std.enums.values(types.Target)) |t| if (t.arch() == in.art.arch) try targets.append(arena, t);
            } else for (list) |t| {
                if (t.arch() != in.art.arch)
                    return ctx.events.fail(error.BadTarget, "--target {t}: the layers are {t}, and {t} runs {t}", .{ t, in.art.arch, t, t.arch() });
                for (targets.items) |have| {
                    if (have == t) break;
                } else try targets.append(arena, t);
            }
        },
    }
    // Each target's runner, before anything is written. A bare
    // `--runner FILE` must be one of the targets'.
    for (opts.runners) |v| {
        const g = runners.Given.parse(v);
        if (g.target != null) continue;
        const bytes = try readRunner(ctx, g.path);
        for (targets.items) |t| {
            if (runners.matches(bytes, t)) break;
        } else return ctx.events.fail(error.BadTarget, "--runner {s}: not a runner for any target asked for", .{g.path});
    }
    const runner_bytes = try arena.alloc([]const u8, targets.items.len);
    for (targets.items, runner_bytes) |t, *b| b.* = try runnerFor(ctx, opts, t);

    const cwd = Io.Dir.cwd();
    const pack_opts: pack.Options = .{ .policy = text, .debug = !opts.no_debug };
    const pin: pack.Input = .{
        .arch = in.art.arch,
        .base = in.base,
        .layers = try packLayers(arena, in.layers),
        .env = in.art.env,
        .start = in.art.start,
        .cwd = in.art.cwd,
    };

    if (mode == .tar) {
        const out = opts.out orelse try std.fmt.allocPrint(arena, "{s}.tar", .{in.name});
        const tmp = try tmpName(arena, io, out);
        const f = try cwd.createFile(io, tmp, .{ .read = true });
        var keep = false;
        defer if (!keep) cwd.deleteFile(io, tmp) catch {};
        const r = blk: {
            defer f.close(io);
            break :blk try pack.write(ctx.gpa, io, pin, pack_opts, f);
        };
        try cwd.rename(tmp, cwd, out, io);
        keep = true;
        ctx.events.log("wrote {s}: {s}, {d} bytes", .{ out, &r.digest, r.size });
        return 0;
    }

    // Executables: the tar once, beside them, then each target's.
    const out_dir: []const u8 = switch (mode) {
        .one => std.fs.path.dirname(opts.out orelse ".") orelse ".",
        else => opts.out orelse "dist",
    };
    try cwd.createDirPath(io, out_dir);
    const tar_tmp = try tmpName(arena, io, try std.fs.path.join(arena, &.{ out_dir, in.name }));
    const tf = try cwd.createFile(io, tar_tmp, .{ .read = true });
    defer {
        tf.close(io);
        cwd.deleteFile(io, tar_tmp) catch {};
    }
    const r = try pack.write(ctx.gpa, io, pin, pack_opts, tf);

    var sums: std.ArrayList(u8) = .empty;
    var written: std.ArrayList([2][]const u8) = .empty;
    for (targets.items, runner_bytes) |t, runner| {
        const ext = if (t.container() == .pe) ".exe" else "";
        const path = switch (mode) {
            .one => opts.out orelse try std.fmt.allocPrint(arena, "{s}{s}", .{ in.name, ext }),
            else => try std.fmt.allocPrint(arena, "{s}/{s}-{t}{s}", .{ out_dir, in.name, t, ext }),
        };
        const base = std.fs.path.basename(path);
        const ident = if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| (if (i > 0) base[0..i] else base) else base;
        const sum = try writeExe(ctx, tf, r.size, t, runner, path, ident);
        try written.append(arena, .{ std.fs.path.basename(path), try arena.dupe(u8, &sum) });
        ctx.events.log("wrote {s} ({t}): pack {s}", .{ path, t, &r.digest });
    }
    if (mode == .many) {
        std.mem.sort([2][]const u8, written.items, {}, struct {
            fn lt(_: void, a: [2][]const u8, b: [2][]const u8) bool {
                return std.mem.lessThan(u8, a[0], b[0]);
            }
        }.lt);
        for (written.items) |w| try sums.print(arena, "{s}  {s}\n", .{ w[1], w[0] });
        const sums_path = try std.fs.path.join(arena, &.{ out_dir, "SHA256SUMS" });
        try cwd.writeFile(io, .{ .sub_path = sums_path, .data = sums.items });
        ctx.events.log("wrote {s}", .{sums_path});
    }
    return 0;
}

fn packLayers(arena: std.mem.Allocator, layers: []const types.Layer) ![]const pack.Input.Layer {
    const out = try arena.alloc(pack.Input.Layer, layers.len);
    for (out, layers) |*o, l| o.* = .{ .name = l.name, .key = l.key, .path = l.path };
    return out;
}

/// `path` with a random hidden name beside it, for writing then renaming.
fn tmpName(arena: std.mem.Allocator, io: Io, path: []const u8) ![]const u8 {
    var rand: [6]u8 = undefined;
    io.random(&rand);
    const dir = std.fs.path.dirname(path) orelse ".";
    return std.fmt.allocPrint(arena, "{s}/.{s}.{x}.tmp", .{ dir, std.fs.path.basename(path), &rand });
}

/// The runner for `t`: a `--runner` that names it or matches it, the
/// host's own, or the release's, downloaded. A `--runner` for `t` that
/// isn't one is exit 2, as is a target with no runner at all.
fn runnerFor(ctx: *cli.Context, opts: cli.PackOptions, t: types.Target) ![]const u8 {
    const arena = ctx.arena;
    var bare: ?[]const u8 = null;
    for (opts.runners) |v| {
        const g = runners.Given.parse(v);
        if (g.target) |gt| {
            if (gt != t) continue;
            const bytes = try readRunner(ctx, g.path);
            if (!runners.matches(bytes, t)) return wrong(ctx, g.path, t);
            return bytes;
        }
        const bytes = try readRunner(ctx, g.path);
        if (bare == null and runners.matches(bytes, t)) bare = bytes;
    }
    if (bare) |b| return b;
    if (runners.hostTarget() == t) return embedded.runner;
    const version = runners.pins.version;
    const p = runners.pinFor(&runners.pins.list, t) orelse {
        ctx.events.log("no runner for {t}: h9x {s} has none released; build one with zig build -Dtarget=... and give --runner {t}=FILE", .{ t, build_options.version, t });
        return error.BadTarget;
    };
    const cache_dir = try cache.dir(arena, ctx.env);
    ctx.events.emit(.{ .fetch = .{ .url = try runners.releaseUrl(arena, version, t), .state = .start } });
    return runners.fetch(ctx.gpa, arena, ctx.io, ctx.env, cache_dir, version, p) catch |e| {
        ctx.events.log("runner for {t}: {t}", .{ t, e });
        return e;
    };
}

fn wrong(ctx: *cli.Context, path: []const u8, t: types.Target) error{BadTarget} {
    ctx.events.log("--runner {s}: not a runner for {t}", .{ path, t });
    return error.BadTarget;
}

fn readRunner(ctx: *cli.Context, path: []const u8) ![]const u8 {
    return Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(512 << 20)) catch |e| {
        ctx.events.log("--runner {s}: {t}", .{ path, e });
        return if (e == error.FileNotFound) error.Usage else e;
    };
}

/// Joins `runner` and the pack in `tar` into `path`, executable, and
/// returns its sha256 in hex.
fn writeExe(ctx: *cli.Context, tar: Io.File, size: u64, t: types.Target, runner: []const u8, path: []const u8, ident: []const u8) ![64]u8 {
    const io = ctx.io;
    const cwd = Io.Dir.cwd();
    const tmp = try tmpName(ctx.arena, io, path);
    const f = try cwd.createFile(io, tmp, .{ .read = true, .permissions = .fromMode(0o755) });
    var keep = false;
    defer if (!keep) cwd.deleteFile(io, tmp) catch {};
    {
        defer f.close(io);
        var in_buf: [64 * 1024]u8 = undefined;
        var tr = tar.reader(io, &in_buf);
        var out_buf: [64 * 1024]u8 = undefined;
        var fw = f.writer(io, &out_buf);
        _ = exe.join(ctx.gpa, &fw.interface, t.container(), runner, &tr.interface, size, .{ .identifier = ident }) catch |e| {
            if (e == error.WriteFailed) if (fw.err) |x| return x;
            if (e == error.ReadFailed) if (tr.err) |x| return x;
            return e;
        };
        fw.interface.flush() catch |e| return if (fw.err) |x| x else e;
        try f.setPermissions(io, .fromMode(0o755));
    }
    // Its digest, for SHA256SUMS, read back.
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    {
        const rf = try cwd.openFile(io, tmp, .{});
        defer rf.close(io);
        var buf: [256 * 1024]u8 = undefined;
        var off: u64 = 0;
        while (true) {
            const n = try rf.readPositionalAll(io, &buf, off);
            if (n == 0) break;
            h.update(buf[0..n]);
            off += n;
        }
    }
    try cwd.rename(tmp, cwd, path, io);
    keep = true;
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}

/// `pack --inspect FILE`: the trailer, the container's section, the
/// signature on macOS, the archive's digest, and pack.json, as text or,
/// with `--json`, one object on stdout. Exit 1 if FILE has no pack or
/// anything in it doesn't check out.
fn inspect(ctx: *cli.Context, path: []const u8) !u8 {
    const r = exe.inspect(ctx.arena, ctx.io, path) catch |e| switch (e) {
        error.NotPacked => {
            ctx.events.log("{s} has no pack: it doesn't end in an h9x trailer", .{path});
            return types.Exit.failed.code();
        },
        error.FileNotFound => {
            ctx.events.log("{s}: no such file", .{path});
            return types.Exit.usage.code();
        },
        else => return e,
    };
    if (ctx.common.json) try exe.writeJson(ctx.arena, ctx.stdout, r) else try exe.writeText(ctx.stdout, r);
    // The seal, which pack.json names the pack by (pack.zig).
    const sealed = seal(ctx, path, r.trailer) catch |e| blk: {
        if (!ctx.common.json) try ctx.stdout.print("seal       unreadable: {t}\n", .{e});
        break :blk false;
    };
    return if (r.ok() and sealed) types.Exit.ok.code() else types.Exit.failed.code();
}

fn seal(ctx: *cli.Context, path: []const u8, t: types.Trailer) !bool {
    const f = try Io.Dir.cwd().openFile(ctx.io, path, .{});
    defer f.close(ctx.io);
    const p = try pack.open(ctx.arena, ctx.io, f, t.offset, t.length);
    const ok = try pack.verify(ctx.io, f, p);
    if (!ctx.common.json) try ctx.stdout.print("seal       {s}, {s}\n", .{ p.pack.digest, if (ok) "matching the archive" else "NOT matching the archive" });
    return ok;
}

test {
    _ = exe;
    _ = runners;
}
