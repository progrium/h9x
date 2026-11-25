//! The real h9x-runner, joined with a pack the way `pack --exe` joins it,
//! and run with `H9X_PACK=info`, which reads the trailer, the index, and
//! pack.json and checks the seal without starting a machine: so it runs
//! on any host CI builds the runner for. Then a byte of the archive is
//! changed, and the runner says so.
//!
//! Owned by W8. A module of its own in build.zig's test step, beside
//! exe_test.zig, since it embeds the runner.

const std = @import("std");
const builtin = @import("builtin");
const pack = @import("pack.zig");
const exe = @import("exe/exe.zig");
const runners = @import("runners.zig");

const runner = @embedFile("h9x_runner");

test "a packed runner reads its own pack and checks the seal" {
    const t = runners.hostTarget() orelse return error.SkipZigTest;
    if (t.container() == .pe) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var a: std.heap.ArenaAllocator = .init(gpa);
    defer a.deinit();
    const arena = a.allocator();
    var fx = try pack.Fixture.init(arena);
    defer fx.deinit();

    // The pack, then the executable.
    const tf = try fx.tmp.dir.createFile(io, "app.tar", .{ .read = true });
    defer tf.close(io);
    const r = try pack.write(gpa, io, try fx.input(arena), .{ .policy = "net disable\nwrite overlay\n" }, tf);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var buf: [64 * 1024]u8 = undefined;
    var tr = tf.reader(io, &buf);
    const j = try exe.join(gpa, &aw.writer, t.container(), runner, &tr.interface, r.size, .{ .identifier = "app" });
    try fx.tmp.dir.writeFile(io, .{ .sub_path = "packed", .data = aw.written(), .flags = .{ .permissions = .executable_file } });
    const path = try fx.tmp.dir.realPathFileAlloc(io, "packed", arena);

    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("H9X_PACK", "info");
    try env.put("HOME", fx.abs);
    {
        const res = try std.process.run(arena, io, .{ .argv = &.{path}, .environ_map = &env });
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, res.term);
        try std.testing.expect(std.mem.indexOf(u8, res.stdout, &r.digest) != null);
        try std.testing.expect(std.mem.indexOf(u8, res.stdout, "(sealed)") != null);
        try std.testing.expect(std.mem.indexOf(u8, res.stdout, "policy  net disable\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, res.stdout, "layer   app a1\n") != null);
    }

    // A changed byte, in a file's data, past the index's reach.
    const bytes = aw.written();
    const at = j.offset + std.mem.indexOf(u8, bytes[j.offset..][0..j.length], "echo hello").?;
    bytes[at] = 'E';
    try fx.tmp.dir.writeFile(io, .{ .sub_path = "packed", .data = bytes, .flags = .{ .permissions = .executable_file } });
    if (t.container() == .macho) return; // Its signature covers the archive: the OS refuses it first.
    {
        const res = try std.process.run(arena, io, .{ .argv = &.{path}, .environ_map = &env });
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, res.term);
        try std.testing.expect(std.mem.indexOf(u8, res.stdout, "CHANGED") != null);
    }
    // Run for real, it's refused before anything is extracted.
    _ = env.swapRemove("H9X_PACK");
    {
        const res = try std.process.run(arena, io, .{ .argv = &.{path}, .environ_map = &env });
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 125 }, res.term);
        try std.testing.expect(std.mem.indexOf(u8, res.stderr, "doesn't match its digest") != null);
    }
}

// pack.zig's policy code links h9's libkern, which calls back into Zig code
// that only `Machine.init` and `Machine.run` reach.
test {
    const h9 = @import("h9");
    _ = &h9.Machine.init;
    _ = &h9.Machine.run;
}
