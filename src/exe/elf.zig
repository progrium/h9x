//! Linux executables: the archive appended after the runner's ELF image,
//! then the trailer.
//!
//! Owned by W4. Treats the archive as opaque bytes.
//!
//! The kernel maps an ELF executable by its program headers, so bytes past
//! the image are never loaded and change nothing about how it runs. The
//! archive starts on a page, and the runner finds it by the trailer, the
//! last 32 bytes of /proc/self/exe.

const std = @import("std");
const trailer = @import("trailer.zig");

pub const Error = error{ NotElf, AlreadyPacked };

/// Where the archive went.
pub const Layout = struct {
    offset: u64,
    length: u64,
    /// The size of the whole file.
    size: u64,
};

/// Checks that `runner` is an ELF file without a pack.
pub fn validate(runner: []const u8) Error!void {
    if (runner.len < 64 or !std.mem.eql(u8, runner[0..4], "\x7fELF")) return error.NotElf;
    if (trailer.isPacked(runner)) return error.AlreadyPacked;
}

/// Where `join` puts an archive of `len` bytes after `runner`.
pub fn layout(runner_len: u64, len: u64) Layout {
    const offset = std.mem.alignForward(u64, runner_len, trailer.archive_align);
    return .{ .offset = offset, .length = len, .size = offset + len + trailer.Trailer.size };
}

/// Writes `runner`, the `len` bytes of `archive` on the next page, and the
/// trailer to `out`.
pub fn join(out: *std.Io.Writer, runner: []const u8, archive: *std.Io.Reader, len: u64) !Layout {
    try validate(runner);
    const l = layout(runner.len, len);
    try out.writeAll(runner);
    try out.splatByteAll(0, @intCast(l.offset - runner.len));
    try trailer.copyArchive(out, archive, len);
    try out.writeAll(&trailer.encode(.{ .offset = l.offset, .length = len }));
    return l;
}

test join {
    const gpa = std.testing.allocator;
    var runner: [100]u8 = @splat(0xAA);
    runner[0..4].* = "\x7fELF".*;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var ar: std.Io.Reader = .fixed("archive!");
    const l = try join(&aw.writer, &runner, &ar, 8);
    const out = aw.written();
    try std.testing.expectEqual(@as(u64, 0x1000), l.offset);
    try std.testing.expectEqual(l.size, out.len);
    try std.testing.expectEqualSlices(u8, &runner, out[0..100]);
    const t = (try trailer.fromBytes(out)).?;
    try std.testing.expectEqualStrings("archive!", out[t.offset..][0..t.length]);

    // A packed executable can't be packed again.
    var ar2: std.Io.Reader = .fixed("x");
    try std.testing.expectError(error.AlreadyPacked, join(&aw.writer, out, &ar2, 1));
    try std.testing.expectError(error.NotElf, validate("MZ not an elf, but long enough to be one if it were........................"));
}
