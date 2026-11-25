//! The pack index: the tar's last entry, `/.h9x/index`, listing each
//! entry's path, offset, and size, so a reader can open any file in the
//! archive with one seek and without reading the rest.
//!
//! It's text, one line per entry in the tar's order, after a version line:
//!
//!   h9x-index 1
//!   KIND\tMODE\tOFFSET\tSIZE\tPATH[\tTARGET]
//!   ...
//!   end\tOFFSET
//!
//! KIND is `f` (a file), `d` (a directory), `l` (a symbolic link, with its
//! TARGET), or `p` (a FIFO). MODE is octal. OFFSET is where the entry's
//! data starts, from the start of the archive, after its headers, and SIZE
//! its length: a file's data is the bytes OFFSET to OFFSET+SIZE. PATH is
//! the tar's, relative, without a leading `/`; it and TARGET escape `\`,
//! tab, and newline as `\\`, `\t`, and `\n`. A line starting with `#` is
//! padding.
//!
//! The last line is `end`, with the index's own OFFSET as 20 decimal
//! digits, and it ends the entry's last block: the index is padded so that
//! the archive's last 1536 bytes are that block and the two zero blocks.
//! So `locate` finds the index from the archive's tail alone, and the
//! runner, given the archive's offset and length by the trailer, reads the
//! tail, then the index, then the files it needs.
//!
//! Owned by W3.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tar = @import("tar.zig");

/// The index's path in the archive.
pub const path = ".h9x/index";
pub const version_line = "h9x-index 1";
/// How much of the archive's end `locate` needs.
pub const tail_len = 3 * tar.block_size;

const end_line_len = "end\t".len + 20 + "\n".len;

pub const Entry = struct {
    kind: tar.Kind,
    mode: u32,
    /// Where the data starts, from the start of the archive.
    offset: u64,
    size: u64,
    path: []const u8,
    /// A symbolic link's target; empty otherwise.
    target: []const u8 = "",
};

/// The index's text for `entries`, when its data starts at `offset`.
pub fn encode(gpa: Allocator, entries: []const Entry, offset: u64) Allocator.Error![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    encodeTo(&out.writer, entries, offset) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn encodeTo(w: *Io.Writer, entries: []const Entry, offset: u64) Io.Writer.Error!void {
    var counter: Io.Writer.Discarding = .init(&.{});
    for ([_]*Io.Writer{ &counter.writer, w }) |out| {
        try out.writeAll(version_line ++ "\n");
        for (entries) |e| {
            try out.print("{c}\t{o}\t{d}\t{d}\t", .{ kindChar(e.kind), e.mode, e.offset, e.size });
            try escape(out, e.path);
            if (e.kind == .symlink) {
                try out.writeByte('\t');
                try escape(out, e.target);
            }
            try out.writeByte('\n');
        }
        if (out == w) {
            const len = counter.fullCount() + end_line_len;
            var pad = (tar.block_size - len % tar.block_size) % tar.block_size;
            if (pad == 1) pad += tar.block_size;
            if (pad > 0) {
                try w.writeByte('#');
                try w.splatByteAll(' ', pad - 2);
                try w.writeByte('\n');
            }
            try w.print("end\t{d:0>20}\n", .{offset});
        }
    }
}

/// Writes the index of every entry `w` has recorded as the archive's last
/// entry, then the two zero blocks that end it. `w.entries` must be set.
pub fn finish(w: *tar.Writer) !void {
    const entries = w.entries.?.items;
    // The index's path is short, so its data follows its one header.
    const offset = w.offset + tar.block_size;
    const text = try encode(w.gpa, entries, offset);
    defer w.gpa.free(text);
    const saved = w.entries;
    w.entries = null;
    defer w.entries = saved;
    try w.file(path, 0o644, text);
    std.debug.assert(w.offset - text.len == offset);
    try w.finish();
}

/// Frees what `tar.Writer` recorded in `entries`, and the list.
pub fn deinitEntries(gpa: Allocator, entries: *std.ArrayList(Entry)) void {
    for (entries.items) |e| {
        gpa.free(e.path);
        gpa.free(e.target);
    }
    entries.deinit(gpa);
}

/// Where the index's text starts in an archive `len` bytes long, from the
/// archive's last `tail_len` bytes (or all of it, if it's shorter). The
/// text is the bytes from there to `len - 2 * tar.block_size`.
pub fn locate(tail: []const u8, len: u64) error{NoIndex}!u64 {
    const zeros = 2 * tar.block_size;
    if (tail.len < zeros + end_line_len) return error.NoIndex;
    for (tail[tail.len - zeros ..]) |b| if (b != 0) return error.NoIndex;
    const line = tail[tail.len - zeros - end_line_len .. tail.len - zeros];
    if (!std.mem.startsWith(u8, line, "end\t") or line[line.len - 1] != '\n') return error.NoIndex;
    const offset = std.fmt.parseUnsigned(u64, line[4 .. line.len - 1], 10) catch return error.NoIndex;
    if (offset + end_line_len + zeros > len) return error.NoIndex;
    return offset;
}

pub const ParseError = Allocator.Error || error{BadIndex};

/// The entries in an index's text. Paths and targets are allocated with
/// `arena`, which owns them.
pub fn parse(arena: Allocator, text: []const u8) ParseError![]Entry {
    var lines = std.mem.splitScalar(u8, text, '\n');
    if (!std.mem.eql(u8, lines.next() orelse "", version_line)) return error.BadIndex;
    var entries: std.ArrayList(Entry) = .empty;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const k = f.next().?;
        if (std.mem.eql(u8, k, "end")) return entries.toOwnedSlice(arena);
        if (k.len != 1) return error.BadIndex;
        const kind = kindOf(k[0]) orelse return error.BadIndex;
        const mode = std.fmt.parseUnsigned(u32, f.next() orelse return error.BadIndex, 8) catch return error.BadIndex;
        const offset = std.fmt.parseUnsigned(u64, f.next() orelse return error.BadIndex, 10) catch return error.BadIndex;
        const size = std.fmt.parseUnsigned(u64, f.next() orelse return error.BadIndex, 10) catch return error.BadIndex;
        const p = try unescape(arena, f.next() orelse return error.BadIndex);
        const target = if (kind == .symlink) try unescape(arena, f.next() orelse return error.BadIndex) else "";
        if (f.next() != null) return error.BadIndex;
        try entries.append(arena, .{ .kind = kind, .mode = mode, .offset = offset, .size = size, .path = p, .target = target });
    }
    // No `end` line: the text was cut short.
    return error.BadIndex;
}

