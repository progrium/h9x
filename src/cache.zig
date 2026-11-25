//! The cache (design/prototype.md, "Cache"): its layout, touching entries
//! on use, `cache ls`, and `cache prune`. Documented in spec/cache.md.
//!
//! Each kind of entry is a directory under the cache, and each entry is a
//! file or directory in it: `roots/base-KEY`, `runtimes/KEY`, `dl/FILE`.
//! `sources/` is one level deeper, since it holds three kinds of its own:
//! `sources/git/KEY`, `sources/tree/HASH`, and `sources/dirs/KEY`. An
//! entry's mtime is its last use: whoever uses one calls `touch`, so
//! `prune` can tell what hasn't been used in a while.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = std.Io.Dir;

/// The kinds of entry, each a directory under the cache.
pub const Kind = enum {
    bootstrap,
    dl,
    tools,
    roots,
    runtimes,
    sources,
    builds,
    runners,
    packs,

    /// How deep a kind's entries are below its directory.
    fn depth(k: Kind) u8 {
        return if (k == .sources) 2 else 1;
    }
};

/// `$H9X_CACHE`, or `${XDG_CACHE_HOME:-~/.cache}/h9x`.
pub fn dir(arena: std.mem.Allocator, env: *const std.process.Environ.Map) error{ OutOfMemory, NoHome }![]const u8 {
    if (env.get("H9X_CACHE")) |c| if (c.len > 0) return c;
    if (env.get("XDG_CACHE_HOME")) |x| if (x.len > 0) return std.fs.path.join(arena, &.{ x, "h9x" });
    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse return error.NoHome;
    return std.fs.path.join(arena, &.{ home, ".cache", "h9x" });
}

/// An entry's path: `CACHE/KIND/NAME`. NAME may have a directory in it,
/// as `sources/` entries do.
pub fn path(arena: std.mem.Allocator, cache_dir: []const u8, kind: Kind, name: []const u8) error{OutOfMemory}![]const u8 {
    return std.fs.path.join(arena, &.{ cache_dir, @tagName(kind), name });
}

/// Marks an entry used now, by setting its mtime. Best effort: an entry
/// that can't be touched is only pruned sooner.
pub fn touch(io: Io, entry_path: []const u8) void {
    Dir.cwd().setTimestamps(io, entry_path, .{
        .follow_symlinks = false,
        .modify_timestamp = .now,
    }) catch {};
}

pub const Entry = struct {
    kind: Kind,
    /// The path below the kind's directory: `base-KEY`, or `tree/HASH`.
    name: []const u8,
    /// Absolute, or as the cache directory was given.
    path: []const u8,
    /// Bytes, of every file below it, symlinks not followed.
    size: u64,
    /// Its mtime: when it was last used.
    used: Io.Timestamp,
    /// A build in the cache names it, so `prune` keeps it.
    named: bool = false,
};

/// Every entry in the cache, in `Kind` order and then by name. A cache
/// that doesn't exist yet has none.
pub fn list(arena: std.mem.Allocator, io: Io, cache_dir: []const u8) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    for (std.enums.values(Kind)) |kind| {
        const kdir = try std.fs.path.join(arena, &.{ cache_dir, @tagName(kind) });
        if (kind.depth() == 1) {
            try listDir(arena, io, kind, kdir, "", &out);
            continue;
        }
        var d = Dir.cwd().openDir(io, kdir, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => continue,
            else => return e,
        };
        defer d.close(io);
        var subs: std.ArrayList([]const u8) = .empty;
        var it = d.iterate();
        while (try it.next(io)) |e| if (e.kind == .directory) try subs.append(arena, try arena.dupe(u8, e.name));
        std.mem.sortUnstable([]const u8, subs.items, {}, lessThan);
        for (subs.items) |s| try listDir(arena, io, kind, try std.fs.path.join(arena, &.{ kdir, s }), s, &out);
    }
    const named = try namedPaths(arena, io, cache_dir, out.items, null);
    for (out.items) |*e| e.named = named.contains(e.path);
    return out.items;
}

