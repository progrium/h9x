//! Executable containers (design/prototype.md, "Packs"): joining a runner
//! and an archive for a target's OS, and reading one back for
//! `h9x pack --inspect`.
//!
//! Owned by W4. pack.zig (W8) calls `join`; cmd/pack.zig calls `inspect`.
//! The archive is opaque here, except that `inspect` looks for
//! `/.h9x/pack.json` in it to print.

const std = @import("std");
const types = @import("../types.zig");
const trailer = @import("trailer.zig");
const elf = @import("elf.zig");
const macho = @import("macho.zig");
const pe = @import("pe.zig");
const adhoc = @import("adhoc.zig");

pub const Container = types.Target.Container;

pub const JoinOptions = struct {
    /// The macOS signature's identifier: the executable's name, without a
    /// directory or extension.
    identifier: []const u8,
    /// The macOS signature's entitlements, each true.
    entitlements: []const []const u8 = &.{adhoc.hypervisor},
};

/// Where the archive went in the joined executable.
pub const Joined = struct {
    offset: u64,
    length: u64,
    size: u64,
};

/// Writes `runner` joined with the `len` bytes of `archive` to `out`, in
/// `container`'s way, ending in the trailer; macOS executables are signed
/// ad hoc. Nothing is read from `archive` but those bytes.
pub fn join(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    container: Container,
    runner: []const u8,
    archive: *std.Io.Reader,
    len: u64,
    opts: JoinOptions,
) !Joined {
    return switch (container) {
        .elf => j: {
            const l = try elf.join(out, runner, archive, len);
            break :j .{ .offset = l.offset, .length = l.length, .size = l.size };
        },
        .macho => j: {
            const l = try macho.join(gpa, out, runner, archive, len, .{ .identifier = opts.identifier, .entitlements = opts.entitlements });
            break :j .{ .offset = l.offset, .length = l.length, .size = l.size };
        },
        .pe => j: {
            const l = try pe.join(gpa, out, runner, archive, len);
            break :j .{ .offset = l.offset, .length = l.length, .size = l.size };
        },
    };
}

/// The container `head`, the start of a file, is in, or null.
pub fn detect(head: []const u8) ?Container {
    if (head.len >= 4 and std.mem.eql(u8, head[0..4], "\x7fELF")) return .elf;
    if (macho.isMachO(head)) return .macho;
    if (pe.isPe(head)) return .pe;
    return null;
}

/// What `inspect` found.
pub const Report = struct {
    file: []const u8,
    size: u64,
    container: ?Container,
    arch: []const u8,
    trailer: types.Trailer,
    /// The container's own record of the archive: `__H9X,__pack` or
    /// `.h9x`. Linux has none.
    section: ?struct { name: []const u8, offset: u64, size: u64, matches: bool },
    signature: ?struct {
        identifier: []const u8,
        entitlements: []const []const u8,
        der: bool,
        valid: bool,
    },
    /// The archive's sha256, in hex.
    digest: []const u8,
    /// `/.h9x/pack.json`, as it is in the archive, or null.
    pack_json: ?[]const u8,

    /// Whether everything that can be checked checks out.
    pub fn ok(r: Report) bool {
        if (r.section) |s| if (!s.matches) return false;
        if (r.signature) |s| if (!s.valid) return false;
        if (r.container == .macho and r.signature == null) return false;
        return true;
    }
};

pub const InspectError = error{NotPacked};

