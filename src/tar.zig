//! Deterministic tar writing (design/prototype.md, "Packs"): entries sorted
//! by path, mtimes 0, uid and gid 0, no host names, so the same tree makes
//! the same bytes; and flattening layers with their whiteouts applied.
//!
//! A `Writer` writes ustar entries, with a PAX header for a path or link
//! target too long for ustar, or a size too large for it. A `Tree` gathers
//! one or more layer directories, and any in-memory files, into one sorted
//! tree, and writes it to a `Writer`:
//!
//!   var tree: tar.Tree = .init(arena, io);
//!   try tree.addLayer(base, .apply);
//!   try tree.addLayer(app, .apply);
//!   try tree.addBytes(".h9x/pack.json", 0o644, json);
//!   var w: tar.Writer = .init(gpa, out);
//!   try tree.write(&w);
//!   try w.finish();
//!
//! Layers are OCI layers, unpacked, as h9's `up` mounts make them
//! (hyper9's design/upper-layers.md): `.wh.NAME` hides NAME in the layers
//! below, and `.wh..wh..opq` in a directory hides everything below it.
//! `.apply` follows them and leaves them out, which is how a pack is
//! flattened; `.keep` writes them as the empty files they are, which is
//! how an OCI layer is exported.
//!
//! Owned by W3.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const index = @import("index.zig");

pub const block_size = 512;

/// The prefix of a whiteout's name.
pub const whiteout_prefix = ".wh.";
/// The name of an opaque directory's marker.
pub const opaque_marker = ".wh..wh..opq";

/// The entry kinds h9x writes. Hard links are written as copies, and
/// devices and sockets are left out: a layer h9 makes has neither.
pub const Kind = enum {
    file,
    dir,
    symlink,
    fifo,

    fn typeflag(k: Kind) u8 {
        return switch (k) {
            .file => '0',
            .dir => '5',
            .symlink => '2',
            .fifo => '6',
        };
    }
};

/// What a tar entry's header says, besides its path.
pub const Meta = struct {
    kind: Kind,
    /// The permission bits, with setuid, setgid, and sticky.
    mode: u32,
    /// The data's length; 0 for anything but a file.
    size: u64 = 0,
    /// A symbolic link's target.
    target: []const u8 = "",
};

