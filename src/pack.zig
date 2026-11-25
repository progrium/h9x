//! Packs (design/prototype.md, "Packs"): the base root and run layers
//! flattened into one tar, with `/.h9x/pack.json`, `/.h9x/run`, and the
//! index; and reading one back, for the runner: finding pack.json,
//! checking the seal, and extracting the tree. spec/pack.md describes the
//! format.
//!
//! The tar is `tar.zig`'s, deterministic, so the same layers and options
//! make the same bytes. Its last entry is the index (index.zig).
//!
//! **The seal.** pack.json's `digest` is the sha256 of the whole archive
//! with that field's 64 hex digits written as `0`s. `write` hashes the
//! archive as it writes it with the zeros in place, then writes the digest
//! over them; `seal` hashes an archive the same way to check it. So the
//! digest covers every byte of the pack, pack.json and its sealed policy
//! included, and a reader finds it with one seek through the index. It
//! names the pack: the runner extracts into `packs/DIGEST`.
//!
//! Owned by W8. Making executables, with runners from the release or
//! `--runner`, is in runners.zig and cmd/pack.zig.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const types = @import("types.zig");
const tar = @import("tar.zig");
const index = @import("index.zig");
const policy = @import("policy.zig");

pub const json_path = ".h9x/pack.json";
pub const run_path = ".h9x/run";

/// `sha256:` and 64 hex digits.
pub const Digest = [digest_prefix.len + 64]u8;
const digest_prefix = "sha256:";
/// What `write` puts in pack.json's `digest` until the archive is hashed.
pub const zero_digest: Digest = (digest_prefix ++ "0" ** 64).*;
/// What comes before the digest's hex in pack.json's text.
const digest_key = "\"digest\":\"" ++ digest_prefix;

/// A run layer, as pack.json names it: no host path.
pub const PackLayer = struct {
    name: types.LayerName,
    key: []const u8,
};

/// `/.h9x/pack.json`: what the runner needs to start the app. Field order
/// is the JSON's, and `digest` stays third, so `zero_digest` is the first
/// thing in the text that looks like it.
pub const PackJson = struct {
    pub const current_version = 1;

    version: u32 = current_version,
    arch: types.Arch,
    /// The seal: see the file's comment.
    digest: []const u8 = &zero_digest,
    /// `NAME=VALUE` lines.
    env: []const []const u8,
    start: ?[]const u8,
    cwd: []const u8 = "/app",
    /// The run policy, as plan text, sealed: the environment can narrow it
    /// and never widen it. Its `dir` lines are the `--mount`s given at pack
    /// time, a relative host path resolved against the runner's cwd.
    policy: []const u8,
    layers: []const PackLayer,
    /// Whether `H9X_PACK=info` and `H9X_PACK=shell` work; `--no-debug`
    /// turns them off.
    debug: bool = true,
};

/// What a pack is made from: a build's output, with every path absolute.
pub const Input = struct {
    pub const Layer = struct {
        name: types.LayerName,
        key: []const u8,
        /// The layer's directory, absolute.
        path: []const u8,
    };

    arch: types.Arch,
    /// The base root, absolute.
    base: []const u8,
    /// The run layers, bottom first.
    layers: []const Layer,
    env: []const []const u8 = &.{},
    start: ?[]const u8 = null,
    cwd: []const u8 = "/app",
};

pub const Options = struct {
    /// The sealed run policy's text (`policy.print`).
    policy: []const u8,
    debug: bool = true,
};

pub const Result = struct {
    /// The seal: pack.json's `digest`.
    digest: Digest,
    /// The archive's length in bytes.
    size: u64,
};

/// pack.json's text for `pj`, and where its digest's hex starts in it.
pub fn encodeJson(arena: Allocator, pj: PackJson) Allocator.Error!struct { text: []const u8, digest_at: usize } {
    const text = try std.json.Stringify.valueAlloc(arena, pj, .{});
    const at = std.mem.indexOf(u8, text, digest_key).? + digest_key.len;
    return .{ .text = text, .digest_at = at };
}

