//! Ad-hoc signing of macOS executables with the
//! `com.apple.security.hypervisor` entitlement, from any host: a port of
//! the ad-hoc signer in Zig's Mach-O linker.
//!
//! Owned by W4.
//!
//! An ad-hoc signature is an embedded superblob with no certificate: a
//! code directory that hashes every 4 KB page of the file up to the
//! signature, the empty requirement set, and the entitlements as XML and
//! as DER, with the hashes of those blobs in the code directory's special
//! slots. It's what `codesign --sign - --entitlements FILE` writes, and is
//! enough for the kernel to run the file and for HVF to accept
//! `hv_vm_create` on the machine that made it. Zig's linker signs the same
//! way, but marks its signatures linker-signed, which carries no
//! entitlements, so this signer leaves that flag off.
//!
//! The signer is streaming: `Signer.size` is known from the code limit
//! before any page is hashed, so the Mach-O writer (macho.zig) can lay out
//! `LC_CODE_SIGNATURE` and `__LINKEDIT` first, then pass each byte through
//! `Signer.update` as it writes, and end with `Signer.finish`.

const std = @import("std");
const macho = std.macho;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const hypervisor = "com.apple.security.hypervisor";

pub const Options = struct {
    /// The code directory's identifier, conventionally the program's name.
    identifier: []const u8,
    /// Entitlements, each set to true. The default is HVF's.
    entitlements: []const []const u8 = &.{hypervisor},
};

pub const page_size = 0x1000;
const page_size_log2 = 12;
const hash_size = Sha256.digest_length;

/// The special slots, by number: 2 is the requirements blob, 5 the XML
/// entitlements, and 7 the DER entitlements. The others are left zero.
const slot_requirements = 2;
const slot_entitlements = 5;
const slot_der_entitlements = 7;

/// Blob types in the superblob's index.
const type_code_directory = 0;
const type_requirements = 2;
const type_entitlements = 5;
const type_der_entitlements = 7;

const code_directory_header_size = 88;
const empty_requirements = [12]u8{ 0xfa, 0xde, 0x0c, 0x01, 0, 0, 0, 12, 0, 0, 0, 0 };

/// What the code directory says about the executable segment.
pub const ExecSegment = struct {
    base: u64,
    limit: u64,
    main_binary: bool,
};