/// Reads and parses the index of the archive at `offset` in `file`, `len`
/// bytes long: a pack, or the archive in a packed executable.
pub fn read(arena: Allocator, io: Io, file: Io.File, offset: u64, len: u64) ![]Entry {
    var tail_buf: [tail_len]u8 = undefined;
    const n: usize = @intCast(@min(len, tail_len));
    const tail = tail_buf[0..n];
    if (try file.readPositionalAll(io, tail, offset + len - n) != n) return error.NoIndex;
    const at = try locate(tail, len);
    const text = try arena.alloc(u8, @intCast(len - 2 * tar.block_size - at));
    if (try file.readPositionalAll(io, text, offset + at) != text.len) return error.NoIndex;
    return parse(arena, text);
}

/// The entry for `p`, by a linear search: an index is read once per run,
/// and a caller that looks up many paths can build a map.
pub fn find(entries: []const Entry, p: []const u8) ?Entry {
    for (entries) |e| if (std.mem.eql(u8, e.path, p)) return e;
    return null;
}

fn kindChar(k: tar.Kind) u8 {
    return switch (k) {
        .file => 'f',
        .dir => 'd',
        .symlink => 'l',
        .fifo => 'p',
    };
}

fn kindOf(c: u8) ?tar.Kind {
    return switch (c) {
        'f' => .file,
        'd' => .dir,
        'l' => .symlink,
        'p' => .fifo,
        else => null,
    };
}

fn escape(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '\t' => try w.writeAll("\\t"),
        '\n' => try w.writeAll("\\n"),
        else => try w.writeByte(c),
    };
}

fn unescape(arena: Allocator, s: []const u8) ParseError![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return arena.dupe(u8, s);
    var out: std.ArrayList(u8) = try .initCapacity(arena, s.len);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\') {
            out.appendAssumeCapacity(s[i]);
            continue;
        }
        i += 1;
        if (i == s.len) return error.BadIndex;
        out.appendAssumeCapacity(switch (s[i]) {
            '\\' => '\\',
            't' => '\t',
            'n' => '\n',
            else => return error.BadIndex,
        });
    }
    return out.items;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// A pack-shaped archive: a tree, a file `index.finish` indexes, and the