/// `/.h9x/run`: starts the app with plain h9, which has no JSON reader, so
/// the env, cwd, and start command are written out as shell:
///
///   h9 --archive app.tar:#L sh /.h9x/run [ARGS...]
///
/// ARGS go after the start command, as a packed executable's do. The
/// runner runs it too, so both start the app the same way. With
/// `H9X_PACK=shell` in the guest's environment it runs a shell in the
/// app's cwd instead, with ARGS as the shell's.
pub fn runScript(arena: Allocator, pj: PackJson) Allocator.Error![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    script(w, pj) catch return error.OutOfMemory;
    return aw.written();
}

fn script(w: *Io.Writer, pj: PackJson) Io.Writer.Error!void {
    try w.writeAll(
        \\#!/bin/sh
        \\# Starts this pack's app, with any arguments after its start command:
        \\#   h9 --archive PACK.tar:#L sh /.h9x/run [ARGS...]
        \\# Written by h9x pack from /.h9x/pack.json.
        \\
    );
    for (pj.env) |kv| {
        try w.writeAll("export ");
        try shQuote(w, kv);
        try w.writeByte('\n');
    }
    try w.writeAll("cd ");
    try shQuote(w, pj.cwd);
    try w.writeAll(" || exit 125\n");
    try w.writeAll(
        \\if [ "${H9X_PACK:-}" = shell ]; then
        \\  unset H9X_PACK
        \\  exec /bin/sh "$@"
        \\fi
        \\
    );
    if (pj.start) |s| {
        // `START "$@"`, quoted: the start command is shell, as Railpack's
        // are, and the arguments go after it.
        try w.writeAll("exec /bin/sh -c '");
        try shEscape(w, s);
        try w.writeAll(" \"$@\"' sh \"$@\"\n");
    } else {
        try w.writeAll(
            \\if [ $# -eq 0 ]; then
            \\  echo "h9x: this pack has no start command; give one as arguments" >&2
            \\  exit 2
            \\fi
            \\exec "$@"
            \\
        );
    }
}

/// `s` in single quotes, as sh reads it.
pub fn shQuote(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try w.writeByte('\'');
    try shEscape(w, s);
    try w.writeByte('\'');
}

/// `s` as it goes inside single quotes.
fn shEscape(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    for (s) |c| {
        if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    }
}

/// Writes the pack of `in` to `file` from its start, and seals it. The
/// file must be open for reading and writing at its start, empty.
pub fn write(gpa: Allocator, io: Io, in: Input, opts: Options, file: Io.File) !Result {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cwd = Io.Dir.cwd();
    var dirs: std.ArrayList(Io.Dir) = .empty;
    defer for (dirs.items) |d| d.close(io);
    try dirs.append(arena, try cwd.openDir(io, in.base, .{ .iterate = true }));
    for (in.layers) |l| try dirs.append(arena, try cwd.openDir(io, l.path, .{ .iterate = true }));

    var tree: tar.Tree = .init(arena, io);
    for (dirs.items) |d| try tree.addLayer(d, .apply);

    const layers = try arena.alloc(PackLayer, in.layers.len);
    for (layers, in.layers) |*o, l| o.* = .{ .name = l.name, .key = l.key };
    const pj: PackJson = .{
        .arch = in.arch,
        .env = in.env,
        .start = in.start,
        .cwd = in.cwd,
        .policy = opts.policy,
        .layers = layers,
        .debug = opts.debug,
    };
    const enc = try encodeJson(arena, pj);
    try tree.addBytes(json_path, 0o644, enc.text);
    try tree.addBytes(run_path, 0o755, try runScript(arena, pj));

    var file_buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &file_buf);
    var hash_buf: [256]u8 = undefined;
    var hashed: Io.Writer.Hashed(Sha256) = .initHasher(&fw.interface, .init(.{}), &hash_buf);
    var entries: std.ArrayList(index.Entry) = .empty;
    defer index.deinitEntries(gpa, &entries);
    var w: tar.Writer = .init(gpa, &hashed.writer);
    w.entries = &entries;
    tree.write(&w) catch |e| return writeError(e, &fw);
    index.finish(&w) catch |e| return writeError(e, &fw);
    hashed.writer.flush() catch |e| return writeError(e, &fw);
    fw.interface.flush() catch |e| return writeError(e, &fw);

    const je = index.find(entries.items, json_path).?;
    var r: Result = .{ .digest = zero_digest, .size = w.offset };
    const hex = std.fmt.bytesToHex(hashed.hasher.finalResult(), .lower);
    @memcpy(r.digest[digest_prefix.len..], &hex);
    try file.writePositionalAll(io, &hex, je.offset + enc.digest_at);
    return r;
}

