//! `h9x cache ls` and `h9x cache prune`.
//!
//! Owned by W5, on cache.zig.

const std = @import("std");
const cli = @import("../cli.zig");
const cache = @import("../cache.zig");

/// What `prune` removes without `--unused`.
pub const default_unused_ns: u64 = 30 * std.time.ns_per_day;

pub fn run(ctx: *cli.Context, opts: cli.CacheOptions) !u8 {
    const dir = try cache.dir(ctx.arena, ctx.env);
    const now = std.Io.Timestamp.now(ctx.io, .real);
    switch (opts) {
        .ls => {
            const entries = try cache.list(ctx.arena, ctx.io, dir);
            if (ctx.common.json) try cache.writeListJson(ctx.stdout, entries) else try cache.writeList(ctx.stdout, entries, now);
        },
        .prune => |p| {
            const r = try cache.prune(ctx.arena, ctx.io, dir, now, p.unused_ns orelse default_unused_ns, p.dry_run);
            try writePruned(ctx.stdout, r, p.dry_run, ctx.common.json);
        },
    }
    return 0;
}

fn writePruned(w: *std.Io.Writer, r: cache.Pruned, dry_run: bool, json: bool) !void {
    if (json) {
        for (r.removed) |e| {
            var s: std.json.Stringify = .{ .writer = w };
            try s.write(.{ .kind = @tagName(e.kind), .name = e.name, .size = e.size, .removed = !dry_run });
            try w.writeByte('\n');
        }
        return;
    }
    var b: [16]u8 = undefined;
    for (r.removed) |e| try w.print("{s} {t}/{s} ({s})\n", .{
        if (dry_run) "would remove" else "removed",
        e.kind,
        e.name,
        cache.formatSize(&b, e.size),
    });
    for (r.kept) |e| try w.print("kept {t}/{s}: a build names it\n", .{ e.kind, e.name });
    try w.print("{s} {s}\n", .{ if (dry_run) "would free" else "freed", cache.formatSize(&b, r.freed) });
}

test writePruned {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const e: cache.Entry = .{ .kind = .runtimes, .name = "r2", .path = "/c/runtimes/r2", .size = 2048, .used = .zero };
    try writePruned(&w, .{ .removed = &.{e}, .kept = &.{}, .freed = 2048 }, true, false);
    try std.testing.expectEqualStrings("would remove runtimes/r2 (2.0K)\nwould free 2.0K\n", w.buffered());
}