pub const Signer = struct {
    gpa: std.mem.Allocator,
    identifier: []const u8,
    code_limit: u64,
    exec_seg: ExecSegment,
    /// The XML and DER entitlements, or empty when there are none.
    xml: []u8,
    der: []u8,
    hashes: []u8,
    page: [page_size]u8 = undefined,
    page_len: usize = 0,
    page_index: u64 = 0,
    seen: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, opts: Options, code_limit: u64, exec_seg: ExecSegment) !Signer {
        const xml: []u8 = if (opts.entitlements.len > 0) try entitlementsXml(gpa, opts.entitlements) else &.{};
        errdefer gpa.free(xml);
        const der: []u8 = if (opts.entitlements.len > 0) try entitlementsDer(gpa, opts.entitlements) else &.{};
        errdefer gpa.free(der);
        const hashes = try gpa.alloc(u8, pages(code_limit) * hash_size);
        return .{
            .gpa = gpa,
            .identifier = opts.identifier,
            .code_limit = code_limit,
            .exec_seg = exec_seg,
            .xml = xml,
            .der = der,
            .hashes = hashes,
        };
    }

    pub fn deinit(s: *Signer) void {
        s.gpa.free(s.xml);
        s.gpa.free(s.der);
        s.gpa.free(s.hashes);
    }

    fn entitled(s: *const Signer) bool {
        return s.xml.len > 0;
    }

    fn nSpecial(s: *const Signer) u32 {
        return if (s.entitled()) slot_der_entitlements else slot_requirements;
    }

    fn nBlobs(s: *const Signer) u32 {
        return if (s.entitled()) 4 else 2;
    }

    fn codeDirectorySize(s: *const Signer) u64 {
        return code_directory_header_size + s.identifier.len + 1 + (s.nSpecial() + pages(s.code_limit)) * hash_size;
    }

    /// The superblob's size in bytes, which is what `finish` writes.
    pub fn size(s: *const Signer) u64 {
        var n: u64 = 12 + 8 * @as(u64, s.nBlobs()) + s.codeDirectorySize() + empty_requirements.len;
        if (s.entitled()) n += 8 + s.xml.len + 8 + s.der.len;
        return n;
    }

    /// Hashes `bytes`, the next bytes of the file, up to the code limit.
    pub fn update(s: *Signer, bytes: []const u8) void {
        var rest = bytes[0..@intCast(@min(bytes.len, s.code_limit - s.seen))];
        s.seen += rest.len;
        while (rest.len > 0) {
            const n = @min(rest.len, page_size - s.page_len);
            @memcpy(s.page[s.page_len..][0..n], rest[0..n]);
            s.page_len += n;
            rest = rest[n..];
            if (s.page_len == page_size) s.flushPage();
        }
    }

    fn flushPage(s: *Signer) void {
        const i = s.page_index;
        Sha256.hash(s.page[0..s.page_len], s.hashes[i * hash_size ..][0..hash_size], .{});
        s.page_index += 1;
        s.page_len = 0;
    }

    /// Writes the superblob, once every byte up to the code limit has
    /// passed through `update`.
    pub fn finish(s: *Signer, out: *std.Io.Writer) !void {
        if (s.seen != s.code_limit) return error.ShortSignedRange;
        if (s.page_len > 0) s.flushPage();

        // The blobs after the code directory, and their hashes for its
        // special slots.
        var ent_blob: std.ArrayList(u8) = .empty;
        defer ent_blob.deinit(s.gpa);
        var der_blob: std.ArrayList(u8) = .empty;
        defer der_blob.deinit(s.gpa);
        if (s.entitled()) {
            try blob(s.gpa, &ent_blob, macho.CSMAGIC_EMBEDDED_ENTITLEMENTS, s.xml);
            try blob(s.gpa, &der_blob, macho.CSMAGIC_EMBEDDED_DER_ENTITLEMENTS, s.der);
        }
        const n_special = s.nSpecial();
        var special: [slot_der_entitlements][hash_size]u8 = @splat(@splat(0));
        Sha256.hash(&empty_requirements, &special[slot_requirements - 1], .{});
        if (s.entitled()) {
            Sha256.hash(ent_blob.items, &special[slot_entitlements - 1], .{});
            Sha256.hash(der_blob.items, &special[slot_der_entitlements - 1], .{});
        }

        // The superblob's header and index.
        const n_blobs = s.nBlobs();
        const cd_size: u32 = @intCast(s.codeDirectorySize());
        var off: u32 = 12 + 8 * n_blobs;
        try be32(out, macho.CSMAGIC_EMBEDDED_SIGNATURE);
        try be32(out, @intCast(s.size()));
        try be32(out, n_blobs);
        try be32(out, type_code_directory);
        try be32(out, off);
        off += cd_size;
        try be32(out, type_requirements);
        try be32(out, off);
        off += empty_requirements.len;
        if (s.entitled()) {
            try be32(out, type_entitlements);
            try be32(out, off);
            off += @intCast(ent_blob.items.len);
            try be32(out, type_der_entitlements);
            try be32(out, off);
        }

        // The code directory, version 0x20400, with the executable segment.
        const ident_off: u32 = code_directory_header_size;
        const hash_off: u32 = ident_off + @as(u32, @intCast(s.identifier.len)) + 1 + n_special * hash_size;
        const limit32: u32 = if (s.code_limit > std.math.maxInt(u32)) 0 else @intCast(s.code_limit);
        try be32(out, macho.CSMAGIC_CODEDIRECTORY);
        try be32(out, cd_size);
        try be32(out, macho.CS_SUPPORTSEXECSEG);
        try be32(out, macho.CS_ADHOC);
        try be32(out, hash_off);
        try be32(out, ident_off);
        try be32(out, n_special);
        try be32(out, @intCast(pages(s.code_limit)));
        try be32(out, limit32);
        try out.writeAll(&.{ hash_size, macho.CS_HASHTYPE_SHA256, 0, page_size_log2 });
        try be32(out, 0); // spare2
        try be32(out, 0); // scatterOffset
        try be32(out, 0); // teamOffset
        try be32(out, 0); // spare3
        try be64(out, if (limit32 == 0) s.code_limit else 0);
        try be64(out, s.exec_seg.base);
        try be64(out, s.exec_seg.limit);
        try be64(out, if (s.exec_seg.main_binary) macho.CS_EXECSEG_MAIN_BINARY else 0);
        try out.writeAll(s.identifier);
        try out.writeByte(0);
        // Special slots run backwards from the code slots: -n first.
        var i: u32 = n_special;
        while (i > 0) : (i -= 1) try out.writeAll(&special[i - 1]);
        try out.writeAll(s.hashes);

        try out.writeAll(&empty_requirements);
        try out.writeAll(ent_blob.items);
        try out.writeAll(der_blob.items);
    }
};

fn pages(code_limit: u64) u64 {
    return std.math.divCeil(u64, code_limit, page_size) catch unreachable;
}

fn be32(out: *std.Io.Writer, v: u32) !void {
    try out.writeInt(u32, v, .big);
}

fn be64(out: *std.Io.Writer, v: u64) !void {
    try out.writeInt(u64, v, .big);
}

