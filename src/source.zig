//! Sources (design/prototype.md, "Sources"): directories, git, and
//! tarballs, their fetch, and their content hash.
//!
//! Owned by W5. A directory is hashed by its files, rehashing only those
//! whose size or mtime changed since the last build. Git and tarball
//! sources are fetched in a machine on the builder root, with network to
//! the source's host only, into `$cache/sources/`.

const std = @import("std");
const types = @import("types.zig");
const cli = @import("cli.zig");

/// The source a SOURCE argument names, fetched if it's remote.
pub fn resolve(ctx: *cli.Context, spec: []const u8) !types.Source {
    _ = ctx;
    _ = spec;
    return error.NotImplemented;
}