fn writeError(e: anyerror, fw: *Io.File.Writer) anyerror {
    if (e == error.WriteFailed) if (fw.err) |x| return x;
    return e;
}

// ---------------------------------------------------------------- reading

/// A pack, opened: the archive at `offset` in a file, `len` bytes long.
pub const Opened = struct {
    offset: u64,
    len: u64,
    entries: []const index.Entry,
    /// pack.json's text, as it is in the archive.
    json: []const u8,
    pack: PackJson,
    /// Where the digest's hex is, from the archive's start.
    digest_at: u64,
};

pub const OpenError = error{ NoIndex, BadIndex, NoPackJson, BadPackJson, UnsupportedVersion };

/// Reads the index and pack.json of the archive at `offset` in `file`,
/// without reading the rest. Allocates in `arena`.
pub fn open(arena: Allocator, io: Io, file: Io.File, offset: u64, len: u64) !Opened {
    const entries = try index.read(arena, io, file, offset, len);
    const e = index.find(entries, json_path) orelse return error.NoPackJson;
    if (e.kind != .file or e.size > 1 << 20 or e.offset + e.size > len) return error.BadPackJson;
    const text = try arena.alloc(u8, @intCast(e.size));
    if (try file.readPositionalAll(io, text, offset + e.offset) != text.len) return error.BadPackJson;
    const pj = try parseJson(arena, text);
    const at = (std.mem.indexOf(u8, text, digest_key) orelse return error.BadPackJson) + digest_key.len;
    if (at + 64 > text.len) return error.BadPackJson;
    return .{ .offset = offset, .len = len, .entries = entries, .json = text, .pack = pj, .digest_at = e.offset + at };
}

/// pack.json's text, parsed. Fields a later h9x adds are ignored.
pub fn parseJson(arena: Allocator, text: []const u8) error{ BadPackJson, UnsupportedVersion, OutOfMemory }!PackJson {
    const pj = std.json.parseFromSliceLeaky(PackJson, arena, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadPackJson,
    };
    if (pj.version != PackJson.current_version) return error.UnsupportedVersion;
    if (pj.digest.len != zero_digest.len or !std.mem.startsWith(u8, pj.digest, digest_prefix)) return error.BadPackJson;
    return pj;
}

/// The archive's seal, computed: its sha256 with the digest's hex read as
/// `0`s. Equal to `p.pack.digest` for a pack nothing has changed.
pub fn seal(io: Io, file: Io.File, p: Opened) !Digest {
    var h = Sha256.init(.{});
    var buf: [256 * 1024]u8 = undefined;
    try hashRange(io, file, &h, p.offset, p.digest_at, &buf);
    h.update("0" ** 64);
    try hashRange(io, file, &h, p.offset + p.digest_at + 64, p.len - p.digest_at - 64, &buf);
    var d: Digest = zero_digest;
    const hex = std.fmt.bytesToHex(h.finalResult(), .lower);
    @memcpy(d[digest_prefix.len..], &hex);
    return d;
}

fn hashRange(io: Io, file: Io.File, h: *Sha256, start: u64, len: u64, buf: []u8) !void {
    var off = start;
    const end = start + len;
    while (off < end) {
        const n: usize = @intCast(@min(buf.len, end - off));
        if (try file.readPositionalAll(io, buf[0..n], off) != n) return error.EndOfStream;
        h.update(buf[0..n]);
        off += n;
    }
}

/// Whether `p` is sealed: its digest matches its bytes.
pub fn verify(io: Io, file: Io.File, p: Opened) !bool {
    const d = try seal(io, file, p);
    return std.mem.eql(u8, &d, p.pack.digest);
}

/// The hex of a digest, for a directory's name.
pub fn digestHex(d: []const u8) []const u8 {
    return d[digest_prefix.len..];
}

pub const ExtractError = error{BadPath};

