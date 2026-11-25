//! h9x-runner: the program a packed executable starts as
//! (design/prototype.md, "Packs"). It reads the trailer from its own file,
//! verifies the archive's digest, extracts it once into
//! `${XDG_CACHE_HOME:-~/.cache}/h9x/packs/DIGEST`, and runs the start
//! command under the policy sealed in pack.json.
//!
//! Owned by W8. The skeleton finds the trailer and stops there.

const std = @import("std");
const h9x = @import("h9x");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    var err_buf: [1024]u8 = undefined;
    var err = std.Io.File.stderr().writerStreaming(io, &err_buf);
    defer err.interface.flush() catch {};

    const self = try std.process.executablePathAlloc(io, init.arena.allocator());
    const t = readTrailer(io, self) catch null orelse {
        try err.interface.print("h9x-runner: no pack in {s}\n", .{self});
        return h9x.types.Exit.setup.code();
    };
    try err.interface.print("h9x-runner: a pack of {d} bytes at {d}; running packs isn't implemented yet\n", .{ t.length, t.offset });
    return h9x.types.Exit.setup.code();
}

fn readTrailer(io: std.Io, path: []const u8) !?h9x.types.Trailer {
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const n = h9x.types.Trailer.size;
    if (size < n) return null;
    var b: [n]u8 = undefined;
    if (try f.readPositionalAll(io, &b, size - n) != n) return null;
    return h9x.trailer.decode(&b);
}
