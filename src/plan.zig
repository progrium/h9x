//! Plans (design/prototype.md, "The build engine"): running Railpack in a
//! machine on the builder root, reading `plan.json` into a `Plan` with
//! plan.sh's rules, keeping it under the plan key, and `h9x plan`'s
//! summary.
//!
//! Owned by W2. The fixtures are each example's plan.json and plan.sh's
//! text output, captured from the POC.

const std = @import("std");
const types = @import("types.zig");

/// Reads a kept `plan.json` into a `Plan`, as plan.sh would.
pub fn read(arena: std.mem.Allocator, json: []const u8, src_dir: []const u8) !types.Plan {
    _ = arena;
    _ = json;
    _ = src_dir;
    return error.NotImplemented;
}
