//! `h9x build`: write the output directory, `NAME.h9` in the cwd for a
//! directory source and `$cache/builds/KEY` for a remote one.
//!
//! Owned by W7, which wires source, config, policy, roots, plan, layers,
//! and artifact together here.

const cli = @import("../cli.zig");

pub fn run(ctx: *cli.Context, opts: cli.BuildOptions) !u8 {
    if (opts.poc) ctx.events.log("warning: h9x [-o OUT] DIR is deprecated; use h9x build DIR [-o OUT]", .{});
    return error.NotImplemented;
}
