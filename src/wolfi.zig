//! The Debian-to-Wolfi package table: the plan's apt packages as Wolfi
//! package names, or alternatives (`a|b|c`) for roots.sh to try.
//!
//! Owned by W2. A port of the POC's `wolfi` function: a name of h9x's own
//! for the common packages, else the Debian name, then guesses without its
//! version or its `lib` prefix (libfoo-dev is often foo-dev in Wolfi).
//! roots.sh installs the first alternative the repository has.

const std = @import("std");

/// The packages Wolfi names differently, by their Debian names.
const table = std.StaticStringMap([]const u8).initComptime(.{
    .{ "build-essential", "build-base" },
    .{ "pkg-config", "pkgconf" },
    .{ "libssl-dev", "openssl-dev" },
    .{ "zlib1g-dev", "zlib-dev" },
    .{ "zlib1g", "zlib" },
    .{ "libjemalloc2", "jemalloc" },
    .{ "libatomic1", "libatomic" },
    .{ "libyaml-0-2", "yaml" },
    .{ "libpq5", "libpq" },
    .{ "libpq-dev", "libpq-dev|postgresql-dev" },
    .{ "libsqlite3-dev", "sqlite-dev" },
    .{ "libsqlite3-0", "sqlite-libs" },
    .{ "libvips-dev", "vips-dev" },
    .{ "libvips42", "vips" },
    .{ "libvips", "vips" },
    .{ "libmagickwand-dev", "imagemagick-dev" },
    .{ "default-libmysqlclient-dev", "mariadb-connector-c-dev|mariadb-dev" },
});

/// The Wolfi package, or alternatives, for the Debian package `deb`.
pub fn name(arena: std.mem.Allocator, deb: []const u8) error{OutOfMemory}![]const u8 {
    if (table.get(deb)) |w| return w;
    if (std.mem.startsWith(u8, deb, "libncurses") and std.mem.endsWith(u8, deb, "-dev")) return "ncurses-dev";
    if (std.mem.endsWith(u8, deb, "-dev")) {
        const b = deb[0 .. deb.len - "-dev".len];
        const nolib = noLib(b);
        return std.fmt.allocPrint(arena, "{s}|{s}-dev|{s}-dev|{s}-dev", .{ deb, nolib, noVersion(b), noVersion(nolib) });
    }
    return std.fmt.allocPrint(arena, "{s}|{s}|{s}", .{ deb, noVersion(deb), noVersion(noLib(deb)) });
}

/// Each of `debs` as `name` gives it.
pub fn names(arena: std.mem.Allocator, debs: []const []const u8) error{OutOfMemory}![]const []const u8 {
    const out = try arena.alloc([]const u8, debs.len);
    for (debs, out) |d, *o| o.* = try name(arena, d);
    return out;
}

/// `${p#lib}`.
fn noLib(p: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, p, "lib")) p[3..] else p;
}

/// `sed 's/[0-9.-]*$//'`: the name without a trailing version.
fn noVersion(p: []const u8) []const u8 {
    return std.mem.trimEnd(u8, p, "0123456789.-");
}

test name {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    // What the POC's wolfi function prints for each.
    const cases = [_][2][]const u8{
        .{ "libatomic1", "libatomic" },
        .{ "libjemalloc2", "jemalloc" },
        .{ "build-essential", "build-base" },
        .{ "libvips42", "vips" },
        .{ "libncursesw5-dev", "ncurses-dev" },
        .{ "libyaml-dev", "libyaml-dev|yaml-dev|libyaml-dev|yaml-dev" },
        .{ "libicu-dev", "libicu-dev|icu-dev|libicu-dev|icu-dev" },
        .{ "libjemalloc-dev", "libjemalloc-dev|jemalloc-dev|libjemalloc-dev|jemalloc-dev" },
        .{ "libgdbm6-dev", "libgdbm6-dev|gdbm6-dev|libgdbm-dev|gdbm-dev" },
        .{ "python3.11-dev", "python3.11-dev|python3.11-dev|python-dev|python-dev" },
        .{ "libvips", "vips" },
        .{ "libgmp10", "libgmp10|libgmp|gmp" },
        .{ "ffmpeg", "ffmpeg|ffmpeg|ffmpeg" },
        .{ "libc6", "libc6|libc|c" },
        .{ "git", "git|git|git" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c[1], try name(a.allocator(), c[0]));
}
