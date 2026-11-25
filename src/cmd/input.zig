//! What `pack` and `export` work on: a build's output directory, with its
//! artifact.json read and its paths made absolute.
//!
//! Owned by W8. A SOURCE that isn't a build's output is built first once
//! `h9x build` works (W7); `resolve` is where that goes.

const std = @import("std");
const cli = @import("../cli.zig");
const types = @import("../types.zig");
const artifact = @import("../artifact.zig");
const cache = @import("../cache.zig");
const config = @import("../config.zig");

pub const Input = struct {
    /// The output directory, absolute.
    dir: []const u8,
    /// Its name, without `.h9`: what packs and images are named.
    name: []const u8,
    art: types.Artifact,
    /// The base root, absolute.
    base: []const u8,
    /// The run layers, bottom first, with absolute paths.
    layers: []const types.Layer,
    cfg: config.Config,
};

/// SOURCE as a build's output. A directory with an artifact.json is one;
/// anything else needs a build, which isn't wired up yet.
pub fn resolve(ctx: *cli.Context, source: []const u8) !Input {
    const arena = ctx.arena;
    const io = ctx.io;
    const dir = std.Io.Dir.cwd().realPathFileAlloc(io, source, arena) catch |e| switch (e) {
        error.FileNotFound => {
            ctx.events.log("{s}: no such directory", .{source});
            return error.BadSource;
        },
        else => |x| return x,
    };
    const art = artifact.read(arena, io, dir) catch |e| switch (e) {
        error.NoArtifact => {
            // W7: build SOURCE here and use its output.
            ctx.events.log("{s} has no artifact.json; give a build's output directory until h9x build is wired up", .{source});
            return error.NotImplemented;
        },
        error.BadArtifact, error.UnsupportedVersion => {
            ctx.events.log("{s}/{s}: {t}", .{ source, artifact.json_file, e });
            return error.BadConfig;
        },
        else => |x| return x,
    };
    const cache_dir = try cache.dir(arena, ctx.env);
    const layers = try arena.alloc(types.Layer, art.layers.len);
    for (layers, art.layers) |*o, l| o.* = .{ .name = l.name, .key = l.key, .path = try artifact.resolvePath(arena, dir, cache_dir, l.path) };
    for (layers) |l| cache.touch(io, l.path);
    const base = try artifact.resolvePath(arena, dir, cache_dir, art.base.path);
    cache.touch(io, base);

    // The output directory has no h9x.toml of its own, so this is the
    // user's config and the environment.
    var diag: config.Diag = .{};
    const cfg = config.loadFrom(arena, io, ctx.env, dir, &diag) catch |e| switch (e) {
        error.Config => {
            ctx.events.log("{f}", .{diag});
            return error.BadConfig;
        },
        else => |x| return x,
    };
    for (cfg.warnings) |w| ctx.events.log("warning: {s}", .{w});

    var name = std.fs.path.basename(dir);
    if (std.mem.endsWith(u8, name, ".h9") and name.len > 3) name = name[0 .. name.len - 3];
    return .{ .dir = dir, .name = name, .art = art, .base = base, .layers = layers, .cfg = cfg };
}