/// Writes a tar to `out` entry by entry, tracking the offset of each one,
/// and, when `entries` is set, recording each in it for the index.
pub const Writer = struct {
    out: *Io.Writer,
    /// Bytes written so far.
    offset: u64 = 0,
    /// Each entry written, for `index.finish`. Paths are copied.
    entries: ?*std.ArrayList(index.Entry) = null,
    gpa: Allocator,

    pub const Error = Io.Writer.Error || Allocator.Error || error{InvalidPath};

    pub fn init(gpa: Allocator, out: *Io.Writer) Writer {
        return .{ .gpa = gpa, .out = out };
    }

    /// Writes an entry's header, and its PAX header first if it needs one.
    /// A file's data follows with `data` or `stream`. `path` is relative,
    /// with `/` separators and no trailing slash.
    pub fn header(w: *Writer, path: []const u8, meta: Meta) Error!void {
        try checkPath(path);
        const dir_suffix: []const u8 = if (meta.kind == .dir) "/" else "";
        const name_len = path.len + dir_suffix.len;
        const long_name = name_len > 100;
        const long_target = meta.target.len > 100;
        const big = meta.size > max_octal_11;
        if (long_name or long_target or big) {
            var pax: Io.Writer.Allocating = .init(w.gpa);
            defer pax.deinit();
            const pw = &pax.writer;
            if (long_name) paxRecord(pw, "path", &.{ path, dir_suffix }) catch return error.OutOfMemory;
            if (long_target) paxRecord(pw, "linkpath", &.{meta.target}) catch return error.OutOfMemory;
            if (big) {
                var buf: [24]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{meta.size}) catch unreachable;
                paxRecord(pw, "size", &.{s}) catch return error.OutOfMemory;
            }
            const records = pax.written();
            var h: Header = .{ .typeflag = 'x' };
            h.setName(&.{"././@PaxHeader"});
            h.setOctal(&h.size, records.len);
            h.setOctal(&h.mode, 0o644);
            h.finish();
            try w.out.writeAll(std.mem.asBytes(&h));
            try w.out.writeAll(records);
            try w.out.splatByteAll(0, padding(records.len));
            w.offset += block_size + records.len + padding(records.len);
        }
        var h: Header = .{ .typeflag = meta.kind.typeflag() };
        if (long_name) h.setName(&.{truncate(path, 100)}) else h.setName(&.{ path, dir_suffix });
        h.setOctal(&h.mode, meta.mode & 0o7777);
        h.setOctal(&h.size, if (big) 0 else meta.size);
        if (meta.kind == .symlink) @memcpy(h.linkname[0..@min(meta.target.len, 100)], truncate(meta.target, 100));
        h.finish();
        try w.out.writeAll(std.mem.asBytes(&h));
        w.offset += block_size;
        if (w.entries) |list| {
            try list.append(w.gpa, .{
                .kind = meta.kind,
                .mode = meta.mode & 0o7777,
                .offset = w.offset,
                .size = meta.size,
                .path = try w.gpa.dupe(u8, path),
                .target = if (meta.kind == .symlink) try w.gpa.dupe(u8, meta.target) else "",
            });
        }
    }

    pub fn dir(w: *Writer, path: []const u8, mode: u32) Error!void {
        try w.header(path, .{ .kind = .dir, .mode = mode });
    }

    pub fn symlink(w: *Writer, path: []const u8, target: []const u8) Error!void {
        try w.header(path, .{ .kind = .symlink, .mode = 0o777, .target = target });
    }

    /// A file whose data is `bytes`.
    pub fn file(w: *Writer, path: []const u8, mode: u32, bytes: []const u8) Error!void {
        try w.header(path, .{ .kind = .file, .mode = mode, .size = bytes.len });
        try w.out.writeAll(bytes);
        try w.pad(bytes.len);
    }

    /// A file whose `size` bytes come from `in`: exactly that many, or
    /// error.EndOfStream.
    pub fn fileStream(w: *Writer, path: []const u8, mode: u32, size: u64, in: *Io.Reader) (Error || Io.Reader.StreamError)!void {
        try w.header(path, .{ .kind = .file, .mode = mode, .size = size });
        try in.streamExact64(w.out, size);
        try w.pad(size);
    }

    /// Pads a file's data, after `size` bytes of it, to a whole block.
    pub fn pad(w: *Writer, size: u64) Io.Writer.Error!void {
        const p = padding(size);
        try w.out.splatByteAll(0, p);
        w.offset += size + p;
    }

    /// The two zero blocks that end an archive.
    pub fn finish(w: *Writer) Io.Writer.Error!void {
        try w.out.splatByteAll(0, 2 * block_size);
        w.offset += 2 * block_size;
    }
};

const max_octal_11 = (1 << 33) - 1;

/// The bytes that pad `size` to a whole block.
pub fn padding(size: u64) usize {
    return @intCast((block_size - size % block_size) % block_size);
}

fn truncate(s: []const u8, n: usize) []const u8 {
    return s[0..@min(s.len, n)];
}

/// A path h9x writes is relative, with no empty, `.`, or `..` parts.
fn checkPath(path: []const u8) error{InvalidPath}!void {
    if (path.len == 0) return error.InvalidPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, "..")) return error.InvalidPath;
    }
}

/// A PAX record, `LEN KEY=VALUE\n`, where LEN counts itself.
fn paxRecord(w: *Io.Writer, key: []const u8, value: []const []const u8) Io.Writer.Error!void {
    var vlen: usize = 0;
    for (value) |v| vlen += v.len;
    const rest = 1 + key.len + 1 + vlen + 1; // " KEY=VALUE\n"
    var len = rest + 1;
    while (std.math.log10_int(len) + 1 + rest != len) len = std.math.log10_int(len) + 1 + rest;
    try w.print("{d} {s}=", .{ len, key });
    for (value) |v| try w.writeAll(v);
    try w.writeByte('\n');
}

