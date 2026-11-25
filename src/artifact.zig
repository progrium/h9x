//! The output directory (design/prototype.md, "The output directory"): its
//! layout, `artifact.json`, and the `run` script, documented in
//! docs/output.md.
//!
//! Owned by W7. `read` came first, from W8, for pack and export on a
//! build's output.

const std = @import("std");
const types = @import("types.zig");

pub const json_file = "artifact.json";

pub const ReadError = error{ NoArtifact, BadArtifact, UnsupportedVersion, OutOfMemory } || std.Io.Dir.ReadFileAllocError;

/// Reads `OUT/artifact.json`, for pack, export, and run on a build's
/// output. Fields a later h9x adds are ignored. error.NoArtifact if there
/// is none.
pub fn read(arena: std.mem.Allocator, io: std.Io, out_dir: []const u8) ReadError!types.Artifact {
    const path = try std.fs.path.join(arena, &.{ out_dir, json_file });
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20)) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return error.NoArtifact,
        else => |x| return x,
    };
    return parse(arena, text);
}

/// artifact.json's text, parsed.
pub fn parse(arena: std.mem.Allocator, text: []const u8) error{ BadArtifact, UnsupportedVersion, OutOfMemory }!types.Artifact {
    const a = std.json.parseFromSliceLeaky(types.Artifact, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadArtifact,
    };
    if (a.version != types.Artifact.current_version) return error.UnsupportedVersion;
    return a;
}

/// A path in artifact.json as a host path: `$cache/...` under the cache,
/// a relative one under the output directory, and an absolute one as it
/// is.
pub fn resolvePath(arena: std.mem.Allocator, out_dir: []const u8, cache_dir: []const u8, p: []const u8) error{OutOfMemory}![]const u8 {
    const prefix = "$cache/";
    if (std.mem.startsWith(u8, p, prefix)) return std.fs.path.join(arena, &.{ cache_dir, p[prefix.len..] });
    if (std.fs.path.isAbsolute(p)) return p;
    return std.fs.path.join(arena, &.{ out_dir, p });
}

test parse {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const art = try parse(a.allocator(),
        \\{"version":1,"arch":"amd64","base":{"path":"$cache/roots/base-k","packages":["glibc"]},
        \\ "layers":[{"name":"runtime","key":"r","path":"$cache/runtimes/r"},{"name":"app","key":"a","path":"layers/app"}],
        \\ "env":["PATH=/bin"],"start":"node server.js","cwd":"/app","later":true}
    );
    try std.testing.expectEqual(types.LayerName.app, art.layers[1].name);
    try std.testing.expectEqualStrings("/c/runtimes/r", try resolvePath(a.allocator(), "/o", "/c", art.layers[0].path));
    try std.testing.expectEqualStrings("/o/layers/app", try resolvePath(a.allocator(), "/o", "/c", art.layers[1].path));
    try std.testing.expectError(error.UnsupportedVersion, parse(a.allocator(), "{\"version\":2,\"arch\":\"amd64\",\"base\":{\"path\":\"\",\"packages\":[]},\"layers\":[],\"env\":[],\"start\":null}"));
}
