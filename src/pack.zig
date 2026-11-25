//! Packs (design/prototype.md, "Packs"): the base root and run layers
//! flattened into one tar, with `/.h9x/pack.json`, `/.h9x/run`, and the
//! index; `--exe` and `--target`, runner downloads and `--runner`, and
//! `SHA256SUMS`.
//!
//! Owned by W8. The host's runner is embedded (embedded.runner).

const std = @import("std");
const types = @import("types.zig");

/// `/.h9x/pack.json`: what the runner needs to start the app.
pub const PackJson = struct {
    version: u32 = 1,
    arch: types.Arch,
    env: []const []const u8,
    start: ?[]const u8,
    cwd: []const u8 = "/app",
    /// The run policy, as plan text, sealed: the environment can narrow it
    /// and never widen it.
    policy: []const u8,
    layers: []const types.Layer,
    debug: bool = true,
};
