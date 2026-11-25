//! `h9x plan`: plan if there's no kept plan, then print the summary, or
//! plan.json as kept with `--json`. Builds nothing.
//!
//! Owned by W10, on W2's plan.zig.

const cli = @import("../cli.zig");

pub fn run(ctx: *cli.Context, opts: cli.PlanOptions) !u8 {
    _ = ctx;
    _ = opts;
    return error.NotImplemented;
}