/// A ustar header: owner 0, mtime 0, and no user or group names.
const Header = extern struct {
    name: [100]u8 = @splat(0),
    mode: [8]u8 = @splat(0),
    uid: [8]u8 = "0000000\x00".*,
    gid: [8]u8 = "0000000\x00".*,
    size: [12]u8 = @splat(0),
    mtime: [12]u8 = "00000000000\x00".*,
    chksum: [8]u8 = @splat(' '),
    typeflag: u8,
    linkname: [100]u8 = @splat(0),
    magic: [6]u8 = "ustar\x00".*,
    version: [2]u8 = "00".*,
    uname: [32]u8 = @splat(0),
    gname: [32]u8 = @splat(0),
    devmajor: [8]u8 = "0000000\x00".*,
    devminor: [8]u8 = "0000000\x00".*,
    prefix: [155]u8 = @splat(0),
    pad: [12]u8 = @splat(0),

    comptime {
        std.debug.assert(@sizeOf(Header) == block_size);
    }

    fn setName(h: *Header, parts: []const []const u8) void {
        var i: usize = 0;
        for (parts) |p| {
            const n = @min(p.len, h.name.len - i);
            @memcpy(h.name[i..][0..n], p[0..n]);
            i += n;
        }
    }

    /// Zero-padded octal, with a NUL, filling the field.
    fn setOctal(_: *Header, field: anytype, value: u64) void {
        const n = field.len - 1;
        var v = value;
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            field[i] = '0' + @as(u8, @intCast(v & 7));
            v >>= 3;
        }
        field[n] = 0;
    }

    fn finish(h: *Header) void {
        var sum: u32 = 0;
        for (std.mem.asBytes(h)) |b| sum += b;
        // Six digits, a NUL, and a space, as tar writes it.
        var v = sum;
        var i: usize = 6;
        while (i > 0) {
            i -= 1;
            h.chksum[i] = '0' + @as(u8, @intCast(v & 7));
            v >>= 3;
        }
        h.chksum[6] = 0;
        h.chksum[7] = ' ';
    }
};

// ---------------------------------------------------------------- trees

