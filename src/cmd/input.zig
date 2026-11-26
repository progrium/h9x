//! What `pack` and `export` work on: a build's output directory, with its
//! artifact.json read and its paths made absolute.
//!
//! A SOURCE that isn't a build's output is built first, with `h9x build`'s
//! defaults.

const std = @import("std");
const cli = @import("../cli.zig");
const types = @import("../types.zig");
const artifact = @import("../artifact.zig");
const cache = @import("../cache.zig");
const config = @import("../config.zig");
const build = @import("build.zig");

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
    /// Whether it was built from a git or tarball source just now, which
    /// runs untrusted unless `--trust` is given. A build's output given by
    /// path is the person's own, and trusted.
    remote: bool = false,
};

/// SOURCE as a build's output. A directory with an artifact.json is one;
/// anything else is built first.
pub fn resolve(ctx: *cli.Context, source: []const u8) !Input {
    if (try output(ctx, source)) |in| return in;
    const r = try build.build(ctx, .{ .source = source });
    var in = try fromOutput(ctx, r.out, r.artifact, .{ .cfg = r.env.cfg, .name = r.source.name });
    in.remote = r.source.remote();
    return in;
}

/// SOURCE as a build's output, if it's a directory with an artifact.json;
/// null otherwise.
pub fn output(ctx: *cli.Context, source: []const u8) !?Input {
    const arena = ctx.arena;
    const io = ctx.io;
    if (std.Io.Dir.cwd().realPathFileAlloc(io, source, arena)) |dir| {
        if (artifact.read(arena, io, dir)) |art| {
            return try fromOutput(ctx, dir, art, null);
        } else |e| switch (e) {
            error.NoArtifact => {},
            error.BadArtifact, error.UnsupportedVersion => {
                ctx.events.log("{s}/{s}: {t}", .{ source, artifact.json_file, e });
                return error.BadConfig;
            },
            else => |x| return x,
        }
    } else |_| {}
    return null;
}

const Built = struct { cfg: config.Config, name: []const u8 };

fn fromOutput(ctx: *cli.Context, dir: []const u8, art: types.Artifact, built: ?Built) !Input {
    const arena = ctx.arena;
    const io = ctx.io;
    const cache_dir = try cache.dir(arena, ctx.env);
    const layers = try arena.alloc(types.Layer, art.layers.len);
    for (layers, art.layers) |*o, l| o.* = .{ .name = l.name, .key = l.key, .path = try artifact.resolvePath(arena, dir, cache_dir, l.path) };
    for (layers) |l| cache.touch(io, l.path);
    const base = try artifact.resolvePath(arena, dir, cache_dir, art.base.path);
    cache.touch(io, base);

    if (built) |b| return .{ .dir = dir, .name = b.name, .art = art, .base = base, .layers = layers, .cfg = b.cfg };

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
