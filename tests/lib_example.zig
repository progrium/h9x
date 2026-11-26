//! The library's example (src/root.zig), as an embedder writes it:
//! `lib_example DIR` plans and builds DIR into a fresh output directory,
//! then runs its start command. The integration tests run it.

const std = @import("std");
const h9x = @import("h9x");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: lib_example DIR\n", .{});
        return 2;
    }
    var b = try h9x.Builder.init(init.gpa, init.io, .{ .env = init.environ_map, .on_event = report });
    defer b.deinit();
    const run = struct {
        fn f(builder: *h9x.Builder, dir: []const u8) !u8 {
            const src = try builder.source(.{ .dir = dir });
            const plan = try builder.plan(src, .{});
            std.debug.print("provider {s}, {d} steps\n", .{ plan.value().provider, plan.value().steps.len });
            const art = try builder.build(plan, .{});
            var m = try art.machine(.{ .policy = .local });
            return m.run(&.{});
        }
    }.f;
    return run(b, args[1]) catch |e| {
        std.debug.print("lib_example: {t}\n", .{e});
        return h9x.exitCode(e);
    };
}

/// Logs and results on stderr; the program's own output comes through
/// on stdout as the machine writes it.
fn report(_: ?*anyopaque, ev: h9x.Event) void {
    switch (ev) {
        .log => |l| std.debug.print("h9x: {s}\n", .{l.text}),
        .layer => |l| std.debug.print("h9x: layer {t} {t}\n", .{ l.layer, l.state }),
        else => {},
    }
}