/// One or more layers, and in-memory files, merged into one tree, written
/// sorted by path. Its memory is an arena's: nodes, names, and link
/// targets live as long as it does. The layer directories are borrowed and
/// must stay open until `write` returns.
pub const Tree = struct {
    arena: Allocator,
    io: Io,
    layers: std.ArrayList(Io.Dir) = .empty,
    root: Node = .{ .meta = .{ .kind = .dir, .mode = 0o755 } },

    /// How a layer's `.wh.` names are taken.
    pub const Whiteouts = enum {
        /// Hide what they name in the layers below, and leave them out.
        apply,
        /// Keep them as the empty files they are, as an OCI layer does.
        keep,
    };

    pub const Node = struct {
        meta: Meta,
        /// Where a file's data comes from.
        source: union(enum) {
            none,
            /// The index in `layers` of the layer that holds it, at the
            /// node's path.
            layer: u32,
            bytes: []const u8,
        } = .none,
        children: std.StringArrayHashMapUnmanaged(*Node) = .empty,
    };

    pub fn init(arena: Allocator, io: Io) Tree {
        return .{ .arena = arena, .io = io };
    }

    /// Stacks `dir` on the tree's layers so far.
    pub fn addLayer(t: *Tree, dir: Io.Dir, whiteouts: Whiteouts) !void {
        const n: u32 = @intCast(t.layers.items.len);
        try t.layers.append(t.arena, dir);
        var path: std.ArrayList(u8) = .empty;
        try t.merge(&t.root, dir, &path, n, whiteouts);
    }

    fn merge(t: *Tree, node: *Node, dir: Io.Dir, path: *std.ArrayList(u8), layer: u32, whiteouts: Whiteouts) !void {
        const io = t.io;
        var d = try dir.openDir(io, if (path.items.len == 0) "." else path.items, .{ .iterate = true });
        defer d.close(io);

        // Whiteouts hide names in the layers below this one, never in it,
        // so they're read first.
        var names: std.ArrayList([]const u8) = .empty;
        var it = d.iterate();
        while (try it.next(io)) |e| try names.append(t.arena, try t.arena.dupe(u8, e.name));
        std.mem.sort([]const u8, names.items, {}, lessThan);
        if (whiteouts == .apply) {
            for (names.items) |name| {
                if (std.mem.eql(u8, name, opaque_marker)) {
                    node.children.clearRetainingCapacity();
                } else if (std.mem.startsWith(u8, name, whiteout_prefix)) {
                    _ = node.children.orderedRemove(name[whiteout_prefix.len..]);
                }
            }
        }

        const base = path.items.len;
        defer path.shrinkRetainingCapacity(base);
        for (names.items) |name| {
            if (whiteouts == .apply and std.mem.startsWith(u8, name, whiteout_prefix)) continue;
            path.shrinkRetainingCapacity(base);
            if (base > 0) try path.append(t.arena, '/');
            try path.appendSlice(t.arena, name);

            const st = try dir.statFile(io, path.items, .{ .follow_symlinks = false });
            const mode: u32 = @intCast(st.permissions.toMode() & 0o7777);
            const meta: Meta = switch (st.kind) {
                .file => .{ .kind = .file, .mode = mode, .size = st.size },
                .directory => .{ .kind = .dir, .mode = mode },
                .sym_link => blk: {
                    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
                    const len = try dir.readLink(io, path.items, &buf);
                    break :blk .{ .kind = .symlink, .mode = 0o777, .target = try t.arena.dupe(u8, buf[0..len]) };
                },
                .named_pipe => .{ .kind = .fifo, .mode = mode },
                // A device or socket has no place in a layer h9 makes.
                else => continue,
            };

            const gop = try node.children.getOrPut(t.arena, name);
            if (!gop.found_existing) {
                gop.key_ptr.* = name;
                gop.value_ptr.* = try t.arena.create(Node);
                gop.value_ptr.*.* = .{ .meta = meta };
            }
            const child = gop.value_ptr.*;
            // An upper directory merges with a lower one; anything else
            // replaces what was there.
            if (meta.kind != .dir or child.meta.kind != .dir) child.children = .empty;
            child.meta = meta;
            child.source = if (meta.kind == .file) .{ .layer = layer } else .none;
            if (meta.kind == .dir) try t.merge(child, dir, path, layer, whiteouts);
        }
    }

    /// Adds a file with `bytes` as its data, making its parents (mode 0755)
    /// where the tree has none. It replaces whatever is at `path`.
    pub fn addBytes(t: *Tree, path: []const u8, mode: u32, bytes: []const u8) !void {
        try checkPath(path);
        var node = &t.root;
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |name| {
            const last = parts.peek() == null;
            const gop = try node.children.getOrPut(t.arena, name);
            if (!gop.found_existing) {
                gop.key_ptr.* = try t.arena.dupe(u8, name);
                gop.value_ptr.* = try t.arena.create(Node);
                gop.value_ptr.*.* = .{ .meta = .{ .kind = .dir, .mode = 0o755 } };
            }
            const child = gop.value_ptr.*;
            if (last) {
                child.* = .{
                    .meta = .{ .kind = .file, .mode = mode, .size = bytes.len },
                    .source = .{ .bytes = try t.arena.dupe(u8, bytes) },
                };
            } else if (child.meta.kind != .dir) {
                child.* = .{ .meta = .{ .kind = .dir, .mode = 0o755 } };
            }
            node = child;
        }
    }

    /// Writes every entry, depth first with each directory's names sorted,
    /// so a directory comes before what's in it. The tree's root isn't an
    /// entry. Doesn't finish the archive.
    pub fn write(t: *Tree, w: *Writer) !void {
        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(w.gpa);
        var buf: [64 * 1024]u8 = undefined;
        try t.writeNode(&t.root, w, &path, &buf);
    }

    fn writeNode(t: *Tree, node: *Node, w: *Writer, path: *std.ArrayList(u8), buf: []u8) !void {
        const gpa = w.gpa;
        const names = try gpa.dupe([]const u8, node.children.keys());
        defer gpa.free(names);
        std.mem.sort([]const u8, names, {}, lessThan);
        const base = path.items.len;
        defer path.shrinkRetainingCapacity(base);
        for (names) |name| {
            const child = node.children.get(name).?;
            path.shrinkRetainingCapacity(base);
            if (base > 0) try path.append(gpa, '/');
            try path.appendSlice(gpa, name);
            switch (child.source) {
                .none => try w.header(path.items, child.meta),
                .bytes => |b| try w.file(path.items, child.meta.mode, b),
                .layer => |l| {
                    const f = try t.layers.items[l].openFile(t.io, path.items, .{});
                    defer f.close(t.io);
                    var r = f.reader(t.io, buf);
                    w.fileStream(path.items, child.meta.mode, child.meta.size, &r.interface) catch |e| switch (e) {
                        error.ReadFailed => return r.err.?,
                        error.EndOfStream => return error.FileChanged,
                        else => |x| return x,
                    };
                },
            }
            if (child.meta.kind == .dir) try t.writeNode(child, w, path, buf);
        }
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Writes `dir` as one deterministic tar, with its whiteouts kept, as an
/// OCI layer. Finishes the archive.
pub fn writeLayer(gpa: Allocator, io: Io, dir: Io.Dir, out: *Io.Writer) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var tree: Tree = .init(arena.allocator(), io);
    try tree.addLayer(dir, .keep);
    var w: Writer = .init(gpa, out);
    try tree.write(&w);
    try w.finish();
}

/// Writes `layers`, bottom first, flattened into one deterministic tar,
/// with their whiteouts applied. Finishes the archive.
pub fn flatten(gpa: Allocator, io: Io, layers: []const Io.Dir, out: *Io.Writer) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var tree: Tree = .init(arena.allocator(), io);
    for (layers) |l| try tree.addLayer(l, .apply);
    var w: Writer = .init(gpa, out);
    try tree.write(&w);
    try w.finish();
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Reads a tar back with std.tar, as h9's `--archive` does, into
/// `KIND MODE PATH[ -> TARGET][ [DATA]]` lines.
fn listing(gpa: Allocator, bytes: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var in: Io.Reader = .fixed(bytes);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&in, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    while (try it.next()) |f| {
        try out.writer.print("{t} {o} {s}", .{ f.kind, f.mode, f.name });
        switch (f.kind) {
            .sym_link => try out.writer.print(" -> {s}", .{f.link_name}),
            .file => {
                try out.writer.writeAll(" [");
                try it.streamRemaining(f, &out.writer);
                try out.writer.writeByte(']');
            },
            else => {},
        }
        try out.writer.writeByte('\n');
    }
    return out.toOwnedSlice();
}

fn mkfile(dir: Io.Dir, path: []const u8, data: []const u8) !void {
    const io = testing.io;
    if (std.fs.path.dirname(path)) |d| try dir.createDirPath(io, d);
    try dir.writeFile(io, .{ .sub_path = path, .data = data, .flags = .{ .permissions = .fromMode(0o644) } });
}

test "a layer is written sorted, with whiteouts kept" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try mkfile(tmp.dir, "b/z", "z");
    try mkfile(tmp.dir, "b/a", "a");
    try mkfile(tmp.dir, "a.txt", "hello");
    try mkfile(tmp.dir, "b/.wh.gone", "");
    try tmp.dir.symLink(io, "a.txt", "link", .{});
    var b = try tmp.dir.openDir(io, "b", .{ .iterate = true });
    try b.setPermissions(io, .fromMode(0o750));
    b.close(io);

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeLayer(testing.allocator, io, tmp.dir, &out.writer);
    try testing.expect(out.written().len % block_size == 0);

    const got = try listing(testing.allocator, out.written());
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\file 644 a.txt [hello]
        \\directory 750 b/
        \\file 644 b/.wh.gone []
        \\file 644 b/a [a]
        \\file 644 b/z [z]
        \\sym_link 777 link -> a.txt
        \\
    , got);
}