/// index.
fn packed_(gpa: Allocator, io: Io, out: *Io.Writer, files: []const [2][]const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var tree: tar.Tree = .init(arena.allocator(), io);
    for (files) |f| try tree.addBytes(f[0], 0o644, f[1]);
    var entries: std.ArrayList(Entry) = .empty;
    defer deinitEntries(gpa, &entries);
    var w: tar.Writer = .init(gpa, out);
    w.entries = &entries;
    try tree.write(&w);
    try w.symlink("usr/bin/sh", "busybox");
    try finish(&w);
}

test "the index is the last entry, and points at each file" {
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const files = [_][2][]const u8{
        .{ "usr/bin/busybox", "#!busybox" },
        .{ "app/server.js", "listen(8080)" },
        .{ "app/we\tird\nname\\", "odd" },
        .{ "app/" ++ repeat("long/", 40) ++ "file", "deep" },
    };
    try packed_(gpa, testing.io, &out.writer, &files);
    const bytes = out.written();
    try testing.expect(bytes.len % tar.block_size == 0);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const at = try locate(bytes[bytes.len - tail_len ..], bytes.len);
    const entries = try parse(arena.allocator(), bytes[at .. bytes.len - 2 * tar.block_size]);
    for (files) |f| {
        const e = find(entries, f[0]) orelse return error.TestExpectedEqual;
        try testing.expectEqual(tar.Kind.file, e.kind);
        try testing.expectEqualStrings(f[1], bytes[e.offset..][0..e.size]);
    }
    const sh = find(entries, "usr/bin/sh").?;
    try testing.expectEqualStrings("busybox", sh.target);
    try testing.expectEqual(tar.Kind.dir, find(entries, "app").?.kind);
    try testing.expect(find(entries, path) == null);

    // std.tar, as h9's --archive, sees the index as the last file.
    var in: Io.Reader = .fixed(bytes);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&in, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var last: []const u8 = "";
    var data: Io.Writer.Allocating = .init(gpa);
    defer data.deinit();
    while (try it.next()) |f| {
        last = f.name;
        data.clearRetainingCapacity();
        if (f.kind == .file) try it.streamRemaining(f, &data.writer);
    }
    try testing.expectEqualStrings(path, last);
    try testing.expectEqualStrings(bytes[at .. bytes.len - 2 * tar.block_size], data.written());
}

test "the index ends its last block, whatever its length" {
    const gpa = testing.allocator;
    var name: [600]u8 = @splat('n');
    // Every remainder of the index's length, through a whole block, so the
    // one-byte padding case is covered.
    for (1..tar.block_size + 2) |n| {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try packed_(gpa, testing.io, &out.writer, &.{.{ name[0..n], "x" }});
        const bytes = out.written();
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const at = try locate(bytes[bytes.len - tail_len ..], bytes.len);
        const entries = try parse(arena.allocator(), bytes[at .. bytes.len - 2 * tar.block_size]);
        try testing.expectEqualStrings("x", bytes[find(entries, name[0..n]).?.offset..][0..1]);
    }
}

test "read finds the index in a file at an offset" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    // An executable's image, then the archive, then a trailer.
    try out.writer.writeAll("\x7fELF" ++ repeat("\x00", 1000));
    const start = out.written().len;
    try packed_(gpa, io, &out.writer, &.{.{ "bin/app", "hello" }});
    const len = out.written().len - start;
    try out.writer.writeAll("H9XPACK\x00" ++ repeat("\x00", 24));
    try tmp.dir.writeFile(io, .{ .sub_path = "app", .data = out.written() });

    const f = try tmp.dir.openFile(io, "app", .{});
    defer f.close(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const entries = try read(arena.allocator(), io, f, start, len);
    const e = find(entries, "bin/app").?;
    var buf: [5]u8 = undefined;
    _ = try f.readPositionalAll(io, &buf, start + e.offset);
    try testing.expectEqualStrings("hello", &buf);
}

test "a tar without an index is refused" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var w: tar.Writer = .init(testing.allocator, &out.writer);
    try w.file("a", 0o644, "end\t00000000000000000000\n");
    try w.finish();
    const bytes = out.written();
    try testing.expectError(error.NoIndex, locate(bytes, bytes.len));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.BadIndex, parse(arena.allocator(), "h9x-index 1\nf\t644\t0\t0\ta\n"));
    try testing.expectError(error.BadIndex, parse(arena.allocator(), "h9x-index 2\nend\t0\n"));
}
/// `s` `n` times, at comptime.
fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    comptime var out: [s.len * n]u8 = undefined;
    inline for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
    const final = out;
    return &final;
}
