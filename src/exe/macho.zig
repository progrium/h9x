//! macOS executables: the archive in a `__H9X,__pack` section of its own
//! segment, before `__LINKEDIT`, then the trailer.
//!
//! Owned by W4. Treats the archive as opaque bytes.
//!
//! This is the layout Node's single-executable applications use, so
//! `codesign`, `otool`, and the loader see an ordinary executable:
//!
//!   [header and load commands, with __H9X's added]
//!   [__TEXT, __DATA_CONST, __DATA: the runner's, unchanged]
//!   [__H9X,__pack: the archive, on a segment boundary]
//!   [__LINKEDIT: the runner's, moved up, without its old signature]
//!   [the new ad-hoc signature, with the trailer in its reserved tail]
//!
//! Moving `__LINKEDIT` means every load command that points into it
//! (symbols, strings, fixups, the export trie, function starts, and the
//! rest) gets the same shift. The segments before it keep their indexes,
//! so fixups and binding opcodes, which name segments by index, are
//! untouched. The runner's own signature can't survive any of this, so the
//! result is always signed again by adhoc.zig, in the same pass that
//! writes it: the trailer sits inside `LC_CODE_SIGNATURE`'s range, after
//! the superblob, so the file still ends at the end of `__LINKEDIT` and
//! `codesign --verify --strict` has nothing to complain about.

const std = @import("std");
const adhoc = @import("adhoc.zig");
const trailer = @import("trailer.zig");

pub const segment_name = "__H9X";
pub const section_name = "__pack";

pub const Error = error{
    NotMachO,
    /// A fat file, or a 32-bit or big-endian one.
    UnsupportedMachO,
    BadMachO,
    AlreadyPacked,
    /// No room after the load commands for __H9X's, before the first
    /// section. Link the runner with `-headerpad 0x400` (build.zig's
    /// `headerpad_size`): Zig's linker leaves none by default.
    HeaderFull,
};

const MH_MAGIC_64 = 0xfeedfacf;
const MH_EXECUTE = 2;
const CPU_TYPE_ARM64 = 0x0100000c;
const VM_PROT_READ = 1;

const LC_SEGMENT_64 = 0x19;
const LC_SYMTAB = 0x2;
const LC_DYSYMTAB = 0xb;
const LC_CODE_SIGNATURE = 0x1d;
const LC_DYLD_INFO = 0x22;
const LC_DYLD_INFO_ONLY = 0x80000022;

const header_size = 32;
const segment_size = 72;
const section_size = 80;
const linkedit_data_size = 16;

/// The load commands that are a `linkedit_data_command`, whose `dataoff`
/// at byte 8 points into __LINKEDIT.
const linkedit_data_cmds = [_]u32{
    LC_CODE_SIGNATURE,
    0x1e, // LC_SEGMENT_SPLIT_INFO
    0x26, // LC_FUNCTION_STARTS
    0x29, // LC_DATA_IN_CODE
    0x2b, // LC_DYLIB_CODE_SIGN_DRS
    0x2e, // LC_LINKER_OPTIMIZATION_HINT
    0x80000033, // LC_DYLD_EXPORTS_TRIE
    0x80000034, // LC_DYLD_CHAINED_FIXUPS
    0x36, // LC_ATOM_INFO
};

/// The file offsets other load commands keep in __LINKEDIT, by byte
/// offset in the command. Each is a u32.
fn linkeditOffsets(cmd: u32) []const usize {
    return switch (cmd) {
        LC_SYMTAB => &.{ 8, 16 }, // symoff, stroff
        // tocoff, modtaboff, extrefsymoff, indirectsymoff, extreloff, locreloff
        LC_DYSYMTAB => &.{ 32, 40, 48, 56, 64, 72 },
        // rebase, bind, weak_bind, lazy_bind, export
        LC_DYLD_INFO, LC_DYLD_INFO_ONLY => &.{ 8, 16, 24, 32, 40 },
        else => for (linkedit_data_cmds) |c| {
            if (c == cmd) break &.{8};
        } else &.{},
    };
}