test "the same tree makes the same bytes" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "x");
    try tmp.dir.createDirPath(io, "y");
    // The same files, made in a different order, at different times.
    try mkfile(tmp.dir, "x/one", "1");
    try mkfile(tmp.dir, "x/two", "2");
    try mkfile(tmp.dir, "y/two", "2");
    try mkfile(tmp.dir, "y/one", "1");
    var x = try tmp.dir.openDir(io, "x", .{ .iterate = true });
    defer x.close(io);
    var y = try tmp.dir.openDir(io, "y", .{ .iterate = true });
    defer y.close(io);
    try x.setPermissions(io, .fromMode(0o755));
    try y.setPermissions(io, .fromMode(0o755));

    var a: Io.Writer.Allocating = .init(testing.allocator);
    defer a.deinit();
    var b: Io.Writer.Allocating = .init(testing.allocator);
    defer b.deinit();
    try writeLayer(testing.allocator, io, x, &a.writer);
    try writeLayer(testing.allocator, io, y, &b.writer);
    try testing.expectEqualSlices(u8, a.written(), b.written());
}

test "flatten applies whiteouts and opaque directories" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // base: etc/motd, etc/hosts, usr/lib/a, usr/lib/b, opt/x
    try mkfile(tmp.dir, "base/etc/motd", "welcome");
    try mkfile(tmp.dir, "base/etc/hosts", "localhost");
    try mkfile(tmp.dir, "base/usr/lib/a", "a");
    try mkfile(tmp.dir, "base/usr/lib/b", "b");
    try mkfile(tmp.dir, "base/opt/x", "x");
    try mkfile(tmp.dir, "base/app", "a file, then a directory");
    // run: removes etc/motd and opt, replaces usr/lib, changes etc/hosts,
    // and makes app a directory.
    try mkfile(tmp.dir, "run/etc/.wh.motd", "");
    try mkfile(tmp.dir, "run/etc/hosts", "127.0.0.1 localhost");
    try mkfile(tmp.dir, "run/.wh.opt", "");
    try mkfile(tmp.dir, "run/usr/lib/.wh..wh..opq", "");
    try mkfile(tmp.dir, "run/usr/lib/c", "c");
    try mkfile(tmp.dir, "run/app/server.js", "listen()");
    // A whiteout hides lower layers only, never its own.
    try mkfile(tmp.dir, "run/etc/.wh.hosts", "");

    var dirs: [2]Io.Dir = undefined;
    for (&dirs, [_][]const u8{ "base", "run" }) |*d, name| d.* = try tmp.dir.openDir(io, name, .{});
    defer for (dirs) |d| d.close(io);

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try flatten(testing.allocator, io, &dirs, &out.writer);
    const got = try listing(testing.allocator, out.written());
    defer testing.allocator.free(got);
    // Directory modes are the umask's, so only the names are compared.
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(testing.allocator);
    var lines = std.mem.splitScalar(u8, got, '\n');
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        var f = std.mem.splitScalar(u8, l, ' ');
        _ = f.next();
        _ = f.next();
        try names.appendSlice(testing.allocator, f.rest());
        try names.append(testing.allocator, '\n');
    }
    try testing.expectEqualStrings(
        \\app/
        \\app/server.js [listen()]
        \\etc/
        \\etc/hosts [127.0.0.1 localhost]
        \\usr/
        \\usr/lib/
        \\usr/lib/c [c]
        \\
    , names.items);
}

