//! `h9x shell`: the build stage's layers (or the run stage's, with
//! `--stage run`), the source writable at /app, and a scratch up layer on
//! top, running `sh` or the given command.
//!
//! Owned by W10.

const cli = @import("../cli.zig");

pub fn run(ctx: *cli.Context, opts: cli.ShellOptions) !u8 {
    _ = ctx;
    _ = opts;
    return error.NotImplemented;
}