/// What `parse` finds in a Mach-O header.
pub const Info = struct {
    cputype: u32,
    filetype: u32,
    ncmds: u32,
    sizeofcmds: u32,
    /// Byte offsets of load commands in the file.
    linkedit_cmd: usize,
    text: struct { fileoff: u64, filesize: u64 },
    linkedit: struct { vmaddr: u64, fileoff: u64, filesize: u64 },
    /// LC_CODE_SIGNATURE's command offset, and its data's range.
    signature: ?struct { cmd: usize, dataoff: u32, datasize: u32 },
    /// The `__H9X,__pack` section's range in the file, if there is one.
    pack: ?struct { offset: u64, size: u64 },
    /// The lowest file offset of any section's contents: the load
    /// commands can grow up to here.
    first_section: u64,

    pub fn arch(i: Info) []const u8 {
        return switch (i.cputype) {
            CPU_TYPE_ARM64 => "arm64",
            0x01000007 => "x86_64",
            else => "unknown",
        };
    }

    pub fn segmentAlign(i: Info) u64 {
        return if (i.cputype == CPU_TYPE_ARM64) 0x4000 else 0x1000;
    }
};

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn rd64(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}
fn wr32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}
fn wr64(b: []u8, off: usize, v: u64) void {
    std.mem.writeInt(u64, b[off..][0..8], v, .little);
}

fn name16(b: []const u8) []const u8 {
    return std.mem.sliceTo(b[0..16], 0);
}

/// Whether `head` starts like a Mach-O file of any kind.
pub fn isMachO(head: []const u8) bool {
    if (head.len < 4) return false;
    const m = std.mem.readInt(u32, head[0..4], .little);
    const mb = std.mem.readInt(u32, head[0..4], .big);
    return m == MH_MAGIC_64 or m == 0xfeedface or mb == 0xcafebabe or mb == MH_MAGIC_64 or mb == 0xfeedface;
}

/// Parses the header and load commands. `head` holds at least the header
/// and load commands, from the start of the file.
pub fn parse(head: []const u8) Error!Info {
    if (head.len < header_size) return error.NotMachO;
    if (rd32(head, 0) != MH_MAGIC_64) return if (isMachO(head)) error.UnsupportedMachO else error.NotMachO;
    const ncmds = rd32(head, 16);
    const sizeofcmds = rd32(head, 20);
    if (header_size + @as(u64, sizeofcmds) > head.len) return error.BadMachO;

    var info: Info = .{
        .cputype = rd32(head, 4),
        .filetype = rd32(head, 12),
        .ncmds = ncmds,
        .sizeofcmds = sizeofcmds,
        .linkedit_cmd = 0,
        .text = .{ .fileoff = 0, .filesize = 0 },
        .linkedit = .{ .vmaddr = 0, .fileoff = 0, .filesize = 0 },
        .signature = null,
        .pack = null,
        .first_section = std.math.maxInt(u64),
    };
    var have_linkedit = false;
    var off: usize = header_size;
    const end = header_size + sizeofcmds;
    for (0..ncmds) |_| {
        if (off + 8 > end) return error.BadMachO;
        const cmd = rd32(head, off);
        const size = rd32(head, off + 4);
        if (size < 8 or off + size > end) return error.BadMachO;
        const c = head[off..][0..size];
        switch (cmd) {
            LC_SEGMENT_64 => {
                if (size < segment_size) return error.BadMachO;
                const name = name16(c[8..]);
                const nsects = rd32(c, 64);
                if (segment_size + @as(u64, nsects) * section_size > size) return error.BadMachO;
                if (std.mem.eql(u8, name, "__TEXT")) info.text = .{ .fileoff = rd64(c, 40), .filesize = rd64(c, 48) };
                if (std.mem.eql(u8, name, "__LINKEDIT")) {
                    have_linkedit = true;
                    info.linkedit_cmd = off;
                    info.linkedit = .{ .vmaddr = rd64(c, 24), .fileoff = rd64(c, 40), .filesize = rd64(c, 48) };
                }
                for (0..nsects) |i| {
                    const s = c[segment_size + i * section_size ..][0..section_size];
                    const s_off = rd32(s, 48);
                    const s_type = rd32(s, 64) & 0xff;
                    const zerofill = s_type == 0x1 or s_type == 0xc or s_type == 0x12;
                    if (std.mem.eql(u8, name, segment_name) and std.mem.eql(u8, name16(s), section_name))
                        info.pack = .{ .offset = s_off, .size = rd64(s, 40) };
                    if (s_off != 0 and !zerofill) info.first_section = @min(info.first_section, s_off);
                }
            },
            LC_CODE_SIGNATURE => {
                if (size < linkedit_data_size) return error.BadMachO;
                info.signature = .{ .cmd = off, .dataoff = rd32(c, 8), .datasize = rd32(c, 12) };
            },
            else => {},
        }
        off += size;
    }
    if (!have_linkedit) return error.BadMachO;
    return info;
}

