//! The executable containers on real runners: exe/testdata/runner.zig,
//! built by Zig for Linux, macOS, and Windows, joined with an archive, read
//! back by `pack --inspect`'s code, and, where the host can, run.
//!
//! Owned by W4. A module of its own in build.zig's test step, so the
//! fixtures are built only for `zig build test`.

const std = @import("std");
const builtin = @import("builtin");
const exe = @import("exe/exe.zig");
const macho = @import("exe/macho.zig");

const fixtures = .{
    .elf = @embedFile("fixture_elf"),
    .macho = @embedFile("fixture_macho"),
    .pe = @embedFile("fixture_pe"),
};

/// An archive that is a tar with a pack.json, so inspect finds it.
fn archive(gpa: std.mem.Allocator) ![]u8 {
    const json = "{\"version\":1,\"start\":\"echo hi\"}";
    const buf = try gpa.alloc(u8, 512 * 4 + 40000);
    @memset(buf, 0);
    const h = buf[0..512];
    @memcpy(h[0..16], "./.h9x/pack.json");
    _ = try std.fmt.bufPrint(h[124..136], "{o:0>11}", .{json.len});
    h[156] = '0';
    @memcpy(h[257..262], "ustar");
    @memcpy(buf[512..][0..json.len], json);
    // Bytes past the tar's end, so pages of it hash differently.
    for (buf[2048..], 0..) |*b, i| b.* = @truncate(i *% 31);
    return buf;
}

const Packed = struct {
    path: [:0]u8,
    bytes: []u8,
};

fn pack(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, container: exe.Container, runner: []const u8, arch: []const u8) !Packed {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var r: std.Io.Reader = .fixed(arch);
    const j = try exe.join(gpa, &aw.writer, container, runner, &r, arch.len, .{ .identifier = name });
    try std.testing.expectEqual(j.size, aw.written().len);
    try std.testing.expectEqualSlices(u8, arch, aw.written()[j.offset..][0..j.length]);
    const bytes = try aw.toOwnedSlice();
    errdefer gpa.free(bytes);
    try dir.writeFile(io, .{ .sub_path = name, .data = bytes, .flags = .{ .permissions = .executable_file } });
    return .{ .path = try dir.realPathFileAlloc(io, name, gpa), .bytes = bytes };
}

fn runIt(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const res = try std.process.run(gpa, io, .{ .argv = &.{path} });
    defer gpa.free(res.stderr);
    errdefer gpa.free(res.stdout);
    if (res.term != .exited or res.term.exited != 0) {
        std.debug.print("{s}: {any}\n{s}\n", .{ path, res.term, res.stderr });
        return error.RunFailed;
    }
    return res.stdout;
}

test "each container joins a real runner, and inspect reads it back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const arch = try archive(gpa);
    defer gpa.free(arch);

    inline for ([_]exe.Container{ .elf, .macho, .pe }) |c| {
        const p = try pack(gpa, io, tmp.dir, "app-" ++ @tagName(c), c, @field(fixtures, @tagName(c)), arch);
        defer gpa.free(p.path);
        defer gpa.free(p.bytes);

        const r = try exe.inspect(arena.allocator(), io, p.path);
        try std.testing.expectEqual(@as(?exe.Container, c), r.container);
        try std.testing.expect(r.ok());
        try std.testing.expectEqual(@as(u64, arch.len), r.trailer.length);
        try std.testing.expectEqual(@as(u64, 0), r.trailer.offset % 0x1000);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(arch, &digest, .{});
        try std.testing.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), r.digest);
        try std.testing.expectEqualStrings("{\"version\":1,\"start\":\"echo hi\"}", r.pack_json.?);
        switch (c) {
            .elf => try std.testing.expect(r.section == null),
            .macho => {
                try std.testing.expect(r.section.?.matches);
                const sig = r.signature.?;
                try std.testing.expect(sig.valid and sig.der);
                try std.testing.expectEqualStrings("app-macho", sig.identifier);
                try std.testing.expectEqualStrings("com.apple.security.hypervisor", sig.entitlements[0]);
            },
            .pe => try std.testing.expect(r.section.?.matches),
        }

        // The text and JSON forms both write.
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try exe.writeText(&out.writer, r);
        try exe.writeJson(arena.allocator(), &out.writer, r);
    }
}

test "a packed Linux executable runs and finds its archive" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const arch = try archive(gpa);
    defer gpa.free(arch);
    const p = try pack(gpa, io, tmp.dir, "app", .elf, fixtures.elf, arch);
    defer gpa.free(p.path);
    defer gpa.free(p.bytes);
    const out = try runIt(gpa, io, p.path);
    defer gpa.free(out);
    try std.testing.expectEqualSlices(u8, arch, out);
}

test "a packed macOS executable passes codesign --verify --strict and runs" {
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const arch = try archive(gpa);
    defer gpa.free(arch);
    const p = try pack(gpa, io, tmp.dir, "app", .macho, fixtures.macho, arch);
    defer gpa.free(p.path);
    defer gpa.free(p.bytes);

    const verify = try std.process.run(gpa, io, .{ .argv = &.{ "codesign", "--verify", "--strict", "--verbose=4", p.path } });
    defer gpa.free(verify.stdout);
    defer gpa.free(verify.stderr);
    if (verify.term != .exited or verify.term.exited != 0) {
        std.debug.print("codesign --verify: {s}\n", .{verify.stderr});
        return error.VerifyFailed;
    }
    const ents = try std.process.run(gpa, io, .{ .argv = &.{ "codesign", "--display", "--entitlements", "-", "--xml", p.path } });
    defer gpa.free(ents.stdout);
    defer gpa.free(ents.stderr);
    try std.testing.expect(std.mem.indexOf(u8, ents.stdout, "com.apple.security.hypervisor") != null);

    const out = try runIt(gpa, io, p.path);
    defer gpa.free(out);
    try std.testing.expectEqualSlices(u8, arch, out);
}

test "macho.sign re-signs a runner Zig's linker signed" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const l = try macho.sign(gpa, &aw.writer, fixtures.macho, .{ .identifier = "runner" });
    const out = aw.written();
    const info = try macho.parse(out);
    try std.testing.expectEqual(l.signature, info.signature.?.dataoff);
    try std.testing.expectEqual(out.len, info.linkedit.fileoff + info.linkedit.filesize);
    const sig = try @import("exe/adhoc.zig").inspect(arena.allocator(), .{ .bytes = out }, l.signature, l.signature_size);
    try std.testing.expect(sig.valid);
}
