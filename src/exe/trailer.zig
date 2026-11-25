//! The 32-byte trailer every packed executable ends with
//! (`types.Trailer`): finding it in a file, checking it, and writing it.
//!
//! Owned by W4, with `pack --inspect`.

const std = @import("std");
const types = @import("../types.zig");

pub const Trailer = types.Trailer;

/// Archives start on a page in every container, so a later in-place mount
/// can map one without copying.
pub const archive_align = 0x1000;

/// Encodes `t` as its 32 bytes, little-endian.
pub fn encode(t: Trailer) [Trailer.size]u8 {
    var b: [Trailer.size]u8 = undefined;
    @memcpy(b[0..8], &t.magic);
    std.mem.writeInt(u64, b[8..16], t.offset, .little);
    std.mem.writeInt(u64, b[16..24], t.length, .little);
    std.mem.writeInt(u32, b[24..28], t.version, .little);
    std.mem.writeInt(u32, b[28..32], t.reserved, .little);
    return b;
}

/// Decodes a trailer, or null if the magic doesn't match.
pub fn decode(b: *const [Trailer.size]u8) ?Trailer {
    if (!std.mem.eql(u8, b[0..8], &Trailer.magic_bytes)) return null;
    return .{
        .offset = std.mem.readInt(u64, b[8..16], .little),
        .length = std.mem.readInt(u64, b[16..24], .little),
        .version = std.mem.readInt(u32, b[24..28], .little),
        .reserved = std.mem.readInt(u32, b[28..32], .little),
    };
}

pub const CheckError = error{
    /// The trailer's version is newer than this h9x reads.
    UnsupportedVersion,
    /// The archive the trailer names runs past the trailer.
    BadRange,
};

/// Checks a decoded trailer against the size of the file it ends.
pub fn check(t: Trailer, file_size: u64) CheckError!void {
    if (t.version != Trailer.current_version) return error.UnsupportedVersion;
    if (file_size < Trailer.size) return error.BadRange;
    const end = std.math.add(u64, t.offset, t.length) catch return error.BadRange;
    if (end > file_size - Trailer.size) return error.BadRange;
}

/// The trailer at the end of `bytes`, checked, or null if there is none.
pub fn fromBytes(bytes: []const u8) CheckError!?Trailer {
    if (bytes.len < Trailer.size) return null;
    const t = decode(bytes[bytes.len - Trailer.size ..][0..Trailer.size]) orelse return null;
    try check(t, bytes.len);
    return t;
}

/// The trailer at the end of `file`, checked, or null if there is none.
pub fn read(io: std.Io, file: std.Io.File) !?Trailer {
    const size = try file.length(io);
    if (size < Trailer.size) return null;
    var b: [Trailer.size]u8 = undefined;
    if (try file.readPositionalAll(io, &b, size - Trailer.size) != b.len) return null;
    const t = decode(&b) orelse return null;
    try check(t, size);
    return t;
}

/// Whether `runner` already ends in a trailer: packing a packed executable
/// again would nest one archive in another, so the containers refuse it.
pub fn isPacked(runner: []const u8) bool {
    if (runner.len < Trailer.size) return false;
    return decode(runner[runner.len - Trailer.size ..][0..Trailer.size]) != null;
}

/// Streams `len` bytes of `archive` to `out`.
pub fn copyArchive(out: *std.Io.Writer, archive: *std.Io.Reader, len: u64) !void {
    try archive.streamExact64(out, len);
}

test "encode and decode" {
    const t: Trailer = .{ .offset = 1 << 20, .length = 12345 };
    const b = encode(t);
    try std.testing.expectEqual(t, decode(&b).?);
    var bad = b;
    bad[0] = 'X';
    try std.testing.expectEqual(@as(?Trailer, null), decode(&bad));
}

test "check refuses a range past the trailer, or a newer version" {
    try check(.{ .offset = 10, .length = 20 }, 62);
    try std.testing.expectError(error.BadRange, check(.{ .offset = 10, .length = 21 }, 62));
    try std.testing.expectError(error.BadRange, check(.{ .offset = std.math.maxInt(u64), .length = 2 }, 62));
    try std.testing.expectError(error.UnsupportedVersion, check(.{ .offset = 0, .length = 0, .version = 2 }, 62));
}

test fromBytes {
    var buf: [100]u8 = @splat(0);
    try std.testing.expectEqual(@as(?Trailer, null), try fromBytes(&buf));
    buf[68..100].* = encode(.{ .offset = 4, .length = 60 });
    try std.testing.expectEqual(@as(u64, 60), (try fromBytes(&buf)).?.length);
    try std.testing.expect(isPacked(&buf));
}
