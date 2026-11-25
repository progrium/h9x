//! `h9x pack`: a pack, or with `--exe` and `--target`, executables; and
//! `pack --inspect FILE`.
//!
//! Owned by W8, with `--inspect` from W4.

const std = @import("std");
const cli = @import("../cli.zig");
const types = @import("../types.zig");
const exe = @import("../exe/exe.zig");

pub fn run(ctx: *cli.Context, opts: cli.PackOptions) !u8 {
    if (opts.inspect) |path| return inspect(ctx, path);
    return error.NotImplemented;
}

/// `pack --inspect FILE`: the trailer, the container's section, the
/// signature on macOS, the archive's digest, and pack.json, as text or,
/// with `--json`, one object on stdout. Exit 1 if FILE has no pack or
/// anything in it doesn't check out.
fn inspect(ctx: *cli.Context, path: []const u8) !u8 {
    const r = exe.inspect(ctx.arena, ctx.io, path) catch |e| switch (e) {
        error.NotPacked => {
            ctx.events.log("{s} has no pack: it doesn't end in an h9x trailer", .{path});
            return types.Exit.failed.code();
        },
        error.FileNotFound => {
            ctx.events.log("{s}: no such file", .{path});
            return types.Exit.usage.code();
        },
        else => return e,
    };
    if (ctx.common.json) try exe.writeJson(ctx.arena, ctx.stdout, r) else try exe.writeText(ctx.stdout, r);
    return if (r.ok()) types.Exit.ok.code() else types.Exit.failed.code();
}

test {
    _ = exe;
}
