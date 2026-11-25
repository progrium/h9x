//! `h9x export`: an OCI image layout with `--oci FILE`, or a `docker save`
//! tarball on stdout with `--docker`. The image's layers are the base root,
//! then each run layer, bottom first, as oci.zig writes them; it's named
//! `NAME:latest`, after the build's output directory.
//!
//! Owned by W9, on W3's oci.zig.

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const oci = @import("../oci.zig");
const input = @import("input.zig");

pub fn run(ctx: *cli.Context, opts: cli.ExportOptions) !u8 {
    const arena = ctx.arena;
    const io = ctx.io;
    const in = try input.resolve(ctx, opts.source);
    if (opts.format == .docker and (Io.File.stdout().isTty(io) catch false))
        return ctx.events.fail(error.Usage, "--docker writes a tarball to stdout; pipe it to docker load", .{});

    const cwd = Io.Dir.cwd();
    var dirs: std.ArrayList(Io.Dir) = .empty;
    defer for (dirs.items) |d| d.close(io);
    try dirs.append(arena, try cwd.openDir(io, in.base, .{ .iterate = true }));
    for (in.layers) |l| try dirs.append(arena, try cwd.openDir(io, l.path, .{ .iterate = true }));

    // The gzipped layers are staged in the output directory.
    var rand: [6]u8 = undefined;
    io.random(&rand);
    const work_name = try std.fmt.allocPrint(arena, ".export-{x}", .{&rand});
    var out_dir = try cwd.openDir(io, in.dir, .{});
    defer out_dir.close(io);
    var work = try out_dir.createDirPathOpen(io, work_name, .{});
    defer {
        work.close(io);
        out_dir.deleteTree(io, work_name) catch {};
    }

    const ref = try refName(arena, in.name);
    const image = oci.Image.ofArtifact(in.art);
    switch (opts.format) {
        .docker => {
            const r = try oci.write(ctx.gpa, io, image, dirs.items, work, ctx.stdout, .{ .format = .docker, .ref = ref });
            try ctx.stdout.flush();
            ctx.events.log("wrote {s}:latest to stdout: image {s}", .{ ref, &r.digest });
        },
        .oci => |path| {
            const tmp = try std.fmt.allocPrint(arena, "{s}/.{s}.{x}.tmp", .{ std.fs.path.dirname(path) orelse ".", std.fs.path.basename(path), &rand });
            const f = try cwd.createFile(io, tmp, .{});
            var keep = false;
            defer if (!keep) cwd.deleteFile(io, tmp) catch {};
            const r = blk: {
                defer f.close(io);
                var buf: [64 * 1024]u8 = undefined;
                var fw = f.writer(io, &buf);
                const r = oci.write(ctx.gpa, io, image, dirs.items, work, &fw.interface, .{ .format = .oci, .ref = ref }) catch |e| {
                    if (e == error.WriteFailed) if (fw.err) |x| return x;
                    return e;
                };
                fw.interface.flush() catch |e| return if (fw.err) |x| x else e;
                break :blk r;
            };
            try cwd.rename(tmp, cwd, path, io);
            keep = true;
            ctx.events.log("wrote {s}: image {s}", .{ path, &r.digest });
        },
    }
    return 0;
}

/// An image name docker takes, from the output directory's: lowercase,
/// with anything but letters, digits, `.`, `_`, and `-` as `-`.
fn refName(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, name.len);
    for (name, out) |c, *o| o.* = switch (c) {
        'a'...'z', '0'...'9', '.', '_', '-' => c,
        'A'...'Z' => c + 32,
        else => '-',
    };
    // A name starts with a letter or digit.
    var start: usize = 0;
    while (start < out.len and (out[start] == '.' or out[start] == '_' or out[start] == '-')) start += 1;
    return if (start == out.len) "app" else out[start..];
}

test refName {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("my-app", try refName(a.allocator(), "My App"));
    try std.testing.expectEqualStrings("app", try refName(a.allocator(), "..."));
}
