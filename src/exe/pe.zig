//! Windows executables: the archive in a `.h9x` section, before any
//! certificate, then the trailer.
//!
//! Owned by W4. Treats the archive as opaque bytes.
//!
//! The section is added after the runner's last one, with its raw data on a
//! page in the file and its own range of the image, read-only. Any overlay
//! the runner had after its sections (a COFF symbol table, say) moves after
//! the archive, and the trailer ends the file. The runner's Authenticode
//! certificate, if it had one, can't cover the new section, so it's
//! dropped, and the checksum is cleared; signing with `osslsigncode` or
//! `signtool` after packing puts a certificate after the trailer, which the
//! runner still finds through the section table.

const std = @import("std");
const trailer = @import("trailer.zig");

pub const section_name = ".h9x";

pub const Error = error{
    NotPe,
    BadPe,
    AlreadyPacked,
    /// No room in the headers for one more section header.
    HeaderFull,
};

const section_header_size = 40;
const IMAGE_SCN_CNT_INITIALIZED_DATA = 0x00000040;
const IMAGE_SCN_MEM_READ = 0x40000000;
const dir_certificate = 4;

fn rd16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn wr16(b: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, b[off..][0..2], v, .little);
}
fn wr32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}

/// What `parse` finds in a PE file's headers.
pub const Info = struct {
    machine: u16,
    /// Offsets in the file of the COFF header, optional header, and
    /// section table.
    coff: usize,
    opt: usize,
    sections: usize,
    nsections: u16,
    pe32plus: bool,
    section_align: u32,
    file_align: u32,
    size_of_headers: u32,
    /// The certificate table's file range, if there is one.
    certificate: ?struct { offset: u32, size: u32 },
    /// The `.h9x` section's range in the file, if there is one.
    pack: ?struct { offset: u64, size: u64 },
    /// The end of the last section's raw data, and of its image range.
    raw_end: u64,
    virt_end: u64,
    first_raw: u64,

    pub fn arch(i: Info) []const u8 {
        return switch (i.machine) {
            0x8664 => "x86_64",
            0xaa64 => "arm64",
            0x14c => "x86",
            else => "unknown",
        };
    }

    fn dataDirs(i: Info) usize {
        return i.opt + @as(usize, if (i.pe32plus) 112 else 96);
    }
};

/// Whether `head` starts like a PE file.
pub fn isPe(head: []const u8) bool {
    if (head.len < 0x40 or !std.mem.eql(u8, head[0..2], "MZ")) return false;
    const pe = rd32(head, 0x3c);
    return pe + 4 <= head.len and std.mem.eql(u8, head[pe..][0..4], "PE\x00\x00");
}

/// Parses the headers. `head` holds at least the headers, from the start
/// of the file.
pub fn parse(head: []const u8) Error!Info {
    if (!isPe(head)) return error.NotPe;
    const coff = rd32(head, 0x3c) + 4;
    if (coff + 20 > head.len) return error.BadPe;
    const nsections = rd16(head, coff + 2);
    const opt_size = rd16(head, coff + 16);
    const opt = coff + 20;
    const sections = opt + opt_size;
    if (opt + 2 > head.len or sections + @as(usize, nsections) * section_header_size > head.len) return error.BadPe;
    const magic = rd16(head, opt);
    const pe32plus = switch (magic) {
        0x20b => true,
        0x10b => false,
        else => return error.BadPe,
    };
    var info: Info = .{
        .machine = rd16(head, coff),
        .coff = coff,
        .opt = opt,
        .sections = sections,
        .nsections = nsections,
        .pe32plus = pe32plus,
        .section_align = rd32(head, opt + 32),
        .file_align = rd32(head, opt + 36),
        .size_of_headers = rd32(head, opt + 60),
        .certificate = null,
        .pack = null,
        .raw_end = 0,
        .virt_end = 0,
        .first_raw = std.math.maxInt(u64),
    };
    if (info.file_align == 0 or info.section_align == 0) return error.BadPe;
    const ndirs = rd32(head, opt + @as(usize, if (pe32plus) 108 else 92));
    if (ndirs > dir_certificate) {
        const d = info.dataDirs() + dir_certificate * 8;
        if (d + 8 > sections) return error.BadPe;
        const off = rd32(head, d);
        const size = rd32(head, d + 4);
        if (off != 0 and size != 0) info.certificate = .{ .offset = off, .size = size };
    }
    for (0..nsections) |i| {
        const s = head[sections + i * section_header_size ..][0..section_header_size];
        const vsize = rd32(s, 8);
        const va = rd32(s, 12);
        const raw_size = rd32(s, 16);
        const raw = rd32(s, 20);
        if (std.mem.eql(u8, std.mem.sliceTo(s[0..8], 0), section_name)) info.pack = .{ .offset = raw, .size = vsize };
        if (raw != 0 and raw_size != 0) {
            info.raw_end = @max(info.raw_end, @as(u64, raw) + raw_size);
            info.first_raw = @min(info.first_raw, raw);
        }
        info.virt_end = @max(info.virt_end, @as(u64, va) + @max(vsize, raw_size));
    }
    return info;
}

