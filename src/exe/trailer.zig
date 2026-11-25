//! The 32-byte trailer every packed executable ends with
//! (`types.Trailer`): finding it in a file, checking it, and writing it.
//!
//! Owned by W4, with `pack --inspect`.

const std = @import("std");
const types = @import("../types.zig");

pub const Trailer = types.Trailer;

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

test "encode and decode" {
    const t: Trailer = .{ .offset = 1 << 20, .length = 12345 };
    const b = encode(t);
    try std.testing.expectEqual(t, decode(&b).?);
    var bad = b;
    bad[0] = 'X';
    try std.testing.expectEqual(@as(?Trailer, null), decode(&bad));
}
