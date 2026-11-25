//! `h9x cache ls` and `h9x cache prune`.
//!
//! Owned by W5, on cache.zig.

const cli = @import("../cli.zig");

pub fn run(ctx: *cli.Context, opts: cli.CacheOptions) !u8 {
    _ = ctx;
    _ = opts;
    return error.NotImplemented;
}