/// Where `join` put things.
pub const Layout = struct {
    /// The archive's range; zero for `sign`.
    offset: u64,
    length: u64,
    /// The signature superblob's offset and size.
    signature: u64,
    signature_size: u64,
    size: u64,
};

/// Writes `runner` to `out` with the `len` bytes of `archive` as its
/// `__H9X,__pack` section, signed ad hoc with `opts`, ending in the trailer.
pub fn join(gpa: std.mem.Allocator, out: *std.Io.Writer, runner: []const u8, archive: *std.Io.Reader, len: u64, opts: adhoc.Options) !Layout {
    return rewrite(gpa, out, runner, .{ .reader = archive, .len = len }, opts);
}

/// Writes `runner` to `out`, signed ad hoc with `opts` in place of any
/// signature it had: `codesign --force --sign - --entitlements` from any
/// host.
pub fn sign(gpa: std.mem.Allocator, out: *std.Io.Writer, runner: []const u8, opts: adhoc.Options) !Layout {
    return rewrite(gpa, out, runner, null, opts);
}

const Archive = struct { reader: *std.Io.Reader, len: u64 };

fn rewrite(gpa: std.mem.Allocator, out: *std.Io.Writer, runner: []const u8, archive: ?Archive, opts: adhoc.Options) !Layout {
    if (trailer.isPacked(runner)) return error.AlreadyPacked;
    const info = try parse(runner);
    if (info.pack != null) return error.AlreadyPacked;
    const seg_align = info.segmentAlign();

    // __LINKEDIT's contents, less the old signature, which is last in it.
    const le_off = info.linkedit.fileoff;
    var le_end = le_off + info.linkedit.filesize;
    if (info.signature) |s| {
        if (s.dataoff < le_off or s.dataoff > le_end) return error.BadMachO;
        le_end = s.dataoff;
    }
    if (le_end > runner.len or le_off > le_end) return error.BadMachO;
    const linkedit = runner[@intCast(le_off)..@intCast(le_end)];

    // The new layout.
    const arch_off = std.mem.alignForward(u64, le_off, seg_align);
    const arch_len: u64 = if (archive) |a| a.len else 0;
    const arch_vmsize = std.mem.alignForward(u64, @max(arch_len, 1), seg_align);
    const new_le_off = if (archive != null) std.mem.alignForward(u64, arch_off + arch_len, seg_align) else le_off;
    const delta = new_le_off - le_off;
    const sig_off = std.mem.alignForward(u64, new_le_off + linkedit.len, 16);

    var signer: adhoc.Signer = try .init(gpa, opts, sig_off, .{
        .base = info.text.fileoff,
        .limit = info.text.filesize,
        .main_binary = info.filetype == MH_EXECUTE,
    });
    defer signer.deinit();
    const sig_size = signer.size();
    const trailer_size: u64 = if (archive != null) trailer.Trailer.size else 0;
    const sig_reserved = std.mem.alignForward(u64, sig_size, 16) + trailer_size;
    const file_end = sig_off + sig_reserved;
    if (sig_off > std.math.maxInt(u32) or sig_reserved > std.math.maxInt(u32)) return error.FileTooBig;

    // The new load commands.
    var cmds: std.ArrayList(u8) = .empty;
    defer cmds.deinit(gpa);
    var ncmds = info.ncmds;
    var off: usize = header_size;
    for (0..info.ncmds) |_| {
        const cmd = rd32(runner, off);
        const size = rd32(runner, off + 4);
        if (off == info.linkedit_cmd and archive != null) {
            try appendPackSegment(gpa, &cmds, info.linkedit.vmaddr, arch_vmsize, arch_off, arch_len);
            ncmds += 1;
        }
        const start = cmds.items.len;
        try cmds.appendSlice(gpa, runner[off..][0..size]);
        const c = cmds.items[start..];
        for (linkeditOffsets(cmd)) |o| {
            const v = rd32(c, o);
            if (v != 0 and v >= le_off) wr32(c, o, @intCast(v + delta));
        }
        if (off == info.linkedit_cmd) {
            wr64(c, 24, info.linkedit.vmaddr + if (archive != null) arch_vmsize else 0);
            wr64(c, 40, new_le_off);
            wr64(c, 48, file_end - new_le_off);
            wr64(c, 32, std.mem.alignForward(u64, file_end - new_le_off, seg_align));
        }
        if (cmd == LC_CODE_SIGNATURE) {
            wr32(c, 8, @intCast(sig_off));
            wr32(c, 12, @intCast(sig_reserved));
        }
        off += size;
    }
    if (info.signature == null) {
        var c: [linkedit_data_size]u8 = undefined;
        wr32(&c, 0, LC_CODE_SIGNATURE);
        wr32(&c, 4, linkedit_data_size);
        wr32(&c, 8, @intCast(sig_off));
        wr32(&c, 12, @intCast(sig_reserved));
        try cmds.appendSlice(gpa, &c);
        ncmds += 1;
    }
    const cmds_end = header_size + cmds.items.len;
    if (cmds_end > info.first_section or cmds_end > le_off) return error.HeaderFull;

    // Everything before __LINKEDIT, with the new header.
    const head = try gpa.dupe(u8, runner[0..@intCast(le_off)]);
    defer gpa.free(head);
    wr32(head, 16, ncmds);
    wr32(head, 20, @intCast(cmds.items.len));
    @memcpy(head[header_size..cmds_end], cmds.items);

    var w: Tee = .{ .out = out, .signer = &signer };
    try w.write(head);
    if (archive) |a| {
        try w.zeros(arch_off - le_off);
        var buf: [64 * 1024]u8 = undefined;
        var left = a.len;
        while (left > 0) {
            const n: usize = @intCast(@min(left, buf.len));
            try a.reader.readSliceAll(buf[0..n]);
            try w.write(buf[0..n]);
            left -= n;
        }
        try w.zeros(new_le_off - (arch_off + arch_len));
    }
    try w.write(linkedit);
    try w.zeros(sig_off - (new_le_off + linkedit.len));
    try signer.finish(out);
    try out.splatByteAll(0, @intCast(sig_reserved - sig_size - trailer_size));
    if (archive != null) try out.writeAll(&trailer.encode(.{ .offset = arch_off, .length = arch_len }));

    return .{
        .offset = if (archive != null) arch_off else 0,
        .length = arch_len,
        .signature = sig_off,
        .signature_size = sig_size,
        .size = file_end,
    };
}