test "long paths and link targets get a PAX header" {
    const io = testing.io;
    const long = repeat("d", 60) ++ "/" ++ repeat("f", 70);
    const target = repeat("t", 150);
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tree: Tree = .init(arena.allocator(), io);
    try tree.addBytes(long, 0o600, "data");
    var w: Writer = .init(testing.allocator, &out.writer);
    try tree.write(&w);
    try w.symlink("l", target);
    try w.finish();
    try testing.expectEqual(w.offset, out.written().len);

    const got = try listing(testing.allocator, out.written());
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("directory 755 " ++ repeat("d", 60) ++ "/\nfile 600 " ++ long ++ " [data]\nsym_link 777 l -> " ++ target ++ "\n", got);
}

test "a path that climbs out is refused" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var w: Writer = .init(testing.allocator, &out.writer);
    try testing.expectError(error.InvalidPath, w.file("../x", 0o644, ""));
    try testing.expectError(error.InvalidPath, w.file("/x", 0o644, ""));
    try testing.expectError(error.InvalidPath, w.file("a//b", 0o644, ""));
}

test paxRecord {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try paxRecord(&out.writer, "path", &.{"abc"});
    try testing.expectEqualStrings("12 path=abc\n", out.written());
    out.clearRetainingCapacity();
    // 98 bytes without the length, so the length's own digits push it to
    // three of them.
    try paxRecord(&out.writer, "path", &.{repeat("x", 91)});
    try testing.expectEqual(@as(usize, 101), out.written().len);
    try testing.expect(std.mem.startsWith(u8, out.written(), "101 path="));
}

/// `s` `n` times, at comptime.
fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    comptime var out: [s.len * n]u8 = undefined;
    inline for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
    const final = out;
    return &final;
}
