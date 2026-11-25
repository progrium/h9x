//! A stand-in runner for exe/fixture_test.zig: finds the trailer at the end
//! of its own file, as h9x-runner does, and writes the archive to stdout.
//! Built for each container's OS by build.zig's test step.

const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const self = try std.process.executablePathAlloc(io, init.arena.allocator());
    const f = try std.Io.Dir.cwd().openFile(io, self, .{});
    defer f.close(io);
    const size = try f.length(io);
    var t: [32]u8 = undefined;
    if (size < t.len or try f.readPositionalAll(io, &t, size - t.len) != t.len) return 3;
    if (!std.mem.eql(u8, t[0..8], "H9XPACK\x00")) return 3;
    const off = std.mem.readInt(u64, t[8..16], .little);
    const len = std.mem.readInt(u64, t[16..24], .little);
    const buf = try init.arena.allocator().alloc(u8, @intCast(len));
    if (try f.readPositionalAll(io, buf, off) != len) return 4;
    try std.Io.File.stdout().writeStreamingAll(io, buf);
    return 0;
}
