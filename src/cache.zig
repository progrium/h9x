//! The cache (design/prototype.md, "Cache"): its layout, touching entries
//! on use, `cache ls`, and `cache prune`. Documented in docs/cache.md.
//!
//! Owned by W5. `dir` is the skeleton's, since every command needs it.

const std = @import("std");

/// The kinds of entry, each a directory under the cache.
pub const Kind = enum { bootstrap, dl, tools, roots, runtimes, sources, builds, runners, packs };

/// `$H9X_CACHE`, or `${XDG_CACHE_HOME:-~/.cache}/h9x`.
pub fn dir(arena: std.mem.Allocator, env: *const std.process.Environ.Map) error{ OutOfMemory, NoHome }![]const u8 {
    if (env.get("H9X_CACHE")) |c| if (c.len > 0) return c;
    if (env.get("XDG_CACHE_HOME")) |x| if (x.len > 0) return std.fs.path.join(arena, &.{ x, "h9x" });
    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse return error.NoHome;
    return std.fs.path.join(arena, &.{ home, ".cache", "h9x" });
}

test dir {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var env: std.process.Environ.Map = .init(a.allocator());
    try env.put("HOME", "/home/me");
    try std.testing.expectEqualStrings("/home/me/.cache/h9x", try dir(a.allocator(), &env));
    try env.put("H9X_CACHE", "/c");
    try std.testing.expectEqualStrings("/c", try dir(a.allocator(), &env));
}