/// Where `join` put things.
pub const Layout = struct {
    offset: u64,
    length: u64,
    size: u64,
};

/// Writes `runner` to `out` with the `len` bytes of `archive` as its
/// `.h9x` section, then any overlay, then the trailer.
pub fn join(gpa: std.mem.Allocator, out: *std.Io.Writer, runner: []const u8, archive: *std.Io.Reader, len: u64) !Layout {
    if (trailer.isPacked(runner)) return error.AlreadyPacked;
    const info = try parse(runner);
    if (info.pack != null) return error.AlreadyPacked;
    if (len > std.math.maxInt(u32)) return error.FileTooBig;

    // The runner's bytes: the image up to raw_end, and an overlay after it
    // that isn't the certificate.
    const raw_end = info.raw_end;
    var overlay_end: u64 = runner.len;
    if (info.certificate) |c| {
        if (c.offset < raw_end or @as(u64, c.offset) + c.size > runner.len) return error.BadPe;
        overlay_end = c.offset;
    }
    if (raw_end > overlay_end) return error.BadPe;

    // The new section header.
    const hdr_off = info.sections + @as(usize, info.nsections) * section_header_size;
    const hdr_end = hdr_off + section_header_size;
    if (hdr_end > info.size_of_headers or hdr_end > info.first_raw) return error.HeaderFull;

    const align_raw = @max(info.file_align, trailer.archive_align);
    const arch_off = std.mem.alignForward(u64, raw_end, align_raw);
    const raw_size = std.mem.alignForward(u64, len, info.file_align);
    const va = std.mem.alignForward(u64, info.virt_end, info.section_align);
    const overlay_off = arch_off + raw_size;
    const overlay = runner[@intCast(raw_end)..@intCast(overlay_end)];
    if (va + len > std.math.maxInt(u32) or overlay_off > std.math.maxInt(u32)) return error.FileTooBig;

    const head = try gpa.dupe(u8, runner[0..@intCast(raw_end)]);
    defer gpa.free(head);
    const s = head[hdr_off..hdr_end];
    @memset(s, 0);
    @memcpy(s[0..section_name.len], section_name);
    wr32(s, 8, @intCast(len)); // VirtualSize
    wr32(s, 12, @intCast(va)); // VirtualAddress
    wr32(s, 16, @intCast(raw_size)); // SizeOfRawData
    wr32(s, 20, @intCast(arch_off)); // PointerToRawData
    wr32(s, 36, IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ);
    wr16(head, info.coff + 2, info.nsections + 1);
    // The COFF symbol table, if any, moves with the overlay.
    const symtab = rd32(head, info.coff + 8);
    if (symtab != 0 and symtab >= raw_end) wr32(head, info.coff + 8, @intCast(symtab - raw_end + overlay_off));
    const opt = info.opt;
    wr32(head, opt + 8, rd32(head, opt + 8) +% @as(u32, @intCast(raw_size))); // SizeOfInitializedData
    wr32(head, opt + 56, @intCast(std.mem.alignForward(u64, va + @max(len, 1), info.section_align))); // SizeOfImage
    wr32(head, opt + 64, 0); // CheckSum
    if (info.certificate != null) {
        const d = info.dataDirs() + dir_certificate * 8;
        wr32(head, d, 0);
        wr32(head, d + 4, 0);
    }

    try out.writeAll(head);
    try out.splatByteAll(0, @intCast(arch_off - raw_end));
    try trailer.copyArchive(out, archive, len);
    try out.splatByteAll(0, @intCast(raw_size - len));
    try out.writeAll(overlay);
    try out.writeAll(&trailer.encode(.{ .offset = arch_off, .length = len }));
    return .{ .offset = arch_off, .length = len, .size = overlay_off + overlay.len + trailer.Trailer.size };
}