/// Writes `p`'s tree into `dest`, an empty directory: every entry in the
/// index, files with their modes, links, and directories, whose modes are
/// set last so a read-only one can be filled. FIFOs are left out. Paths
/// are checked to stay under `dest`.
pub fn extract(gpa: Allocator, io: Io, file: Io.File, p: Opened, dest: Io.Dir) !void {
    var buf: [256 * 1024]u8 = undefined;
    var dirs: std.ArrayList(index.Entry) = .empty;
    defer dirs.deinit(gpa);
    for (p.entries) |e| {
        try checkPath(e.path);
        switch (e.kind) {
            .dir => {
                try dest.createDirPath(io, e.path);
                try dirs.append(gpa, e);
            },
            .file => {
                if (e.offset + e.size > p.len) return error.BadIndex;
                const f = try dest.createFile(io, e.path, .{ .exclusive = true, .permissions = .fromMode(@intCast(e.mode & 0o777)) });
                defer f.close(io);
                var off: u64 = 0;
                while (off < e.size) {
                    const n: usize = @intCast(@min(buf.len, e.size - off));
                    if (try file.readPositionalAll(io, buf[0..n], p.offset + e.offset + off) != n) return error.EndOfStream;
                    try f.writePositionalAll(io, buf[0..n], off);
                    off += n;
                }
                // The mode as given, past the umask.
                try f.setPermissions(io, .fromMode(@intCast(e.mode & 0o777)));
            },
            .symlink => try dest.symLink(io, e.target, e.path, .{}),
            else => {},
        }
    }
    var i = dirs.items.len;
    while (i > 0) {
        i -= 1;
        const d = dirs.items[i];
        dest.setFilePermissions(io, d.path, .fromMode(@intCast(d.mode & 0o777)), .{}) catch {};
    }
}

/// A path in a pack is relative, with no empty, `.`, or `..` parts.
fn checkPath(p: []const u8) ExtractError!void {
    if (p.len == 0 or p[0] == '/') return error.BadPath;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.BadPath;
    }
}

// ---------------------------------------------------------------- the run's policy

pub const PolicyError = error{ Syntax, Widens, OutOfMemory };

/// What the runner starts the app with, besides the pack.
pub const RunRequest = struct {
    /// The extracted tree, absolute: the Linux root.
    root: []const u8,
    /// The runner's cwd, absolute, which relative `--mount`s resolve
    /// against.
    cwd: []const u8,
    /// `H9X_PACK_NET`, if set: narrows `net`.
    net: ?[]const u8 = null,
};

