//! `h9x run`: build, then run the start command, or the command after
//! `--`, on the run stage. A remote source runs under the untrusted profile
//! unless `--trust` is given.
//!
//! Owned by W10.

const cli = @import("../cli.zig");

pub fn run(ctx: *cli.Context, opts: cli.RunOptions) !u8 {
    _ = ctx;
    _ = opts;
    return error.NotImplemented;
}
