//! `h9x plan`: plan if there's no kept plan, then print the summary, or
//! plan.json as kept with `--json`. Builds nothing: it makes the builder
//! root Railpack runs on, and keeps the plan in the build's output
//! directory, where `build` finds it.

const std = @import("std");
const cli = @import("../cli.zig");
const plan = @import("../plan.zig");
const build = @import("build.zig");
const print = @import("print.zig");

pub fn run(ctx: *cli.Context, opts: cli.PlanOptions) !u8 {
    if (ctx.common.print) return print.phases(ctx, .{ .source = opts.source, .command = .plan });
    const pr = try build.prepare(ctx, .{ .source = opts.source, .replan = opts.replan });
    ctx.result_out = pr.out;
    if (ctx.common.json) {
        // plan.json as kept, on stdout, so an agent can read it whole.
        const path = try std.fs.path.join(ctx.arena, &.{ pr.out, "plan.json" });
        const text = try std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(64 << 20));
        try ctx.stdout.writeAll(text);
        if (text.len > 0 and text[text.len - 1] != '\n') try ctx.stdout.writeByte('\n');
        return 0;
    }
    try plan.writeSummary(ctx.arena, ctx.stdout, pr.plan);
    return 0;
}