/// The machine's policy for a pack: the extracted tree read-only on `#L`,
/// then the sealed policy, its relative mounts resolved, narrowed by the
/// environment. error.Widens, with `diag`, for a variable that would widen
/// it, and error.Syntax for one that doesn't parse.
pub fn runPolicy(arena: Allocator, pj: PackJson, req: RunRequest, diag: *policy.Diag) PolicyError!types.Policy {
    const sealed = try policy.parsePolicy(arena, .run, .trusted, pj.policy, diag);
    var mounts: std.ArrayList(types.Mount) = .empty;
    try mounts.append(arena, .{ .kind = .dir, .src = req.root, .dst = "#L", .access = .ro });
    for (sealed.mounts) |m| {
        var o = m;
        if (m.kind == .dir and !std.fs.path.isAbsolute(m.src)) o.src = try std.fs.path.resolve(arena, &.{ req.cwd, m.src });
        try mounts.append(arena, o);
    }
    var p = sealed;
    p.mounts = mounts.items;
    if (req.net) |n| {
        const net = @import("units.zig").parseNet(n) orelse {
            diag.* = .{ .msg = try std.fmt.allocPrint(arena, "H9X_PACK_NET={s}: want none, outbound, or enable", .{n}) };
            return error.Syntax;
        };
        p = policy.narrow(arena, p, .{ .net = net }, diag) catch |e| switch (e) {
            error.Widens => {
                diag.* = .{ .msg = try std.fmt.allocPrint(arena, "H9X_PACK_NET={s}: the pack's policy has net {t}, and the environment only narrows it", .{ n, sealed.net }) };
                return error.Widens;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
    return p;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn mkfile(dir: Io.Dir, path: []const u8, data: []const u8, mode: std.posix.mode_t) !void {
    const io = testing.io;
    if (std.fs.path.dirname(path)) |d| try dir.createDirPath(io, d);
    try dir.writeFile(io, .{ .sub_path = path, .data = data, .flags = .{ .permissions = .fromMode(mode) } });
    try dir.setFilePermissions(io, path, .fromMode(mode), .{});
}

/// A hand-made build: a base root, a deps layer, and an app layer whiting
/// out a base file, under `tmp`.
pub const Fixture = struct {
    tmp: testing.TmpDir,
    abs: []const u8,

    pub fn init(arena: Allocator) !Fixture {
        const io = testing.io;
        var f: Fixture = .{ .tmp = testing.tmpDir(.{}), .abs = undefined };
        const d = f.tmp.dir;
        try mkfile(d, "base/bin/hello", "#!/bin/sh\necho hello\n", 0o755);
        try mkfile(d, "base/etc/os-release", "ID=fixture\n", 0o644);
        try mkfile(d, "base/etc/motd", "welcome\n", 0o644);
        try d.symLink(io, "hello", "base/bin/hi", .{});
        try mkfile(d, "deps/app/node_modules/x/index.js", "module.exports = 1\n", 0o644);
        try mkfile(d, "app/app/server.js", "console.log('hi')\n", 0o644);
        try mkfile(d, "app/etc/.wh.motd", "", 0o644);
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const n = try d.realPath(io, &buf);
        f.abs = try arena.dupe(u8, buf[0..n]);
        return f;
    }

    pub fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
    }

    pub fn input(f: Fixture, arena: Allocator) !Input {
        const j = struct {
            fn p(a: Allocator, base: []const u8, sub: []const u8) ![]const u8 {
                return std.fs.path.join(a, &.{ base, sub });
            }
        }.p;
        return .{
            .arch = .amd64,
            .base = try j(arena, f.abs, "base"),
            .layers = try arena.dupe(Input.Layer, &.{
                .{ .name = .deps, .key = "d1", .path = try j(arena, f.abs, "deps") },
                .{ .name = .app, .key = "a1", .path = try j(arena, f.abs, "app") },
            }),
            .env = &.{ "PATH=/usr/bin:/bin", "GREETING=it's here" },
            .start = "node server.js",
        };
    }
};

fn writeTo(arena: Allocator, dir: Io.Dir, name: []const u8, in: Input, opts: Options) !Result {
    const io = testing.io;
    const f = try dir.createFile(io, name, .{ .read = true });
    defer f.close(io);
    _ = arena;
    return write(testing.allocator, io, in, opts, f);
}

test "a pack is the same bytes twice, and sealed" {
    const io = testing.io;
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var fx = try Fixture.init(arena);
    defer fx.deinit();
    const in = try fx.input(arena);
    const opts: Options = .{ .policy = "net outbound\nwrite overlay\nmemory 1G\n" };

    const r1 = try writeTo(arena, fx.tmp.dir, "one.tar", in, opts);
    const r2 = try writeTo(arena, fx.tmp.dir, "two.tar", in, opts);
    try testing.expectEqualSlices(u8, &r1.digest, &r2.digest);
    const one = try fx.tmp.dir.readFileAlloc(io, "one.tar", arena, .unlimited);
    const two = try fx.tmp.dir.readFileAlloc(io, "two.tar", arena, .unlimited);
    try testing.expectEqualSlices(u8, one, two);
    try testing.expectEqual(r1.size, one.len);

    const f = try fx.tmp.dir.openFile(io, "one.tar", .{});
    defer f.close(io);
    const p = try open(arena, io, f, 0, one.len);
    try testing.expectEqualStrings(&r1.digest, p.pack.digest);
    try testing.expect(try verify(io, f, p));
    try testing.expectEqualStrings("node server.js", p.pack.start.?);
    try testing.expectEqual(@as(usize, 2), p.pack.layers.len);
    try testing.expectEqualStrings("a1", p.pack.layers[1].key);

    // What's in it: the layers flattened, with the whiteout applied.
    try testing.expect(index.find(p.entries, "app/server.js") != null);
    try testing.expect(index.find(p.entries, "app/node_modules/x/index.js") != null);
    try testing.expect(index.find(p.entries, "etc/os-release") != null);
    try testing.expect(index.find(p.entries, "etc/motd") == null);
    try testing.expect(index.find(p.entries, "etc/.wh.motd") == null);
    try testing.expectEqualStrings("hello", index.find(p.entries, "bin/hi").?.target);
    try testing.expectEqual(@as(u32, 0o755), index.find(p.entries, run_path).?.mode);
}

test "a changed byte breaks the seal" {
    const io = testing.io;
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var fx = try Fixture.init(arena);
    defer fx.deinit();
    const r = try writeTo(arena, fx.tmp.dir, "p.tar", try fx.input(arena), .{ .policy = "net disable\n" });

    const f = try fx.tmp.dir.openFile(io, "p.tar", .{ .mode = .read_write });
    defer f.close(io);
    const p = try open(arena, io, f, 0, r.size);
    // Widen the sealed policy in place: same length, so the index still
    // reads.
    const at = std.mem.indexOf(u8, p.json, "net disable").?;
    const e = index.find(p.entries, json_path).?;
    try f.writePositionalAll(io, "net enable!", e.offset + at);
    const q = try open(arena, io, f, 0, r.size);
    try testing.expect(!try verify(io, f, q));
}

test "extract writes the tree" {
    const io = testing.io;
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var fx = try Fixture.init(arena);
    defer fx.deinit();
    const r = try writeTo(arena, fx.tmp.dir, "p.tar", try fx.input(arena), .{ .policy = "net disable\n" });
    const f = try fx.tmp.dir.openFile(io, "p.tar", .{});
    defer f.close(io);
    const p = try open(arena, io, f, 0, r.size);
    try fx.tmp.dir.createDirPath(io, "out");
    var out = try fx.tmp.dir.openDir(io, "out", .{});
    defer out.close(io);
    try extract(testing.allocator, io, f, p, out);

    try testing.expectEqualStrings("#!/bin/sh\necho hello\n", try out.readFileAlloc(io, "bin/hello", arena, .unlimited));
    const st = try out.statFile(io, "bin/hello", .{});
    try testing.expectEqual(@as(u32, 0o755), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    var lbuf: [64]u8 = undefined;
    try testing.expectEqualStrings("hello", lbuf[0..try out.readLink(io, "bin/hi", &lbuf)]);
    try testing.expectError(error.FileNotFound, out.statFile(io, "etc/motd", .{}));
    const run = try out.readFileAlloc(io, run_path, arena, .unlimited);
    try testing.expect(std.mem.indexOf(u8, run, "export 'GREETING=it'\\''s here'\n") != null);
    try testing.expect(std.mem.indexOf(u8, run, "exec /bin/sh -c 'node server.js \"$@\"' sh \"$@\"\n") != null);
}

test "runPolicy resolves mounts and only narrows" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const pj: PackJson = .{
        .arch = .amd64,
        .env = &.{},
        .start = null,
        .policy = "dir rw . /work\nnet outbound\nwrite overlay\nmemory 1G\n",
        .layers = &.{},
    };
    var diag: policy.Diag = .{};
    const p = try runPolicy(arena, pj, .{ .root = "/c/packs/x", .cwd = "/home/me/proj", .net = "none" }, &diag);
    try testing.expectEqualStrings("#L", p.mounts[0].dst);
    try testing.expectEqualStrings("/c/packs/x", p.mounts[0].src);
    try testing.expectEqualStrings("/home/me/proj", p.mounts[1].src);
    try testing.expectEqualStrings("/work", p.mounts[1].dst);
    try testing.expectEqual(types.Net.disable, p.net);
    try testing.expectEqual(@as(?u64, 1 << 30), p.memory);
    try testing.expectError(error.Widens, runPolicy(arena, pj, .{ .root = "/r", .cwd = "/", .net = "enable" }, &diag));
    try testing.expectError(error.Syntax, runPolicy(arena, pj, .{ .root = "/r", .cwd = "/", .net = "wide" }, &diag));
}

test "a pack with no start command takes one as arguments" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const s = try runScript(a.allocator(), .{ .arch = .amd64, .env = &.{}, .start = null, .policy = "", .layers = &.{} });
    try testing.expect(std.mem.indexOf(u8, s, "exec \"$@\"\n") != null);
}
