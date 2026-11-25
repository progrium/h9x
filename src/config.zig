//! Config (design/prototype.md, "Config"): `h9x.toml` from the source and
//! from `~/.config/h9x/config.toml`, the `H9X_*` variables, and their
//! precedence: flags, then variables, then the source's file, then the
//! user's.
//!
//! Owned by W1, with toml.zig.

const std = @import("std");
const types = @import("types.zig");
const cli = @import("cli.zig");

pub const Config = struct {
    pub const Roots = struct {
        base: []const []const u8 = &.{},
        build: []const []const u8 = &.{},
    };
    pub const Build = struct {
        memory: ?u64 = null,
        net: ?types.Net = null,
        netallow: []const []const u8 = &.{},
        secrets: []const []const u8 = &.{},
    };
    pub const Run = struct {
        /// Plan lines that narrow the run's policy.
        policy: ?[]const u8 = null,
    };
    pub const Pack = struct {
        mount: []const []const u8 = &.{},
        targets: []const types.Target = &.{},
    };

    roots: Roots = .{},
    build: Build = .{},
    run: Run = .{},
    pack: Pack = .{},
};

/// The config for `source`, from its files and the environment. Flags are
/// applied by the command.
pub fn load(ctx: *cli.Context, source: types.Source) !Config {
    _ = ctx;
    _ = source;
    return error.NotImplemented;
}