/// Writes to `out` and hashes for the signature.
const Tee = struct {
    out: *std.Io.Writer,
    signer: *adhoc.Signer,

    fn write(t: Tee, bytes: []const u8) !void {
        try t.out.writeAll(bytes);
        t.signer.update(bytes);
    }

    fn zeros(t: Tee, n: u64) !void {
        const z: [256]u8 = @splat(0);
        var left = n;
        while (left > 0) {
            const k: usize = @intCast(@min(left, z.len));
            try t.write(z[0..k]);
            left -= k;
        }
    }
};

fn appendPackSegment(gpa: std.mem.Allocator, cmds: *std.ArrayList(u8), vmaddr: u64, vmsize: u64, fileoff: u64, len: u64) !void {
    var c: [segment_size + section_size]u8 = @splat(0);
    wr32(&c, 0, LC_SEGMENT_64);
    wr32(&c, 4, c.len);
    @memcpy(c[8..][0..segment_name.len], segment_name);
    wr64(&c, 24, vmaddr);
    wr64(&c, 32, vmsize);
    wr64(&c, 40, fileoff);
    wr64(&c, 48, len);
    wr32(&c, 56, VM_PROT_READ); // maxprot
    wr32(&c, 60, VM_PROT_READ); // initprot
    wr32(&c, 64, 1); // nsects
    const s = c[segment_size..];
    @memcpy(s[0..section_name.len], section_name);
    @memcpy(s[16..][0..segment_name.len], segment_name);
    wr64(s, 32, vmaddr);
    wr64(s, 40, len);
    wr32(s, 48, @intCast(fileoff));
    // align 2^0, no relocations, S_REGULAR
    try cmds.appendSlice(gpa, &c);
}

