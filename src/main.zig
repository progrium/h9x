//! h9x: build an app from source into layers that h9 runs, and pack, run,
//! or export it (design/prototype.md).

const std = @import("std");
const build_options = @import("build_options");
const types = @import("types.zig");
const cli = @import("cli.zig");
const events = @import("events.zig");

const cmd = struct {
    const run = @import("cmd/run.zig");
    const build = @import("cmd/build.zig");
    const shell = @import("cmd/shell.zig");
    const plan = @import("cmd/plan.zig");
    const pack = @import("cmd/pack.zig");
    const @"export" = @import("cmd/export.zig");
    const cache = @import("cmd/cache.zig");
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    defer out.interface.flush() catch {};
    var err_buf: [4096]u8 = undefined;
    var err = std.Io.File.stderr().writerStreaming(io, &err_buf);
    defer err.interface.flush() catch {};

    const parsed = cli.parse(arena, args[1..]) catch |e| switch (e) {
        error.Usage => {
            const code = types.Exit.usage.code();
            // With --json, the usage error is events too, ending in result.
            if (events.wantsJson(args[1..])) {
                var emitter: events.Emitter = .{ .w = &err.interface, .json = true };
                emitter.log("{s}", .{if (cli.why.len > 0) cli.why else "usage error"});
                emitter.result(args[1], code, null, 0);
                return code;
            }
            if (cli.why.len > 0) err.interface.print("h9x: {s}\n", .{cli.why}) catch {};
            err.interface.writeAll(cli.usage) catch {};
            return code;
        },
        error.OutOfMemory => return e,
    };
    switch (parsed.command) {
        .help => {
            try out.interface.writeAll(cli.usage);
            return 0;
        },
        .version => {
            try out.interface.print("h9x {s}\n", .{build_options.version});
            return 0;
        },
        else => {},
    }

    var emitter: events.Emitter = .{ .w = &err.interface, .json = parsed.common.json, .io = io };
    var ctx: cli.Context = .{
        .gpa = init.gpa,
        .arena = arena,
        .io = io,
        .env = init.environ_map,
        .stdout = &out.interface,
        .stderr = &err.interface,
        .events = &emitter,
        .common = parsed.common,
    };
    const start = std.Io.Timestamp.now(io, .awake);
    const name = @tagName(parsed.command);
    const status: u8 = dispatch(&ctx, parsed.command) catch |e| blk: {
        out.interface.flush() catch {};
        // anyerror, so the switch stays valid as the commands' error sets grow.
        switch (@as(anyerror, e)) {
            error.NotImplemented => emitter.log("{s} isn't implemented yet", .{name}),
            else => |x| emitter.log("{s}: {t}", .{ name, x }),
        }
        break :blk events.exitFor(e).code();
    };
    out.interface.flush() catch {};
    const ms = start.untilNow(io, .awake).toMilliseconds();
    emitter.result(name, status, if (status == 0) ctx.result_out else null, @intCast(@max(ms, 0)));
    return status;
}

fn dispatch(ctx: *cli.Context, c: cli.Command) !u8 {
    return switch (c) {
        .run => |o| cmd.run.run(ctx, o),
        .build => |o| cmd.build.run(ctx, o),
        .shell => |o| cmd.shell.run(ctx, o),
        .plan => |o| cmd.plan.run(ctx, o),
        .pack => |o| cmd.pack.run(ctx, o),
        .@"export" => |o| cmd.@"export".run(ctx, o),
        .cache => |o| cmd.cache.run(ctx, o),
        .help, .version => unreachable,
    };
}

// Every module's tests, so `zig build test` runs them without build.zig
// naming each file. A new module is added here.
test {
    _ = @import("types.zig");
    _ = @import("units.zig");
    _ = @import("cli.zig");
    _ = @import("events.zig");
    _ = @import("embedded.zig");
    _ = @import("machine.zig");
    _ = @import("source.zig");
    _ = @import("config.zig");
    _ = @import("toml.zig");
    _ = @import("policy.zig");
    _ = @import("roots.zig");
    _ = @import("download.zig");
    _ = @import("wolfi.zig");
    _ = @import("plan.zig");
    _ = @import("layers.zig");
    _ = @import("artifact.zig");
    _ = @import("tar.zig");
    _ = @import("index.zig");
    _ = @import("pack.zig");
    _ = @import("oci.zig");
    _ = @import("cache.zig");
    _ = @import("exe/trailer.zig");
    _ = @import("exe/elf.zig");
    _ = @import("exe/macho.zig");
    _ = @import("exe/pe.zig");
    _ = @import("exe/adhoc.zig");
    _ = @import("runners.zig");
    _ = @import("cmd/pack.zig");
    _ = @import("cmd/export.zig");
    _ = cmd;
}