fn blob(gpa: std.mem.Allocator, list: *std.ArrayList(u8), magic: u32, payload: []const u8) !void {
    var hdr: [8]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], magic, .big);
    std.mem.writeInt(u32, hdr[4..8], @intCast(8 + payload.len), .big);
    try list.appendSlice(gpa, &hdr);
    try list.appendSlice(gpa, payload);
}

/// The entitlements as the property list `codesign --entitlements` takes.
pub fn entitlementsXml(gpa: std.mem.Allocator, keys: []const []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\
    );
    for (keys) |k| try w.print("\t<key>{s}</key>\n\t<true/>\n", .{k});
    try w.writeAll("</dict>\n</plist>\n");
    return aw.toOwnedSlice();
}

/// The entitlements in the DER form the kernel reads since macOS 12:
/// `[APPLICATION 16] { INTEGER 1, [CONTEXT 16] { SEQUENCE { UTF8String
/// key, BOOLEAN true }... } }`, with the keys sorted.
pub fn entitlementsDer(gpa: std.mem.Allocator, keys: []const []const u8) ![]u8 {
    const sorted = try gpa.dupe([]const u8, keys);
    defer gpa.free(sorted);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var dict: std.ArrayList(u8) = .empty;
    defer dict.deinit(gpa);
    for (sorted) |k| {
        var entry: std.ArrayList(u8) = .empty;
        defer entry.deinit(gpa);
        try derTlv(gpa, &entry, 0x0c, k);
        try entry.appendSlice(gpa, &.{ 0x01, 0x01, 0xff });
        try derTlv(gpa, &dict, 0x30, entry.items);
    }
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, &.{ 0x02, 0x01, 0x01 });
    try derTlv(gpa, &body, 0xb0, dict.items);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try derTlv(gpa, &out, 0x70, body.items);
    return out.toOwnedSlice(gpa);
}

fn derTlv(gpa: std.mem.Allocator, list: *std.ArrayList(u8), tag: u8, value: []const u8) !void {
    try list.append(gpa, tag);
    const n = value.len;
    if (n < 0x80) {
        try list.append(gpa, @intCast(n));
    } else if (n <= 0xff) {
        try list.appendSlice(gpa, &.{ 0x81, @intCast(n) });
    } else if (n <= 0xffff) {
        try list.appendSlice(gpa, &.{ 0x82, @intCast(n >> 8), @intCast(n & 0xff) });
    } else {
        try list.appendSlice(gpa, &.{ 0x83, @intCast(n >> 16), @intCast((n >> 8) & 0xff), @intCast(n & 0xff) });
    }
    try list.appendSlice(gpa, value);
}

/// What an embedded signature says, for `pack --inspect` and the tests.
pub const Info = struct {
    identifier: []const u8,
    flags: u32,
    code_limit: u64,
    pages: u64,
    /// The XML entitlements, or empty.
    entitlements: []const u8,
    has_der: bool,
    /// Whether every page hash and special slot matched the file.
    valid: bool,
};

/// Something `inspect` reads from: a whole file in memory, or an open file.
pub const Source = union(enum) {
    bytes: []const u8,
    file: struct { io: std.Io, file: std.Io.File },

    pub fn readAt(src: Source, buf: []u8, off: u64) !void {
        switch (src) {
            .bytes => |b| {
                if (off > b.len or b.len - off < buf.len) return error.Truncated;
                @memcpy(buf, b[@intCast(off)..][0..buf.len]);
            },
            .file => |f| if (try f.file.readPositionalAll(f.io, buf, off) != buf.len) return error.Truncated,
        }
    }

    pub fn alloc(src: Source, gpa: std.mem.Allocator, off: u64, len: u64) ![]u8 {
        if (len > 1 << 30) return error.Truncated;
        const buf = try gpa.alloc(u8, @intCast(len));
        errdefer gpa.free(buf);
        try src.readAt(buf, off);
        return buf;
    }
};