/// A minimal PE32+ image for the tests, with one `.text` section, a
/// symbol-table overlay, and a certificate after it. Real runners are
/// tested by exe/fixture_test.zig.
pub fn testImage(gpa: std.mem.Allocator) ![]u8 {
    const img = try gpa.alloc(u8, 0x600 + 0x20 + 0x10);
    @memset(img, 0);
    img[0..2].* = "MZ".*;
    wr32(img, 0x3c, 0x80);
    img[0x80..0x84].* = "PE\x00\x00".*;
    const coff = 0x84;
    wr16(img, coff, 0x8664);
    wr16(img, coff + 2, 1);
    wr32(img, coff + 8, 0x600); // symbol table, in the overlay
    wr16(img, coff + 16, 240);
    const opt = coff + 20;
    wr16(img, opt, 0x20b);
    wr32(img, opt + 32, 0x1000);
    wr32(img, opt + 36, 0x200);
    wr32(img, opt + 56, 0x2000);
    wr32(img, opt + 60, 0x400);
    wr32(img, opt + 64, 0xdead);
    wr32(img, opt + 108, 16);
    wr32(img, opt + 112 + dir_certificate * 8, 0x620);
    wr32(img, opt + 112 + dir_certificate * 8 + 4, 0x10);
    const sec = opt + 240;
    @memcpy(img[sec..][0..5], ".text");
    wr32(img, sec + 8, 0x10);
    wr32(img, sec + 12, 0x1000);
    wr32(img, sec + 16, 0x200);
    wr32(img, sec + 20, 0x400);
    @memset(img[0x400..0x410], 0xcc);
    @memset(img[0x600..0x620], 0x55); // the overlay
    @memset(img[0x620..0x630], 0xce); // the certificate
    return img;
}

test join {
    const gpa = std.testing.allocator;
    const img = try testImage(gpa);
    defer gpa.free(img);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const archive = "pe archive" ** 50;
    var ar: std.Io.Reader = .fixed(archive);
    const l = try join(gpa, &aw.writer, img, &ar, archive.len);
    const out = aw.written();
    try std.testing.expectEqual(l.size, out.len);

    const info = try parse(out);
    try std.testing.expectEqual(@as(u16, 2), info.nsections);
    try std.testing.expectEqual(@as(u64, 0x1000), info.pack.?.offset);
    try std.testing.expectEqualStrings(archive, out[0x1000..][0..archive.len]);
    try std.testing.expectEqual(@as(@TypeOf(info.certificate), null), info.certificate);
    // The new section is mapped after .text, and the image grew to fit it.
    const s = info.sections + section_header_size;
    try std.testing.expectEqual(@as(u32, 0x2000), rd32(out, s + 12));
    try std.testing.expectEqual(@as(u32, 0x3000), rd32(out, info.opt + 56));
    try std.testing.expectEqual(@as(u32, 0), rd32(out, info.opt + 64));
    // The overlay moved after the archive, and the symbol table with it.
    const overlay = 0x1000 + std.mem.alignForward(u64, archive.len, 0x200);
    try std.testing.expectEqual(@as(u32, @intCast(overlay)), rd32(out, info.coff + 8));
    try std.testing.expectEqualSlices(u8, img[0x600..0x620], out[overlay..][0..0x20]);

    const t = (try trailer.fromBytes(out)).?;
    try std.testing.expectEqual(info.pack.?.offset, t.offset);
    try std.testing.expectEqual(info.pack.?.size, t.length);

    var ar2: std.Io.Reader = .fixed("x");
    try std.testing.expectError(error.AlreadyPacked, join(gpa, &aw.writer, out, &ar2, 1));
}