/// A minimal arm64 executable for the tests: a header, __PAGEZERO,
/// __TEXT with one section, and __LINKEDIT with a symbol table, built by
/// hand so the tests don't need a macOS toolchain. Real runners are tested
/// by exe/fixture_test.zig.
pub fn testImage(gpa: std.mem.Allocator) ![]u8 {
    const page = 0x4000;
    const img = try gpa.alloc(u8, 2 * page + 0x100);
    @memset(img, 0);
    wr32(img, 0, MH_MAGIC_64);
    wr32(img, 4, CPU_TYPE_ARM64);
    wr32(img, 12, MH_EXECUTE);
    var off: usize = header_size;
    const Seg = struct { name: []const u8, vmaddr: u64, vmsize: u64, fileoff: u64, filesize: u64, sect: bool };
    const segs = [_]Seg{
        .{ .name = "__PAGEZERO", .vmaddr = 0, .vmsize = 0x100000000, .fileoff = 0, .filesize = 0, .sect = false },
        .{ .name = "__TEXT", .vmaddr = 0x100000000, .vmsize = page, .fileoff = 0, .filesize = page, .sect = true },
        .{ .name = "__LINKEDIT", .vmaddr = 0x100000000 + 2 * page, .vmsize = page, .fileoff = 2 * page, .filesize = 0x100, .sect = false },
    };
    for (segs) |s| {
        const size: u32 = if (s.sect) segment_size + section_size else segment_size;
        wr32(img, off, LC_SEGMENT_64);
        wr32(img, off + 4, size);
        @memcpy(img[off + 8 ..][0..s.name.len], s.name);
        wr64(img, off + 24, s.vmaddr);
        wr64(img, off + 32, s.vmsize);
        wr64(img, off + 40, s.fileoff);
        wr64(img, off + 48, s.filesize);
        if (s.sect) {
            wr32(img, off + 64, 1);
            const sec = off + segment_size;
            @memcpy(img[sec..][0..6], "__text");
            @memcpy(img[sec + 16 ..][0..6], "__TEXT");
            wr64(img, sec + 32, 0x100000000 + 0x3000);
            wr64(img, sec + 40, 0x10);
            wr32(img, sec + 48, 0x3000);
            @memset(img[0x3000..0x3010], 0xd5);
        }
        off += size;
    }
    // LC_SYMTAB pointing at __LINKEDIT.
    wr32(img, off, LC_SYMTAB);
    wr32(img, off + 4, 24);
    wr32(img, off + 8, 2 * page);
    wr32(img, off + 12, 1);
    wr32(img, off + 16, 2 * page + 0x10);
    wr32(img, off + 20, 0x10);
    off += 24;
    wr32(img, 16, segs.len + 1);
    wr32(img, 20, @intCast(off - header_size));
    @memset(img[2 * page ..][0..0x20], 0x5a);
    return img;
}