/// Reads a packed executable's trailer, its container's section, its
/// signature on macOS, the archive's digest, and its pack.json. Allocates
/// in `arena`.
pub fn inspect(arena: std.mem.Allocator, io: std.Io, path: []const u8) !Report {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = try file.length(io);
    const t = try trailer.read(io, file) orelse return error.NotPacked;
    const src: adhoc.Source = .{ .file = .{ .io = io, .file = file } };

    var head_len: u64 = @min(size, 64 * 1024);
    var head = try src.alloc(arena, 0, head_len);
    // A Mach-O header's load commands can run past the first 64 KB.
    if (detect(head) == .macho and head.len >= 24) {
        const want = 32 + @as(u64, std.mem.readInt(u32, head[20..24], .little));
        if (want > head_len and want <= size) {
            head_len = want;
            head = try src.alloc(arena, 0, head_len);
        }
    }

    var r: Report = .{
        .file = path,
        .size = size,
        .container = detect(head),
        .arch = "unknown",
        .trailer = t,
        .section = null,
        .signature = null,
        .digest = "",
        .pack_json = null,
    };
    if (r.container) |c| switch (c) {
        .elf => r.arch = elfArch(head),
        .macho => if (macho.parse(head)) |info| {
            r.arch = info.arch();
            if (info.pack) |p| r.section = .{
                .name = macho.segment_name ++ "," ++ macho.section_name,
                .offset = p.offset,
                .size = p.size,
                .matches = p.offset == t.offset and p.size == t.length,
            };
            if (info.signature) |s| {
                if (adhoc.inspect(arena, src, s.dataoff, s.datasize)) |sig| {
                    r.signature = .{
                        .identifier = sig.identifier,
                        .entitlements = try entitlementKeys(arena, sig.entitlements),
                        .der = sig.has_der,
                        .valid = sig.valid and sig.code_limit == s.dataoff,
                    };
                } else |_| r.signature = .{ .identifier = "", .entitlements = &.{}, .der = false, .valid = false };
            }
        } else |_| {},
        .pe => if (pe.parse(head)) |info| {
            r.arch = info.arch();
            if (info.pack) |p| r.section = .{
                .name = pe.section_name,
                .offset = p.offset,
                .size = p.size,
                .matches = p.offset == t.offset and p.size == t.length,
            };
        } else |_| {},
    };

    // The digest, read in pieces.
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var off = t.offset;
    while (off < t.offset + t.length) {
        const n: usize = @intCast(@min(buf.len, t.offset + t.length - off));
        try src.readAt(buf[0..n], off);
        h.update(buf[0..n]);
        off += n;
    }
    r.digest = try std.fmt.allocPrint(arena, "{x}", .{&h.finalResult()});
    r.pack_json = try findInTar(arena, src, t.offset, t.length, ".h9x/pack.json", 1 << 20);
    return r;
}

fn elfArch(head: []const u8) []const u8 {
    if (head.len < 20) return "unknown";
    const big = head[5] == 2;
    const m = std.mem.readInt(u16, head[18..20], if (big) .big else .little);
    return switch (m) {
        62 => "x86_64",
        183 => "arm64",
        else => "unknown",
    };
}

/// The `<key>`s of an entitlements plist.
fn entitlementKeys(arena: std.mem.Allocator, xml: []const u8) ![]const []const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    var rest = xml;
    while (std.mem.indexOf(u8, rest, "<key>")) |i| {
        rest = rest[i + 5 ..];
        const j = std.mem.indexOf(u8, rest, "</key>") orelse break;
        try keys.append(arena, rest[0..j]);
        rest = rest[j..];
    }
    return keys.items;
}

/// The contents of the regular file `want` (without a leading `/` or
/// `./`) in the tar at `off`, or null. Reads headers only, seeking over
/// file data, and understands ustar prefixes, pax `path` records, and GNU
/// long names.
pub fn findInTar(arena: std.mem.Allocator, src: adhoc.Source, off: u64, len: u64, want: []const u8, max: u64) !?[]const u8 {
    var pos: u64 = 0;
    var long_name: ?[]const u8 = null;
    var hdr: [512]u8 = undefined;
    while (pos + 512 <= len) {
        try src.readAt(&hdr, off + pos);
        if (std.mem.allEqual(u8, &hdr, 0)) return null;
        const size = octal(hdr[124..136]) orelse return null;
        const typ = hdr[156];
        const data = pos + 512;
        const next = data + std.mem.alignForward(u64, size, 512);
        var name: []const u8 = std.mem.sliceTo(hdr[0..100], 0);
        if (std.mem.eql(u8, hdr[257..262], "ustar")) {
            const prefix = std.mem.sliceTo(hdr[345..500], 0);
            if (prefix.len > 0) name = try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, name });
        }
        if (long_name) |n| name = n;
        long_name = null;
        switch (typ) {
            'x', 'L' => {
                if (size > 1 << 20 or data + size > len) return null;
                const b = try src.alloc(arena, off + data, size);
                long_name = if (typ == 'L') std.mem.sliceTo(b, 0) else paxPath(b);
            },
            '0', 0 => if (std.mem.eql(u8, trimName(name), want)) {
                if (size > max or data + size > len) return error.Truncated;
                return try src.alloc(arena, off + data, size);
            },
            else => {},
        }
        pos = next;
    }
    return null;
}

fn trimName(n: []const u8) []const u8 {
    var s = n;
    while (true) {
        if (std.mem.startsWith(u8, s, "./")) s = s[2..] else if (std.mem.startsWith(u8, s, "/")) s = s[1..] else break;
    }
    return s;
}

fn octal(field: []const u8) ?u64 {
    const s = std.mem.trim(u8, std.mem.sliceTo(field, 0), " ");
    if (s.len == 0) return 0;
    return std.fmt.parseInt(u64, s, 8) catch null;
}