/// The entries in one directory, sorted by name, as `PREFIX/NAME`.
fn listDir(arena: std.mem.Allocator, io: Io, kind: Kind, d_path: []const u8, prefix: []const u8, out: *std.ArrayList(Entry)) !void {
    var d = Dir.cwd().openDir(io, d_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return,
        else => return e,
    };
    defer d.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (try it.next(io)) |e| try names.append(arena, try arena.dupe(u8, e.name));
    std.mem.sortUnstable([]const u8, names.items, {}, lessThan);
    for (names.items) |n| {
        const st = d.statFile(io, n, .{ .follow_symlinks = false }) catch continue;
        const p = try std.fs.path.join(arena, &.{ d_path, n });
        try out.append(arena, .{
            .kind = kind,
            .name = if (prefix.len == 0) n else try std.fs.path.join(arena, &.{ prefix, n }),
            .path = p,
            .size = if (st.kind == .directory) try treeSize(arena, io, d, n) else st.size,
            .used = st.mtime,
        });
    }
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The bytes of every file below `sub`, symlinks counted as themselves.
fn treeSize(gpa: std.mem.Allocator, io: Io, parent: Dir, sub: []const u8) !u64 {
    var d = parent.openDir(io, sub, .{ .iterate = true, .follow_symlinks = false }) catch return 0;
    defer d.close(io);
    var w = try d.walk(gpa);
    defer w.deinit();
    var total: u64 = 0;
    while (w.next(io) catch null) |e| {
        if (e.kind == .directory) continue;
        const st = e.dir.statFile(io, e.basename, .{ .follow_symlinks = false }) catch continue;
        total += st.size;
    }
    return total;
}

/// The paths that builds in the cache name in their `artifact.json`: the
/// base root and the shared runtime layers. Builds in `skip` are left out,
/// since prune is about to remove them.
fn namedPaths(
    arena: std.mem.Allocator,
    io: Io,
    cache_dir: []const u8,
    entries: []const Entry,
    skip: ?*const std.StringHashMapUnmanaged(void),
) !std.StringHashMapUnmanaged(void) {
    var named: std.StringHashMapUnmanaged(void) = .empty;
    for (entries) |e| {
        if (e.kind != .builds) continue;
        if (skip) |s| if (s.contains(e.path)) continue;
        const json_path = try std.fs.path.join(arena, &.{ e.path, "artifact.json" });
        const text = Dir.cwd().readFileAlloc(io, json_path, arena, .limited(16 << 20)) catch continue;
        for (try artifactPaths(arena, text)) |p| try named.put(arena, try resolveNamed(arena, cache_dir, p), {});
    }
    return named;
}

/// The paths an `artifact.json` names: `base.path` and each layer's
/// `path`. Unreadable JSON names nothing.
pub fn artifactPaths(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const []const u8 {
    const Shape = struct {
        base: ?struct { path: ?[]const u8 = null } = null,
        layers: []const struct { path: ?[]const u8 = null } = &.{},
    };
    const parsed = std.json.parseFromSliceLeaky(Shape, arena, text, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    var out: std.ArrayList([]const u8) = .empty;
    if (parsed.base) |b| if (b.path) |p| try out.append(arena, p);
    for (parsed.layers) |l| if (l.path) |p| try out.append(arena, p);
    return out.items;
}

/// A named path as an entry's path: `$cache/` is the cache directory, and
/// anything below an entry is that entry (a layer's `fs/`, say).
fn resolveNamed(arena: std.mem.Allocator, cache_dir: []const u8, p: []const u8) error{OutOfMemory}![]const u8 {
    const prefix = "$cache/";
    const full = if (std.mem.startsWith(u8, p, prefix))
        try std.fs.path.join(arena, &.{ cache_dir, p[prefix.len..] })
    else
        p;
    // CACHE/KIND/NAME[/...] → CACHE/KIND/NAME, a level deeper for sources.
    if (!std.mem.startsWith(u8, full, cache_dir)) return full;
    const rest = std.mem.trimStart(u8, full[cache_dir.len..], "/");
    var it = std.mem.splitScalar(u8, rest, '/');
    const k = it.next() orelse return full;
    const kind = std.meta.stringToEnum(Kind, k) orelse return full;
    var end: usize = cache_dir.len + 1 + k.len;
    var n: u8 = 0;
    while (n < kind.depth()) : (n += 1) {
        const part = it.next() orelse return full;
        end += 1 + part.len;
    }
    return full[0..@min(end, full.len)];
}

pub const Pruned = struct {
    /// What was removed, or with `dry_run` would be.
    removed: []const Entry,
    /// Entries old enough to go that a build names.
    kept: []const Entry,
    freed: u64,
};

/// Removes the entries not used since `unused_ns` before `now`, except
/// those that a build left in the cache names. With `dry_run`, removes
/// nothing and says what it would.
pub fn prune(
    arena: std.mem.Allocator,
    io: Io,
    cache_dir: []const u8,
    now: Io.Timestamp,
    unused_ns: u64,
    dry_run: bool,
) !Pruned {
    const entries = try list(arena, io, cache_dir);
    const cutoff: i96 = now.nanoseconds - @as(i96, unused_ns);
    const old = struct {
        fn f(e: Entry, c: i96) bool {
            return e.used.nanoseconds < c;
        }
    }.f;

    // Builds go first, so what only an old build names goes with it.
    var gone_builds: std.StringHashMapUnmanaged(void) = .empty;
    for (entries) |e| if (e.kind == .builds and old(e, cutoff)) try gone_builds.put(arena, e.path, {});
    const named = try namedPaths(arena, io, cache_dir, entries, &gone_builds);

    var removed: std.ArrayList(Entry) = .empty;
    var kept: std.ArrayList(Entry) = .empty;
    var freed: u64 = 0;
    for (entries) |e| {
        if (!old(e, cutoff)) continue;
        if (named.contains(e.path)) {
            var k = e;
            k.named = true;
            try kept.append(arena, k);
            continue;
        }
        if (!dry_run) try removeTree(io, e.path);
        try removed.append(arena, e);
        freed += e.size;
    }
    return .{ .removed = removed.items, .kept = kept.items, .freed = freed };
}

/// Removes a file or tree. Guests leave read-only directories (Go's module
/// cache, say), which can't be emptied until they're writable again.
pub fn removeTree(io: Io, p: []const u8) !void {
    const cwd = Dir.cwd();
    cwd.deleteTree(io, p) catch |e| switch (e) {
        error.AccessDenied, error.PermissionDenied => {
            if (builtin.os.tag == .windows) return e;
            try makeWritable(io, p);
            try cwd.deleteTree(io, p);
        },
        else => return e,
    };
}

fn makeWritable(io: Io, p: []const u8) !void {
    const cwd = Dir.cwd();
    const st = cwd.statFile(io, p, .{ .follow_symlinks = false }) catch return;
    if (st.kind != .directory) return;
    const rwx: std.Io.File.Permissions = .fromMode(0o700);
    cwd.setFilePermissions(io, p, rwx, .{}) catch {};
    var d = cwd.openDir(io, p, .{ .iterate = true, .follow_symlinks = false }) catch return;
    defer d.close(io);
    var it = d.iterate();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try it.next(io)) |e| {
        if (e.kind != .directory) continue;
        const sub = std.fmt.bufPrint(&buf, "{s}/{s}", .{ p, e.name }) catch continue;
        try makeWritable(io, sub);
    }
}

// ---------------------------------------------------------------- output

/// `12K`, `3.4M`, `1.2G`.
pub fn formatSize(buf: []u8, n: u64) []const u8 {
    const units = [_]struct { u64, u8 }{ .{ 1 << 30, 'G' }, .{ 1 << 20, 'M' }, .{ 1 << 10, 'K' } };
    for (units) |u| {
        if (n >= u[0]) {
            const whole = n / u[0];
            if (whole >= 10) return std.fmt.bufPrint(buf, "{d}{c}", .{ whole, u[1] }) catch buf[0..0];
            const tenth = (n % u[0]) * 10 / u[0];
            return std.fmt.bufPrint(buf, "{d}.{d}{c}", .{ whole, tenth, u[1] }) catch buf[0..0];
        }
    }
    return std.fmt.bufPrint(buf, "{d}B", .{n}) catch buf[0..0];
}

/// How long ago: `now`, `40s`, `12m`, `5h`, or `3d`.
pub fn formatAge(buf: []u8, now: Io.Timestamp, then: Io.Timestamp) []const u8 {
    const d = now.nanoseconds - then.nanoseconds;
    if (d < std.time.ns_per_s) return "now";
    const ns: u64 = @intCast(d);
    const units = [_]struct { u64, u8 }{
        .{ std.time.ns_per_day, 'd' },
        .{ std.time.ns_per_hour, 'h' },
        .{ std.time.ns_per_min, 'm' },
        .{ std.time.ns_per_s, 's' },
    };
    for (units) |u| if (ns >= u[0]) return std.fmt.bufPrint(buf, "{d}{c}", .{ ns / u[0], u[1] }) catch buf[0..0];
    unreachable;
}

/// `cache ls`: one line per entry, under a header, and a total per kind.
pub fn writeList(w: *Io.Writer, entries: []const Entry, now: Io.Timestamp) Io.Writer.Error!void {
    if (entries.len == 0) return w.writeAll("the cache is empty\n");
    var width: usize = "ENTRY".len;
    for (entries) |e| width = @max(width, @tagName(e.kind).len + 1 + e.name.len);
    try w.print("{s: <[3]}  {s: >6}  {s: >5}\n", .{ "ENTRY", "SIZE", "USED", width });
    var sb: [16]u8 = undefined;
    var ab: [16]u8 = undefined;
    var nb: [256]u8 = undefined;
    var total: u64 = 0;
    for (entries) |e| {
        const name = std.fmt.bufPrint(&nb, "{t}/{s}", .{ e.kind, e.name }) catch e.name;
        try w.print("{s: <[4]}  {s: >6}  {s: >5}{s}\n", .{
            name,
            formatSize(&sb, e.size),
            formatAge(&ab, now, e.used),
            if (e.named) "  (named by a build)" else "",
            width,
        });
        total += e.size;
    }
    try w.print("{s: <[2]}  {s: >6}\n", .{ "total", formatSize(&sb, total), width });
}

/// `cache ls --json`: one object per entry and line, `used` in Unix
/// seconds.
pub fn writeListJson(w: *Io.Writer, entries: []const Entry) Io.Writer.Error!void {
    for (entries) |e| {
        var s: std.json.Stringify = .{ .writer = w };
        try s.write(.{
            .kind = @tagName(e.kind),
            .name = e.name,
            .path = e.path,
            .size = e.size,
            .used = @as(i64, @intCast(@divFloor(e.used.nanoseconds, std.time.ns_per_s))),
            .named = e.named,
        });
        try w.writeByte('\n');
    }
}

// ---------------------------------------------------------------- tests

test dir {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var env: std.process.Environ.Map = .init(a.allocator());
    try env.put("HOME", "/home/me");
    try std.testing.expectEqualStrings("/home/me/.cache/h9x", try dir(a.allocator(), &env));
    try env.put("H9X_CACHE", "/c");
    try std.testing.expectEqualStrings("/c", try dir(a.allocator(), &env));
}

test formatSize {
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("512B", formatSize(&b, 512));
    try std.testing.expectEqualStrings("1.5K", formatSize(&b, 1536));
    try std.testing.expectEqualStrings("212M", formatSize(&b, 212 << 20));
    try std.testing.expectEqualStrings("1.2G", formatSize(&b, (1 << 30) + (1 << 28)));
}

test formatAge {
    var b: [16]u8 = undefined;
    const now: Io.Timestamp = .{ .nanoseconds = 100 * std.time.ns_per_day };
    try std.testing.expectEqualStrings("now", formatAge(&b, now, now));
    try std.testing.expectEqualStrings("3d", formatAge(&b, now, .{ .nanoseconds = now.nanoseconds - 3 * std.time.ns_per_day - 5 }));
    try std.testing.expectEqualStrings("12m", formatAge(&b, now, .{ .nanoseconds = now.nanoseconds - 12 * std.time.ns_per_min }));
}

test artifactPaths {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ps = try artifactPaths(a.allocator(),
        \\{"version":1,"arch":"amd64","base":{"path":"$cache/roots/base-1","packages":[]},
        \\ "layers":[{"name":"runtime","key":"k","path":"$cache/runtimes/r1"},{"name":"deps","key":"k","path":"layers/deps"}],
        \\ "env":[],"start":null,"cwd":"/app"}
    );
    try std.testing.expectEqual(@as(usize, 3), ps.len);
    try std.testing.expectEqualStrings("$cache/runtimes/r1", ps[1]);
    try std.testing.expectEqual(@as(usize, 0), (try artifactPaths(a.allocator(), "not json")).len);
}

test resolveNamed {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    try std.testing.expectEqualStrings("/c/roots/base-1", try resolveNamed(ar, "/c", "$cache/roots/base-1"));
    try std.testing.expectEqualStrings("/c/runtimes/r1", try resolveNamed(ar, "/c", "/c/runtimes/r1/fs"));
    try std.testing.expectEqualStrings("/c/sources/tree/abc", try resolveNamed(ar, "/c", "/c/sources/tree/abc/app"));
    try std.testing.expectEqualStrings("layers/deps", try resolveNamed(ar, "/c", "layers/deps"));
}

/// A cache in a temporary directory, for the tests here and in
/// cmd/cache.zig.
pub const TestCache = struct {
    tmp: std.testing.TmpDir,
    path: []const u8,

    pub fn init(arena: std.mem.Allocator) !TestCache {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        const p = try tmp.dir.realPathFileAlloc(io, ".", arena);
        return .{ .tmp = tmp, .path = p };
    }

    pub fn deinit(t: *TestCache) void {
        t.tmp.cleanup();
    }

    /// Makes `REL` as a directory with a file of `size` bytes, used `age_ns`
    /// before `now`.
    pub fn add(t: *TestCache, rel: []const u8, size: usize, now: Io.Timestamp, age_ns: u64) !void {
        const io = std.testing.io;
        try t.tmp.dir.createDirPath(io, rel);
        var buf: [256]u8 = undefined;
        const f = try std.fmt.bufPrint(&buf, "{s}/data", .{rel});
        const data = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(data);
        @memset(data, 'x');
        try t.tmp.dir.writeFile(io, .{ .sub_path = f, .data = data });
        try t.age(rel, now, age_ns);
    }

    pub fn age(t: *TestCache, rel: []const u8, now: Io.Timestamp, age_ns: u64) !void {
        try t.tmp.dir.setTimestamps(std.testing.io, rel, .{
            .modify_timestamp = .{ .new = .{ .nanoseconds = now.nanoseconds - @as(i96, age_ns) } },
        });
    }

    pub fn exists(t: *TestCache, rel: []const u8) bool {
        t.tmp.dir.access(std.testing.io, rel, .{}) catch return false;
        return true;
    }
};

test "cache prune --unused removes only what no build names [prototype]" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const io = std.testing.io;
    var c = try TestCache.init(ar);
    defer c.deinit();

    const day = std.time.ns_per_day;
    const now = Io.Timestamp.now(io, .real);
    // A recent build names an old base root and an old runtime; an old
    // build names another runtime, which goes with it.
    try c.add("roots/base-1", 100, now, 90 * day);
    try c.add("roots/builder-1", 100, now, 90 * day);
    try c.add("runtimes/r1", 10, now, 60 * day);
    try c.add("runtimes/r2", 10, now, 60 * day);
    try c.add("runtimes/r3", 10, now, 1 * day);
    try c.add("sources/tree/abc", 10, now, 45 * day);
    try c.add("sources/git/def", 10, now, 2 * day);
    try c.add("builds/new", 0, now, 0);
    try c.tmp.dir.writeFile(io, .{ .sub_path = "builds/new/artifact.json", .data =
        \\{"base":{"path":"$cache/roots/base-1"},"layers":[{"path":"$cache/runtimes/r1"},{"path":"layers/deps"}]}
    });
    try c.add("builds/old", 0, now, 40 * day);
    try c.tmp.dir.writeFile(io, .{ .sub_path = "builds/old/artifact.json", .data =
        \\{"base":{"path":"$cache/roots/base-1"},"layers":[{"path":"$cache/runtimes/r2"}]}
    });
    // Writing artifact.json touched the builds.
    try c.age("builds/new", now, 0);
    try c.age("builds/old", now, 40 * day);
    // Read-only directories, as Go's module cache leaves them.
    try c.add("dl/ro/sub", 5, now, 50 * day);
    try c.tmp.dir.setFilePermissions(io, "dl/ro/sub", .fromMode(0o555), .{});
    try c.age("dl/ro", now, 50 * day);

    const dry = try prune(ar, io, c.path, now, 30 * day, true);
    try std.testing.expectEqual(@as(usize, 5), dry.removed.len);
    try std.testing.expect(c.exists("runtimes/r2"));

    const p = try prune(ar, io, c.path, now, 30 * day, false);
    var gone: std.ArrayList(u8) = .empty;
    for (p.removed) |e| try gone.print(ar, "{t}/{s} ", .{ e.kind, e.name });
    try std.testing.expectEqualStrings("dl/ro roots/builder-1 runtimes/r2 sources/tree/abc builds/old ", gone.items);
    try std.testing.expectEqual(@as(usize, 2), p.kept.len);
    try std.testing.expect(c.exists("roots/base-1"));
    try std.testing.expect(c.exists("runtimes/r1"));
    try std.testing.expect(c.exists("runtimes/r3"));
    try std.testing.expect(c.exists("sources/git/def"));
    try std.testing.expect(!c.exists("runtimes/r2"));
    try std.testing.expect(!c.exists("dl/ro"));

    const ls = try list(ar, io, c.path);
    try std.testing.expectEqual(@as(usize, 5), ls.len);
    try std.testing.expectEqualStrings("base-1", ls[0].name);
    try std.testing.expect(ls[0].named);

    // Touching an entry makes it recent.
    touch(io, try path(ar, c.path, .runtimes, "r1"));
    const after = try list(ar, io, c.path);
    for (after) |e| if (e.kind == .runtimes and std.mem.eql(u8, e.name, "r1"))
        try std.testing.expect(now.nanoseconds - e.used.nanoseconds < std.time.ns_per_min);
}

test writeList {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const now: Io.Timestamp = .{ .nanoseconds = 10 * std.time.ns_per_day };
    try writeList(&w, &.{
        .{ .kind = .roots, .name = "base-1", .path = "/c/roots/base-1", .size = 212 << 20, .used = .{ .nanoseconds = 8 * std.time.ns_per_day }, .named = true },
        .{ .kind = .sources, .name = "tree/abc", .path = "/c/sources/tree/abc", .size = 2048, .used = now },
    }, now);
    try std.testing.expectEqualStrings(
        \\ENTRY               SIZE   USED
        \\roots/base-1        212M     2d  (named by a build)
        \\sources/tree/abc    2.0K    now
        \\total               212M
        \\
    , w.buffered());
}

// main.zig's test block names the commands' files without reaching their
// tests.
test {
    _ = @import("cmd/cache.zig");
}