test "join adds __H9X before __LINKEDIT and signs" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const img = try testImage(gpa);
    defer gpa.free(img);
    const before = try parse(img);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const archive = repeat("the archive", 100);
    var ar: std.Io.Reader = .fixed(archive);
    const l = try join(gpa, &aw.writer, img, &ar, archive.len, .{ .identifier = "app" });
    const out = aw.written();
    try std.testing.expectEqual(l.size, out.len);

    const info = try parse(out);
    try std.testing.expectEqual(before.ncmds + 2, info.ncmds); // __H9X and LC_CODE_SIGNATURE
    try std.testing.expectEqual(@as(u64, 0x8000), info.pack.?.offset);
    try std.testing.expectEqualStrings(archive, out[info.pack.?.offset..][0..info.pack.?.size]);
    // __LINKEDIT moved up past the archive, in the file and in memory, and
    // runs to the end of the file.
    try std.testing.expectEqual(@as(u64, 0xc000), info.linkedit.fileoff);
    try std.testing.expectEqual(before.linkedit.vmaddr + 0x4000, info.linkedit.vmaddr);
    try std.testing.expectEqual(out.len, info.linkedit.fileoff + info.linkedit.filesize);
    try std.testing.expectEqualSlices(u8, img[0x8000..][0..0x100], out[0xc000..][0..0x100]);
    // The symbol table moved with it.
    const symtab = header_size + 2 * segment_size + section_size + segment_size + segment_size + section_size;
    try std.testing.expectEqual(@as(u32, 0xc000), rd32(out, symtab + 8));
    try std.testing.expectEqual(@as(u32, 0xc010), rd32(out, symtab + 16));
    // The code before __LINKEDIT is the runner's.
    try std.testing.expectEqualSlices(u8, img[0x1000..0x8000], out[0x1000..0x8000]);

    // The trailer is the last 32 bytes, and agrees with the section.
    const t = (try trailer.fromBytes(out)).?;
    try std.testing.expectEqual(info.pack.?.offset, t.offset);
    try std.testing.expectEqual(info.pack.?.size, t.length);

    // The signature covers everything before it, archive included.
    const s = info.signature.?;
    try std.testing.expectEqual(l.signature, s.dataoff);
    const sig = try adhoc.inspect(arena.allocator(), .{ .bytes = out }, s.dataoff, s.datasize);
    try std.testing.expect(sig.valid);
    try std.testing.expectEqualStrings("app", sig.identifier);
    try std.testing.expectEqual(@as(u64, s.dataoff), sig.code_limit);

    // Packing it again is refused.
    var ar2: std.Io.Reader = .fixed("x");
    try std.testing.expectError(error.AlreadyPacked, join(gpa, &aw.writer, out, &ar2, 1, .{ .identifier = "app" }));
}

test "sign replaces a signature, and resigning is stable" {
    const gpa = std.testing.allocator;
    const img = try testImage(gpa);
    defer gpa.free(img);
    var a1: std.Io.Writer.Allocating = .init(gpa);
    defer a1.deinit();
    _ = try sign(gpa, &a1.writer, img, .{ .identifier = "x" });
    var a2: std.Io.Writer.Allocating = .init(gpa);
    defer a2.deinit();
    _ = try sign(gpa, &a2.writer, a1.written(), .{ .identifier = "x" });
    try std.testing.expectEqualSlices(u8, a1.written(), a2.written());
    try std.testing.expectEqual(@as(u32, (try parse(img)).ncmds + 1), (try parse(a2.written())).ncmds);
}

test "a full header is refused" {
    const gpa = std.testing.allocator;
    const img = try testImage(gpa);
    defer gpa.free(img);
    // Move __text's contents up against the load commands.
    const sec = header_size + 2 * segment_size + 48;
    wr32(img, sec, header_size + rd32(img, 20) + 8);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var ar: std.Io.Reader = .fixed("x");
    try std.testing.expectError(error.HeaderFull, join(gpa, &aw.writer, img, &ar, 1, .{ .identifier = "a" }));
}

/// `s` `n` times, at comptime.
fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    comptime var out: [s.len * n]u8 = undefined;
    inline for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
    const final = out;
    return &final;
}