/// The `path` record of a pax extended header, or null.
fn paxPath(b: []const u8) ?[]const u8 {
    var rest = b;
    while (rest.len > 0) {
        const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
        const n = std.fmt.parseInt(usize, rest[0..sp], 10) catch return null;
        if (n <= sp + 1 or n > rest.len) return null;
        const rec = rest[sp + 1 .. n - 1]; // without the newline
        if (std.mem.startsWith(u8, rec, "path=")) return rec[5..];
        rest = rest[n..];
    }
    return null;
}

/// Writes `r` as `pack --inspect` prints it.
pub fn writeText(w: *std.Io.Writer, r: Report) !void {
    try w.print("file       {s}\n", .{r.file});
    try w.print("container  {s}, {s}, {d} bytes\n", .{ if (r.container) |c| @tagName(c) else "unknown", r.arch, r.size });
    try w.print("archive    {d} bytes at {d} (trailer version {d})\n", .{ r.trailer.length, r.trailer.offset, r.trailer.version });
    if (r.section) |s| {
        try w.print("section    {s}, {d} bytes at {d}, {s}\n", .{ s.name, s.size, s.offset, if (s.matches) "matching the trailer" else "NOT matching the trailer" });
    } else if (r.container != .elf) try w.writeAll("section    none\n");
    if (r.signature) |s| {
        try w.print("signature  ad hoc, identifier {s}, {s}\n", .{ s.identifier, if (s.valid) "valid" else "INVALID" });
        for (s.entitlements) |e| try w.print("entitled   {s}\n", .{e});
    } else if (r.container == .macho) try w.writeAll("signature  none\n");
    try w.print("digest     sha256:{s}\n", .{r.digest});
    if (r.pack_json) |j| {
        try w.writeAll("pack.json\n");
        try w.writeAll(j);
        if (j.len > 0 and j[j.len - 1] != '\n') try w.writeByte('\n');
    } else try w.writeAll("pack.json  none\n");
}

/// Writes `r` as one JSON object, with pack.json inline when it parses.
pub fn writeJson(arena: std.mem.Allocator, w: *std.Io.Writer, r: Report) !void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("file");
    try s.write(r.file);
    try s.objectField("size");
    try s.write(r.size);
    try s.objectField("container");
    try s.write(if (r.container) |c| @tagName(c) else null);
    try s.objectField("arch");
    try s.write(r.arch);
    try s.objectField("archive");
    try s.write(.{ .offset = r.trailer.offset, .length = r.trailer.length, .version = r.trailer.version });
    if (r.section) |sec| {
        try s.objectField("section");
        try s.write(sec);
    }
    if (r.signature) |sig| {
        try s.objectField("signature");
        try s.write(sig);
    }
    try s.objectField("digest");
    try s.print("\"sha256:{s}\"", .{r.digest});
    try s.objectField("ok");
    try s.write(r.ok());
    if (r.pack_json) |j| {
        try s.objectField("pack");
        if (std.json.parseFromSliceLeaky(std.json.Value, arena, j, .{})) |v| try s.write(v) else |_| try s.write(j);
    }
    try s.endObject();
    try w.writeByte('\n');
}

test {
    _ = trailer;
    _ = elf;
    _ = macho;
    _ = pe;
    _ = adhoc;
}

test findInTar {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tar: [512 * 6]u8 = @splat(0);
    const Entry = struct { name: []const u8, typ: u8, data: []const u8 };
    var pos: usize = 0;
    for ([_]Entry{
        .{ .name = "./app/x", .typ = '0', .data = "hello" },
        .{ .name = "././@PaxHeader", .typ = 'x', .data = "25 path=./.h9x/pack.json\n" },
        .{ .name = "ignored", .typ = '0', .data = "{\"version\":1}" },
    }) |e| {
        const h = tar[pos..][0..512];
        @memcpy(h[0..e.name.len], e.name);
        _ = std.fmt.bufPrint(h[124..136], "{o:0>11}", .{e.data.len}) catch unreachable;
        h[156] = e.typ;
        @memcpy(h[257..262], "ustar");
        @memcpy(tar[pos + 512 ..][0..e.data.len], e.data);
        pos += 1024;
    }
    const src: adhoc.Source = .{ .bytes = &tar };
    const got = try findInTar(arena.allocator(), src, 0, tar.len, ".h9x/pack.json", 1024);
    try std.testing.expectEqualStrings("{\"version\":1}", got.?);
    try std.testing.expectEqual(@as(?[]const u8, null), try findInTar(arena.allocator(), src, 0, tar.len, "nope", 1024));
}
