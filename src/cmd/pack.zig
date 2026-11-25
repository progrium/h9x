//! `h9x pack`: a pack, or with `--exe` and `--target`, executables; and
//! `pack --inspect FILE`.
//!
//! Owned by W8, with `--inspect` from W4.

const cli = @import("../cli.zig");

pub fn run(ctx: *cli.Context, opts: cli.PackOptions) !u8 {
    _ = ctx;
    _ = opts;
    return error.NotImplemented;
}