/// Reads the superblob at `off` and checks it against `src`'s pages.
/// Strings in the result are allocated in `gpa`, which should be an arena.
pub fn inspect(gpa: std.mem.Allocator, src: Source, off: u64, len: u64) !Info {
    const sb = try src.alloc(gpa, off, len);
    if (sb.len < 12 or rd32(sb, 0) != macho.CSMAGIC_EMBEDDED_SIGNATURE) return error.BadSignature;
    const count = rd32(sb, 8);
    if (12 + @as(u64, count) * 8 > sb.len) return error.BadSignature;

    var cd: ?[]const u8 = null;
    var blobs: [8]?[]const u8 = @splat(null);
    for (0..count) |i| {
        const typ = rd32(sb, 12 + i * 8);
        const boff = rd32(sb, 16 + i * 8);
        if (@as(u64, boff) + 8 > sb.len) return error.BadSignature;
        const blen = rd32(sb, boff + 4);
        if (blen < 8 or @as(u64, boff) + blen > sb.len) return error.BadSignature;
        const b = sb[boff..][0..blen];
        if (typ == type_code_directory) cd = b else if (typ < blobs.len) blobs[typ] = b;
    }
    const c = cd orelse return error.BadSignature;
    if (c.len < 44 or rd32(c, 0) != macho.CSMAGIC_CODEDIRECTORY) return error.BadSignature;
    const version = rd32(c, 8);
    const flags = rd32(c, 12);
    const hash_off = rd32(c, 16);
    const ident_off = rd32(c, 20);
    const n_special = rd32(c, 24);
    const n_code = rd32(c, 28);
    var code_limit: u64 = rd32(c, 32);
    if (version >= macho.CS_SUPPORTSCODELIMIT64 and code_limit == 0 and c.len >= 64) code_limit = std.mem.readInt(u64, c[56..64], .big);
    const hsize = c[36];
    const htype = c[37];
    const pshift = c[39];
    if (hsize != hash_size or htype != macho.CS_HASHTYPE_SHA256) return error.UnsupportedHash;
    if (@as(u64, hash_off) + @as(u64, n_code) * hash_size > c.len or hash_off < n_special * hash_size) return error.BadSignature;
    if (ident_off >= c.len) return error.BadSignature;
    const ident = std.mem.sliceTo(c[ident_off..], 0);

    var valid = true;
    // The special slots this signer fills.
    for ([_]u32{ slot_requirements, slot_entitlements, slot_der_entitlements }) |slot| {
        if (slot > n_special) continue;
        const want = c[hash_off - slot * hash_size ..][0..hash_size];
        if (blobs[slot]) |b| {
            var got: [hash_size]u8 = undefined;
            Sha256.hash(b, &got, .{});
            if (!std.mem.eql(u8, &got, want)) valid = false;
        } else if (!std.mem.allEqual(u8, want, 0)) valid = false;
    }
    // Every page.
    const psize = @as(u64, 1) << @intCast(pshift);
    if (n_code != std.math.divCeil(u64, code_limit, psize) catch unreachable) valid = false;
    const page = try gpa.alloc(u8, @intCast(psize));
    defer gpa.free(page);
    var p: u64 = 0;
    while (valid and p < n_code) : (p += 1) {
        const start = p * psize;
        const n = @min(psize, code_limit - start);
        try src.readAt(page[0..@intCast(n)], start);
        var got: [hash_size]u8 = undefined;
        Sha256.hash(page[0..@intCast(n)], &got, .{});
        if (!std.mem.eql(u8, &got, c[hash_off + p * hash_size ..][0..hash_size])) valid = false;
    }

    return .{
        .identifier = ident,
        .flags = flags,
        .code_limit = code_limit,
        .pages = n_code,
        .entitlements = if (blobs[type_entitlements]) |b| b[8..] else "",
        .has_der = blobs[type_der_entitlements] != null,
        .valid = valid,
    };
}

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .big);
}

test entitlementsDer {
    const gpa = std.testing.allocator;
    const der = try entitlementsDer(gpa, &.{hypervisor});
    defer gpa.free(der);
    // The entitlement as one dictionary entry.
    const want = "\x70\x29\x02\x01\x01\xb0\x24\x30\x22\x0c\x1d" ++ hypervisor ++ "\x01\x01\xff";
    try std.testing.expectEqualSlices(u8, want, der);
}

test "sign a file and read the signature back" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    // Two and a half pages of "code", then the signature.
    var code: [page_size * 5 / 2]u8 = undefined;
    for (&code, 0..) |*b, i| b.* = @truncate(i *% 7);
    var s: Signer = try .init(gpa, .{ .identifier = "test" }, code.len, .{ .base = 0, .limit = page_size, .main_binary = true });
    defer s.deinit();
    s.update(code[0..100]);
    s.update(code[100..]);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.writeAll(&code);
    try s.finish(&aw.writer);
    const file = aw.written();
    try std.testing.expectEqual(code.len + s.size(), file.len);

    const info = try inspect(arena.allocator(), .{ .bytes = file }, code.len, s.size());
    try std.testing.expect(info.valid);
    try std.testing.expectEqualStrings("test", info.identifier);
    try std.testing.expectEqual(@as(u64, 3), info.pages);
    try std.testing.expectEqual(macho.CS_ADHOC, info.flags);
    try std.testing.expect(std.mem.indexOf(u8, info.entitlements, "<key>" ++ hypervisor ++ "</key>") != null);
    try std.testing.expect(info.has_der);

    // A changed page no longer matches.
    file[page_size + 1] ^= 1;
    try std.testing.expect(!(try inspect(arena.allocator(), .{ .bytes = file }, code.len, s.size())).valid);
}
