//! Policy (design/prototype.md, "Policy"): policies as h9 plan lines, the
//! per-phase defaults, narrowing, the registry allowlist, and compiling a
//! policy into `h9.Machine.Options`.
//!
//! Owned by W1. When h9's `Machine.init` takes `.plan`, `compile` passes
//! the text through and goes away.

const std = @import("std");
const h9 = @import("h9");
const types = @import("types.zig");

pub const Policy = types.Policy;

/// The default policy for a phase at a trust level, before mounts.
pub fn defaults(phase: types.Phase, trust: types.Trust) Policy {
    return .{ .phase = phase, .trust = trust };
}

/// `base` narrowed by `by`; error.Widens if `by` would widen it (exit 2).
pub fn narrow(arena: std.mem.Allocator, base: Policy, by: Policy) !Policy {
    _ = arena;
    _ = base;
    _ = by;
    return error.NotImplemented;
}

/// The policy as plan text, with secrets' values hidden.
pub fn print(p: Policy, w: *std.Io.Writer) std.Io.Writer.Error!void {
    _ = p;
    _ = w;
}

/// The policy as `h9.Machine.Options`, without `stdio`, which the caller
/// sets.
pub fn compile(arena: std.mem.Allocator, p: Policy) !h9.Machine.Options {
    _ = arena;
    _ = p;
    return error.NotImplemented;
}
