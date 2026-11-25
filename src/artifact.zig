//! The output directory (design/prototype.md, "The output directory"): its
//! layout, `artifact.json`, and the `run` script, documented in
//! docs/output.md.
//!
//! Owned by W7.

const std = @import("std");
const types = @import("types.zig");

/// Reads `OUT/artifact.json`, for pack, export, and run on a build's
/// output.
pub fn read(arena: std.mem.Allocator, io: std.Io, out_dir: []const u8) !types.Artifact {
    _ = arena;
    _ = io;
    _ = out_dir;
    return error.NotImplemented;
}
