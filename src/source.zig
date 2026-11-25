//! Sources (design/prototype.md, "Sources"): directories, git, and
//! tarballs, their fetch, and their content hash.
//!
//! A SOURCE argument is parsed into a `Spec`, and `resolve` turns it into a
//! `types.Source` with a tree on the host and a content hash:
//!
//! - A directory is used in place and hashed by its files. The hash of
//!   each file is kept in `$cache/sources/dirs/KEY` with its size and
//!   mtime, so the next build rehashes only the files that changed.
//! - Git (`https://…`, `git@…`, `github.com/OWNER/REPO`, `gh:OWNER/REPO`,
//!   each with `@REF` and `//SUBDIR`) is fetched in a machine on the
//!   builder root, with network to the source's host only, into a bare
//!   repository in `$cache/sources/git/KEY`, and the commit is written out
//!   once into `$cache/sources/tree/COMMIT`. A ref that's a full commit
//!   whose tree is already there fetches nothing.
//! - A tarball (`https://….tar.gz`, `.tgz`, or `.tar`) is downloaded and
//!   unpacked in a machine, and its tree kept in
//!   `$cache/sources/tree/SHA256`, by the download's digest. An archive
//!   that holds one directory, as GitHub's do, is that directory.
//!
//! The fetch machine's policy is `fetchPolicy`'s. Until policy.zig compiles
//! policies (W1), `fetchOptions` turns it into machine options itself.

const std = @import("std");
const h9 = @import("h9");
const types = @import("types.zig");
const cli = @import("cli.zig");
const cache = @import("cache.zig");
const machine = @import("machine.zig");
const policy = @import("policy.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Hex = [Sha256.digest_length * 2]u8;

// ---------------------------------------------------------------- parsing

/// A SOURCE argument, parsed.
pub const Spec = union(enum) {
    dir: []const u8,
    git: Git,
    tarball: Tarball,
};

pub const Git = struct {
    /// What git fetches: an `https://` URL. `gh:`, `github.com/`, and
    /// `git@HOST:PATH` are fetched over HTTPS, since the fetch machine has
    /// no keys.
    url: []const u8,
    /// The host the fetch machine may reach, and its port.
    host: []const u8,
    port: u16 = 443,
    /// A branch, tag, or full commit; null is the remote's HEAD.
    ref: ?[]const u8 = null,
    subdir: ?[]const u8 = null,
    /// The repository's name, or the subdirectory's if there is one.
    name: []const u8,
};

pub const Tarball = struct {
    url: []const u8,
    host: []const u8,
    port: u16 = 443,
    subdir: ?[]const u8 = null,
    /// The file's name without its extension, or the subdirectory's.
    name: []const u8,
    gzip: bool,
};

pub const ParseError = error{ BadSource, OutOfMemory };

/// Why the last `parse` failed.
pub var why: []const u8 = "";

/// Parses a SOURCE. Anything that isn't a URL form is a directory;
/// `resolve` prefers an existing directory over `github.com/OWNER/REPO`.
pub fn parse(arena: std.mem.Allocator, spec: []const u8) ParseError!Spec {
    why = "";
    if (spec.len == 0) return bad(arena, "an empty SOURCE", .{});
    for (spec) |c| if (c <= ' ' or c == 0x7f) return bad(arena, "{s}: has a space or control character", .{spec});

    if (std.mem.startsWith(u8, spec, "gh:")) return parseGitHub(arena, spec, spec["gh:".len..]);
    if (std.mem.startsWith(u8, spec, "github.com/")) return parseGitHub(arena, spec, spec["github.com/".len..]);
    if (std.mem.startsWith(u8, spec, "http://")) return bad(arena, "{s}: only https:// sources are fetched", .{spec});
    if (std.mem.startsWith(u8, spec, "https://")) return parseHttps(arena, spec);
    if (std.mem.startsWith(u8, spec, "git@")) return parseScp(arena, spec);
    return .{ .dir = spec };
}

fn bad(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ParseError {
    why = std.fmt.allocPrint(arena, fmt, args) catch "out of memory";
    return error.BadSource;
}

/// `REST//SUBDIR`, where `from` is where to start looking for `//`.
fn splitSubdir(arena: std.mem.Allocator, spec: []const u8, s: []const u8, from: usize) ParseError!struct { []const u8, ?[]const u8 } {
    const i = std.mem.indexOfPos(u8, s, from, "//") orelse return .{ s, null };
    const sub = std.mem.trim(u8, s[i + 2 ..], "/");
    if (sub.len == 0) return bad(arena, "{s}: an empty //SUBDIR", .{spec});
    var it = std.mem.splitScalar(u8, sub, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, ".."))
            return bad(arena, "{s}: //SUBDIR must be a plain relative path", .{spec});
    }
    return .{ s[0..i], sub };
}

/// `PATH@REF`, with the ref checked: it's passed to git as an argument.
fn splitRef(arena: std.mem.Allocator, spec: []const u8, s: []const u8, from: usize) ParseError!struct { []const u8, ?[]const u8 } {
    const i = std.mem.indexOfScalarPos(u8, s, from, '@') orelse return .{ s, null };
    const ref = s[i + 1 ..];
    if (ref.len == 0 or ref[0] == '-' or std.mem.indexOf(u8, ref, "..") != null or
        std.mem.indexOfAny(u8, ref, ":@\\^~?*[") != null)
        return bad(arena, "{s}: @{s} isn't a branch, tag, or commit", .{ spec, ref });
    return .{ s[0..i], ref };
}

fn parseGitHub(arena: std.mem.Allocator, spec: []const u8, rest: []const u8) ParseError!Spec {
    const no_sub, const subdir = try splitSubdir(arena, spec, rest, 0);
    const repo, const ref = try splitRef(arena, spec, no_sub, 0);
    var it = std.mem.splitScalar(u8, repo, '/');
    const owner = it.next() orelse "";
    var name = it.next() orelse "";
    if (owner.len == 0 or name.len == 0 or it.next() != null) return bad(arena, "{s}: want OWNER/REPO", .{spec});
    if (std.mem.endsWith(u8, name, ".git")) name = name[0 .. name.len - 4];
    if (name.len == 0) return bad(arena, "{s}: want OWNER/REPO", .{spec});
    return .{ .git = .{
        .url = try std.fmt.allocPrint(arena, "https://github.com/{s}/{s}.git", .{ owner, name }),
        .host = "github.com",
        .ref = ref,
        .subdir = subdir,
        .name = if (subdir) |s| std.fs.path.basenamePosix(s) else name,
    } };
}

/// `git@HOST:PATH[@REF][//SUBDIR]`, fetched as `https://HOST/PATH`.
fn parseScp(arena: std.mem.Allocator, spec: []const u8) ParseError!Spec {
    const rest = spec["git@".len..];
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return bad(arena, "{s}: want git@HOST:PATH", .{spec});
    const host = rest[0..colon];
    if (host.len == 0) return bad(arena, "{s}: want git@HOST:PATH", .{spec});
    const no_sub, const subdir = try splitSubdir(arena, spec, rest[colon + 1 ..], 0);
    const p, const ref = try splitRef(arena, spec, no_sub, 0);
    const repo_path = std.mem.trim(u8, p, "/");
    if (repo_path.len == 0) return bad(arena, "{s}: want git@HOST:PATH", .{spec});
    return .{ .git = .{
        .url = try std.fmt.allocPrint(arena, "https://{s}/{s}", .{ host, repo_path }),
        .host = host,
        .ref = ref,
        .subdir = subdir,
        .name = if (subdir) |s| std.fs.path.basenamePosix(s) else repoName(repo_path),
    } };
}

fn parseHttps(arena: std.mem.Allocator, spec: []const u8) ParseError!Spec {
    const scheme = "https://";
    const no_sub, const subdir = try splitSubdir(arena, spec, spec, scheme.len);
    const after = no_sub[scheme.len..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
    const authority = after[0..slash];
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return bad(arena, "{s}: credentials don't go in the URL", .{spec});
    const host, const port = hostPort(authority) orelse return bad(arena, "{s}: no host", .{spec});
    const url_path_full = after[slash..];
    const query = std.mem.indexOfAny(u8, url_path_full, "?#") orelse url_path_full.len;
    const url_path = url_path_full[0..query];

    inline for (.{ .{ ".tar.gz", true }, .{ ".tgz", true }, .{ ".tar", false } }) |ext| {
        if (std.mem.endsWith(u8, url_path, ext[0])) {
            const base = std.fs.path.basenamePosix(url_path);
            const stem = base[0 .. base.len - ext[0].len];
            if (stem.len == 0) return bad(arena, "{s}: no file name", .{spec});
            return .{ .tarball = .{
                .url = no_sub,
                .host = host,
                .port = port,
                .subdir = subdir,
                .name = if (subdir) |s| std.fs.path.basenamePosix(s) else stem,
                .gzip = ext[1],
            } };
        }
    }
    const path_start = scheme.len + slash;
    const url, const ref = try splitRef(arena, spec, no_sub, path_start);
    const repo_path = std.mem.trim(u8, url[path_start..], "/");
    if (repo_path.len == 0) return bad(arena, "{s}: no repository path", .{spec});
    return .{ .git = .{
        .url = url,
        .host = host,
        .port = port,
        .ref = ref,
        .subdir = subdir,
        .name = if (subdir) |s| std.fs.path.basenamePosix(s) else repoName(repo_path),
    } };
}

fn hostPort(authority: []const u8) ?struct { []const u8, u16 } {
    if (authority.len == 0) return null;
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return .{ authority, 443 };
    const port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return null;
    if (colon == 0) return null;
    return .{ authority[0..colon], port };
}

fn repoName(p: []const u8) []const u8 {
    const base = std.fs.path.basenamePosix(p);
    return if (std.mem.endsWith(u8, base, ".git") and base.len > 4) base[0 .. base.len - 4] else base;
}

// ---------------------------------------------------------------- directories

/// A file's line in a directory's index: what its hash was computed from.
const Known = struct { size: u64, mtime: i96, hash: Hex };

/// The hash of a directory's files, as hex: SHA-256 over a line per file,
/// in byte order of their paths, of the file's SHA-256 and path, or for a
/// symlink, its target. Empty directories don't count, and nor do paths
/// in `exclude` (relative, as `a/b`).
///
/// With `index_path`, each file's hash is kept there with its size and
/// mtime, and a file whose size and mtime match is not read again. A file
/// changed in the last two seconds is kept without its mtime, so a change
/// within the filesystem's mtime granularity is never missed.
pub fn hashDir(
    gpa: std.mem.Allocator,
    io: Io,
    root: []const u8,
    index_path: ?[]const u8,
    exclude: []const []const u8,
) !Hex {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = Dir.cwd();

    var known: std.StringHashMapUnmanaged(Known) = .empty;
    if (index_path) |ip| if (cwd.readFileAlloc(io, ip, arena, .limited(256 << 20))) |text| {
        try readIndex(arena, text, &known);
    } else |_| {};

    var d = try cwd.openDir(io, root, .{ .iterate = true });
    defer d.close(io);
    var w = try d.walkSelectively(arena);
    defer w.deinit();

    const Item = struct { rel: []const u8, line: []const u8, known: ?Known };
    var items: std.ArrayList(Item) = .empty;
    const now = Io.Timestamp.now(io, .real).nanoseconds;
    var buf: [64 << 10]u8 = undefined;

    while (try w.next(io)) |e| {
        const rel = try arena.dupe(u8, e.path);
        if (excluded(rel, exclude)) continue;
        switch (e.kind) {
            .directory => try w.enter(io, e),
            .sym_link => {
                const n = try e.dir.readLink(io, e.basename, &buf);
                try items.append(arena, .{ .rel = rel, .line = try std.fmt.allocPrint(arena, "l {s} {s}\n", .{ buf[0..n], rel }), .known = null });
            },
            .file => {
                const st = try e.dir.statFile(io, e.basename, .{ .follow_symlinks = false });
                const mtime = st.mtime.nanoseconds;
                const hash: Hex = blk: {
                    if (known.get(rel)) |k| if (k.size == st.size and k.mtime == mtime and mtime != 0) break :blk k.hash;
                    break :blk try hashFile(io, e.dir, e.basename, &buf);
                };
                const recent = now - mtime < 2 * std.time.ns_per_s;
                try items.append(arena, .{
                    .rel = rel,
                    .line = try std.fmt.allocPrint(arena, "f {s} {s}\n", .{ &hash, rel }),
                    .known = .{ .size = st.size, .mtime = if (recent) 0 else mtime, .hash = hash },
                });
            },
            // Sockets, fifos, and devices have no content to build from.
            else => {},
        }
    }
    std.mem.sortUnstable(Item, items.items, {}, struct {
        fn lt(_: void, a: Item, b: Item) bool {
            return std.mem.order(u8, a.rel, b.rel) == .lt;
        }
    }.lt);

    var h = Sha256.init(.{});
    var index: std.ArrayList(u8) = .empty;
    for (items.items) |it| {
        h.update(it.line);
        if (it.known) |k| {
            if (std.mem.indexOfScalar(u8, it.rel, '\n') != null) continue;
            try index.print(arena, "{d} {d} {s} {s}\n", .{ k.size, k.mtime, &k.hash, it.rel });
        }
    }
    if (index_path) |ip| {
        if (std.fs.path.dirname(ip)) |parent| cwd.createDirPath(io, parent) catch {};
        cwd.writeFile(io, .{ .sub_path = ip, .data = index.items }) catch {};
    }
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}

fn excluded(rel: []const u8, exclude: []const []const u8) bool {
    for (exclude) |x| {
        if (std.mem.eql(u8, rel, x)) return true;
        if (std.mem.startsWith(u8, rel, x) and rel.len > x.len and rel[x.len] == '/') return true;
    }
    return false;
}

fn readIndex(arena: std.mem.Allocator, text: []const u8, known: *std.StringHashMapUnmanaged(Known)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        var f = std.mem.splitScalar(u8, l, ' ');
        const size = std.fmt.parseInt(u64, f.next() orelse continue, 10) catch continue;
        const mtime = std.fmt.parseInt(i96, f.next() orelse continue, 10) catch continue;
        const hash = f.next() orelse continue;
        const rel = f.rest();
        if (hash.len != @sizeOf(Hex) or rel.len == 0) continue;
        try known.put(arena, rel, .{ .size = size, .mtime = mtime, .hash = hash[0..@sizeOf(Hex)].* });
    }
}

fn hashFile(io: Io, d: Dir, name: []const u8, buf: []u8) !Hex {
    var f = try d.openFile(io, name, .{});
    defer f.close(io);
    var r = f.reader(io, &.{});
    var h = Sha256.init(.{});
    while (true) {
        const n = try r.interface.readSliceShort(buf);
        h.update(buf[0..n]);
        if (n < buf.len) break;
    }
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}

/// SHA-256 of a string, as hex, cut to `n` characters: cache keys.
fn key(s: []const u8, comptime n: usize) [n]u8 {
    var d: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(s, &d, .{});
    const hex = std.fmt.bytesToHex(d, .lower);
    return hex[0..n].*;
}

// ---------------------------------------------------------------- fetching

/// Makes or finds the builder root and returns its path. roots.zig's, given
/// by whoever resolves a source, so a directory source never makes one.
pub const BuilderFn = *const fn (ctx: *cli.Context) anyerror![]const u8;

pub const Options = struct {
    /// The builder root, for a remote source. Without it, a remote source
    /// is error.NoBuilderRoot.
    builder: ?BuilderFn = null,
    /// Paths a directory source's hash leaves out: the output directory,
    /// when it's inside the source. Absolute, or relative to the cwd.
    exclude: []const []const u8 = &.{},
};

pub const ResolveError = error{
    /// Not a source; `why` says why. Exit 2.
    BadSource,
    /// The directory or the //SUBDIR isn't there.
    SourceNotFound,
    /// A remote source with no `Options.builder`.
    NoBuilderRoot,
    /// The fetch machine failed; its output was emitted. Exit 125.
    FetchFailed,
};

/// The source SPEC names: a directory, hashed, or a remote source,
/// fetched into the cache if it isn't there already. Each cache entry it
/// uses is touched.
pub fn resolve(ctx: *cli.Context, spec: []const u8, opts: Options) !types.Source {
    const cache_dir = try cache.dir(ctx.arena, ctx.env);
    const parsed = blk: {
        // `github.com/OWNER/REPO` might be a directory of that name.
        if (std.mem.startsWith(u8, spec, "github.com/") and isDir(ctx.io, spec)) break :blk Spec{ .dir = spec };
        break :blk parse(ctx.arena, spec) catch |e| switch (e) {
            error.BadSource => {
                ctx.events.log("{s}", .{why});
                return error.BadSource;
            },
            else => |x| return x,
        };
    };
    return switch (parsed) {
        .dir => |d| resolveDir(ctx, spec, d, cache_dir, opts),
        .git => |g| resolveGit(ctx, spec, g, cache_dir, opts),
        .tarball => |t| resolveTarball(ctx, spec, t, cache_dir, opts),
    };
}

fn isDir(io: Io, p: []const u8) bool {
    const st = Dir.cwd().statFile(io, p, .{}) catch return false;
    return st.kind == .directory;
}

fn resolveDir(ctx: *cli.Context, spec: []const u8, d: []const u8, cache_dir: []const u8, opts: Options) !types.Source {
    const arena = ctx.arena;
    const cwd = Dir.cwd();
    const abs = cwd.realPathFileAlloc(ctx.io, d, arena) catch {
        ctx.events.log("{s}: no such directory", .{d});
        return error.SourceNotFound;
    };
    if (!isDir(ctx.io, abs)) {
        ctx.events.log("{s}: not a directory", .{d});
        return error.SourceNotFound;
    }
    var exclude: std.ArrayList([]const u8) = .empty;
    for (opts.exclude) |x| {
        const xa = cwd.realPathFileAlloc(ctx.io, x, arena) catch continue;
        if (std.mem.startsWith(u8, xa, abs) and xa.len > abs.len + 1 and xa[abs.len] == '/')
            try exclude.append(arena, xa[abs.len + 1 ..]);
    }
    const index_path = try cache.path(arena, cache_dir, .sources, try std.fmt.allocPrint(arena, "dirs/{s}", .{&key(abs, 32)}));
    const hash = try hashDir(ctx.gpa, ctx.io, abs, index_path, exclude.items);
    return .{
        .kind = .dir,
        .spec = spec,
        .path = abs,
        .name = std.fs.path.basename(abs),
        .hash = try arena.dupe(u8, &hash),
    };
}

fn isCommit(ref: []const u8) bool {
    if (ref.len != 40) return false;
    for (ref) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return false;
    return true;
}

/// The guest script that fetches a git source: URL and REF ("" for HEAD)
/// as arguments, the bare repository and its output in /h9x/src.
pub const git_sh =
    \\#!/bin/sh
    \\set -eu
    \\url=$1 ref=${2:-HEAD}
    \\cd /h9x/src
    \\export HOME=/h9x/src/home GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1
    \\mkdir -p home
    \\rm -rf out
    \\mkdir -p out/tree
    \\[ -d repo.git ] || git init -q --bare repo.git
    \\export GIT_DIR=/h9x/src/repo.git GIT_INDEX_FILE=/h9x/src/index
    \\git fetch -q --depth 1 --no-tags --force "$url" "$ref"
    \\git rev-parse --verify 'FETCH_HEAD^{commit}' >out/commit
    \\git -c core.bare=false --work-tree=out/tree checkout -q -f "$(cat out/commit)" -- .
    \\rm -f index
    \\
;

/// The guest script that fetches a tarball: URL and `gz` or `tar` as
/// arguments, the download and its tree in /h9x/src/out.
pub const tarball_sh =
    \\#!/bin/sh
    \\set -eu
    \\url=$1
    \\cd /h9x/src
    \\export HOME=/h9x/src/home
    \\mkdir -p home
    \\rm -rf out
    \\mkdir -p out/tree
    \\curl -fsSL --proto =https --proto-redir =https -o out/src "$url"
    \\if [ "$2" = gz ]; then tar -xzf out/src -C out/tree; else tar -xf out/src -C out/tree; fi
    \\
;

fn resolveGit(ctx: *cli.Context, spec: []const u8, g: Git, cache_dir: []const u8, opts: Options) !types.Source {
    const arena = ctx.arena;
    const io = ctx.io;
    const cwd = Dir.cwd();
    const tree_dir = try cache.path(arena, cache_dir, .sources, "tree");
    const repo_key = key(g.url, 32);
    const work = try cache.path(arena, cache_dir, .sources, try std.fmt.allocPrint(arena, "git/{s}", .{&repo_key}));

    // A full commit whose tree is kept needs no fetch.
    var commit: []const u8 = "";
    if (g.ref) |r| if (isCommit(r) and isDir(io, try std.fs.path.join(arena, &.{ tree_dir, r }))) {
        commit = r;
        ctx.events.emit(.{ .fetch = .{ .url = spec, .state = .cached } });
    };
    if (commit.len == 0) {
        ctx.events.emit(.{ .fetch = .{ .url = spec, .state = .start } });
        try cwd.createDirPath(io, work);
        try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ work, "fetch.sh" }), .data = git_sh });
        try runFetch(ctx, opts, work, .{ .host = g.host, .port = g.port }, &.{ "/bin/sh", "/h9x/src/fetch.sh", g.url, g.ref orelse "" });
        const out = try std.fs.path.join(arena, &.{ work, "out" });
        const commit_file = try std.fs.path.join(arena, &.{ out, "commit" });
        const text = cwd.readFileAlloc(io, commit_file, arena, .limited(256)) catch return error.FetchFailed;
        commit = std.mem.trim(u8, text, " \t\r\n");
        if (!isCommit(commit)) return error.FetchFailed;
        try keepTree(io, arena, try std.fs.path.join(arena, &.{ out, "tree" }), tree_dir, commit, false);
        cache.removeTree(io, out) catch {};
        ctx.events.emit(.{ .fetch = .{ .url = spec, .state = .done } });
    }
    cache.touch(io, work);
    return finish(ctx, spec, .git, tree_dir, commit, g.subdir, g.name);
}

fn resolveTarball(ctx: *cli.Context, spec: []const u8, t: Tarball, cache_dir: []const u8, opts: Options) !types.Source {
    const arena = ctx.arena;
    const io = ctx.io;
    const cwd = Dir.cwd();
    const tree_dir = try cache.path(arena, cache_dir, .sources, "tree");
    const work = try cache.path(arena, cache_dir, .sources, try std.fmt.allocPrint(arena, "tmp/{s}", .{&key(t.url, 32)}));
    defer cache.removeTree(io, work) catch {};

    ctx.events.emit(.{ .fetch = .{ .url = spec, .state = .start } });
    try cwd.createDirPath(io, work);
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ work, "fetch.sh" }), .data = tarball_sh });
    try runFetch(ctx, opts, work, .{ .host = t.host, .port = t.port }, &.{ "/bin/sh", "/h9x/src/fetch.sh", t.url, if (t.gzip) "gz" else "tar" });

    const out = try std.fs.path.join(arena, &.{ work, "out" });
    const download = try std.fs.path.join(arena, &.{ out, "src" });
    var buf: [64 << 10]u8 = undefined;
    const digest = hashFile(io, cwd, download, &buf) catch return error.FetchFailed;
    const st = cwd.statFile(io, download, .{}) catch return error.FetchFailed;
    try keepTree(io, arena, try std.fs.path.join(arena, &.{ out, "tree" }), tree_dir, &digest, true);
    ctx.events.emit(.{ .fetch = .{ .url = spec, .state = .done, .bytes = st.size } });
    return finish(ctx, spec, .tarball, tree_dir, try arena.dupe(u8, &digest), t.subdir, t.name);
}

/// Moves a fetched tree to `TREE_DIR/NAME`, unless it's there already; a
/// tree is never written twice. With `strip`, a tree of one directory is
/// that directory.
fn keepTree(io: Io, arena: std.mem.Allocator, fetched: []const u8, tree_dir: []const u8, name: []const u8, strip: bool) !void {
    const cwd = Dir.cwd();
    const dst = try std.fs.path.join(arena, &.{ tree_dir, name });
    if (isDir(io, dst)) return;
    try cwd.createDirPath(io, tree_dir);
    var src = fetched;
    if (strip) if (try onlyDir(io, arena, fetched)) |only| {
        src = only;
    };
    cwd.rename(src, cwd, dst, io) catch |e| {
        // Another h9x kept the same tree first.
        if (isDir(io, dst)) return;
        return e;
    };
}

/// The one directory `p` holds, if that's all it holds.
fn onlyDir(io: Io, arena: std.mem.Allocator, p: []const u8) !?[]const u8 {
    var d = try Dir.cwd().openDir(io, p, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    const first = (try it.next(io)) orelse return null;
    if (first.kind != .directory) return null;
    const name = try arena.dupe(u8, first.name);
    if (try it.next(io) != null) return null;
    return try std.fs.path.join(arena, &.{ p, name });
}

fn finish(
    ctx: *cli.Context,
    spec: []const u8,
    kind: types.Source.Kind,
    tree_dir: []const u8,
    hash: []const u8,
    subdir: ?[]const u8,
    name: []const u8,
) !types.Source {
    const arena = ctx.arena;
    const tree = try std.fs.path.join(arena, &.{ tree_dir, hash });
    cache.touch(ctx.io, tree);
    var p = tree;
    var h = hash;
    if (subdir) |s| {
        p = try std.fs.path.join(arena, &.{ tree, s });
        if (!isDir(ctx.io, p)) {
            ctx.events.log("{s}: no directory {s} in it", .{ spec, s });
            return error.SourceNotFound;
        }
        // Two subdirectories of one commit are two sources.
        const k = key(try std.fmt.allocPrint(arena, "{s}//{s}", .{ hash, s }), 64);
        h = try arena.dupe(u8, &k);
    }
    return .{ .kind = kind, .spec = spec, .path = p, .name = name, .hash = h };
}

pub const Endpoint = struct { host: []const u8, port: u16 };

/// Hosts a source's host redirects to for its downloads.
const redirects = [_]struct { []const u8, []const []const u8 }{
    .{ "github.com", &.{ "codeload.github.com", "objects.githubusercontent.com" } },
    .{ "gitlab.com", &.{} },
};

/// The `netallow` patterns for fetching from `ep`: its host and port, the
/// hosts it's known to redirect to, and the HTTPS proxy, if there is one.
pub fn netAllow(arena: std.mem.Allocator, ep: Endpoint, https_proxy: ?[]const u8) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(arena, try std.fmt.allocPrint(arena, "tcp!{s}!{d}", .{ ep.host, ep.port }));
    for (redirects) |r| if (std.ascii.eqlIgnoreCase(r[0], ep.host)) for (r[1]) |h|
        try out.append(arena, try std.fmt.allocPrint(arena, "tcp!{s}!443", .{h}));
    if (https_proxy) |p| if (proxyEndpoint(p)) |pe|
        try out.append(arena, try std.fmt.allocPrint(arena, "tcp!{s}!{d}", .{ pe.host, pe.port }));
    return out.items;
}

/// `http://[user@]host:port[/]` as a host and port.
fn proxyEndpoint(p: []const u8) ?Endpoint {
    var s = p;
    if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
    if (std.mem.lastIndexOfScalar(u8, s, '@')) |i| s = s[i + 1 ..];
    if (std.mem.indexOfScalar(u8, s, '/')) |i| s = s[0..i];
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return if (s.len > 0) .{ .host = s, .port = 80 } else null;
    const port = std.fmt.parseInt(u16, s[colon + 1 ..], 10) catch return null;
    return .{ .host = s[0..colon], .port = port };
}

/// The fetch machine's policy: the builder root read-only, the work
/// directory writable at /h9x/src, and network to the source's host only
/// (or any host, while `policy.open_builds` is set).
pub fn fetchPolicy(arena: std.mem.Allocator, builder: []const u8, work: []const u8, ep: Endpoint, https_proxy: ?[]const u8) error{OutOfMemory}!types.Policy {
    const mounts = try arena.dupe(types.Mount, &.{
        .{ .kind = .dir, .src = builder, .dst = "#L", .access = .ro },
        .{ .kind = .dir, .src = work, .dst = "#L/h9x/src", .access = .rw },
    });
    return .{
        .phase = .fetch,
        .trust = .untrusted,
        .mounts = mounts,
        .net = .outbound,
        .netallow = if (policy.open_builds) &.{} else try netAllow(arena, ep, https_proxy),
        .write = .overlay,
        .memory = 1 << 30,
        .timeout_ns = 10 * std.time.ns_per_min,
        .env = try arena.dupe(types.EnvVar, &.{
            .{ .name = "PATH", .value = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" },
            .{ .name = "HOME", .value = "/h9x/src/home" },
        }),
        .cwd = "/h9x/src",
    };
}

/// `p` as machine options. policy.zig's `compile` replaces this once it
/// does the same.
pub fn fetchOptions(arena: std.mem.Allocator, p: types.Policy, stdio: machine.Stdio) error{OutOfMemory}!machine.Options {
    var mounts: std.ArrayList(h9.Machine.Mount) = .empty;
    for (p.mounts) |m| try mounts.append(arena, .{
        .kind = if (m.kind == .dir) .dir else .tmp,
        .src = m.src,
        .dst = m.dst,
        .access = switch (m.access) {
            .ro => .ro,
            .rw => .rw,
            .up => .up,
        },
    });
    var env: std.ArrayList(h9.EnvVar) = .empty;
    for (p.env) |e| try env.append(arena, .{ .name = e.name, .value = e.value });
    return .{
        .mounts = mounts.items,
        .env = env.items,
        .console_tty = false,
        .guest_tools = false,
        .policy = .{
            .write = switch (p.write orelse .overlay) {
                .ro => .none,
                .overlay => .overlay,
                .rw => .scope,
            },
            .net = switch (p.net) {
                .disable => .disable,
                .outbound => .outbound,
                .enable => .enable,
            },
            .net_allow = p.netallow,
            .memory = p.memory,
            .timeout_ns = p.timeout_ns,
            .pids = p.pids,
        },
        .stdio = stdio,
    };
}

/// Runs a fetch script in a machine on the builder root. Its output is
/// kept, and emitted only if it fails.
fn runFetch(ctx: *cli.Context, opts: Options, work: []const u8, ep: Endpoint, argv: []const []const u8) !void {
    const arena = ctx.arena;
    const get = opts.builder orelse {
        ctx.events.log("{s}: fetching a remote source needs the builder root", .{argv[2]});
        return error.NoBuilderRoot;
    };
    const builder = try get(ctx);
    const cache_dir = try cache.dir(arena, ctx.env);
    const host = machine.Host.init(arena, ctx.io, ctx.env, cache_dir) catch |e| {
        ctx.events.log("fetch: {t}", .{e});
        return error.FetchFailed;
    };
    const pol = try fetchPolicy(arena, builder, work, ep, host.https_proxy);
    var outw: Io.Writer.Allocating = .init(arena);
    var in: Io.Reader = .fixed("");
    const o = try fetchOptions(arena, pol, .{ .in = &in, .out = &outw.writer, .err = &outw.writer });
    var why_run: []const u8 = "";
    const status = machine.run(ctx.gpa, arena, ctx.io, host, o, argv, &why_run) catch |e| {
        ctx.events.log("fetch {s}: {s}", .{ argv[2], if (why_run.len > 0) why_run else @errorName(e) });
        return error.FetchFailed;
    };
    const code = machine.exitCode(status);
    if (code != 0) {
        if (outw.written().len > 0) ctx.events.emit(.{ .output = .{ .stream = .stderr, .text = outw.written() } });
        ctx.events.log("fetch {s}: exit {d}", .{ argv[2], code });
        return error.FetchFailed;
    }
}

// ---------------------------------------------------------------- tests

test "parse: directories" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    try std.testing.expectEqualStrings(".", (try parse(ar, ".")).dir);
    try std.testing.expectEqualStrings("./app", (try parse(ar, "./app")).dir);
    try std.testing.expectEqualStrings("/srv/my@app", (try parse(ar, "/srv/my@app")).dir);
}

test "parse: gh: and github.com/" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const g = (try parse(ar, "gh:railwayapp/railpack@v0.43.0//examples/node-npm")).git;
    try std.testing.expectEqualStrings("https://github.com/railwayapp/railpack.git", g.url);
    try std.testing.expectEqualStrings("github.com", g.host);
    try std.testing.expectEqualStrings("v0.43.0", g.ref.?);
    try std.testing.expectEqualStrings("examples/node-npm", g.subdir.?);
    try std.testing.expectEqualStrings("node-npm", g.name);

    const h = (try parse(ar, "github.com/me/app.git")).git;
    try std.testing.expectEqualStrings("https://github.com/me/app.git", h.url);
    try std.testing.expectEqualStrings("app", h.name);
    try std.testing.expect(h.ref == null and h.subdir == null);

    const b = (try parse(ar, "gh:me/app@feature/x")).git;
    try std.testing.expectEqualStrings("feature/x", b.ref.?);
}

test "parse: https git and git@" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const g = (try parse(ar, "https://git.example.com:8443/team/app.git@main//web")).git;
    try std.testing.expectEqualStrings("https://git.example.com:8443/team/app.git", g.url);
    try std.testing.expectEqualStrings("git.example.com", g.host);
    try std.testing.expectEqual(@as(u16, 8443), g.port);
    try std.testing.expectEqualStrings("main", g.ref.?);
    try std.testing.expectEqualStrings("web", g.subdir.?);

    const s = (try parse(ar, "git@github.com:me/app.git@0123456789abcdef0123456789abcdef01234567")).git;
    try std.testing.expectEqualStrings("https://github.com/me/app.git", s.url);
    try std.testing.expectEqualStrings("app", s.name);
    try std.testing.expect(isCommit(s.ref.?));
}

test "parse: tarballs" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const t = (try parse(ar, "https://example.com/dl/app-1.2.tar.gz")).tarball;
    try std.testing.expectEqualStrings("https://example.com/dl/app-1.2.tar.gz", t.url);
    try std.testing.expectEqualStrings("app-1.2", t.name);
    try std.testing.expect(t.gzip);
    const u = (try parse(ar, "https://example.com/a.tar?token=1//srv")).tarball;
    try std.testing.expectEqualStrings("https://example.com/a.tar?token=1", u.url);
    try std.testing.expectEqualStrings("srv", u.name);
    try std.testing.expect(!u.gzip);
}

test "parse: errors" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    for ([_][]const u8{
        "http://example.com/a.tgz",
        "gh:me",
        "gh:me/app/extra",
        "gh:me/app@--upload-pack=x",
        "gh:me/app@a..b",
        "gh:me/app//../etc",
        "gh:me/app//",
        "https://user:pw@example.com/a.git",
        "https:///a.git",
        "git@github.com",
        "gh:me/app @x",
    }) |s| {
        try std.testing.expectError(error.BadSource, parse(ar, s));
        try std.testing.expect(why.len > 0);
    }
}

test netAllow {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const n = try netAllow(ar, .{ .host = "github.com", .port = 443 }, "http://user:pw@proxy.local:3128");
    try std.testing.expectEqual(@as(usize, 4), n.len);
    try std.testing.expectEqualStrings("tcp!github.com!443", n[0]);
    try std.testing.expectEqualStrings("tcp!codeload.github.com!443", n[1]);
    try std.testing.expectEqualStrings("tcp!proxy.local!3128", n[3]);
    const m = try netAllow(ar, .{ .host = "example.com", .port = 8443 }, null);
    try std.testing.expectEqual(@as(usize, 1), m.len);
}

test "fetchPolicy compiles to machine options" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const p = try fetchPolicy(ar, "/c/roots/builder-1", "/c/sources/git/k", .{ .host = "github.com", .port = 443 }, null);
    var buf: [16]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const o = try fetchOptions(ar, p, .{ .out = &w, .err = &w });
    try std.testing.expectEqualStrings("#L/h9x/src", o.mounts[1].dst);
    try std.testing.expect(o.mounts[1].access.? == .rw);
    try std.testing.expectEqual(h9.policy.NetMode.outbound, o.policy.net.?);
    if (policy.open_builds)
        try std.testing.expectEqual(@as(usize, 0), o.policy.net_allow.len)
    else
        try std.testing.expectEqualStrings("tcp!github.com!443", o.policy.net_allow[0]);
}

test hashDir {
    const io = std.testing.io;
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", ar);
    try tmp.dir.createDirPath(io, "app/src");
    try tmp.dir.createDirPath(io, "app/app.h9/layers");
    try tmp.dir.writeFile(io, .{ .sub_path = "app/package.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "app/src/index.js", .data = "console.log(1)" });
    try tmp.dir.writeFile(io, .{ .sub_path = "app/app.h9/layers/x", .data = "out" });
    try tmp.dir.symLink(io, "src/index.js", "app/main.js", .{});
    const app = try std.fs.path.join(ar, &.{ root, "app" });
    const index = try std.fs.path.join(ar, &.{ root, "index" });

    const h1 = try hashDir(std.testing.allocator, io, app, index, &.{"app.h9"});
    // The output directory is left out, and the index doesn't change it.
    try tmp.dir.writeFile(io, .{ .sub_path = "app/app.h9/layers/x", .data = "changed" });
    const h2 = try hashDir(std.testing.allocator, io, app, index, &.{"app.h9"});
    try std.testing.expectEqualStrings(&h1, &h2);
    try std.testing.expectEqualStrings(&h1, &(try hashDir(std.testing.allocator, io, app, null, &.{"app.h9"})));

    // The index names each file with its hash.
    const text = try tmp.dir.readFileAlloc(io, "index", ar, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, text, " src/index.js\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "app.h9") == null);

    // A changed file changes the hash, even with the same size, once its
    // mtime has moved.
    try tmp.dir.writeFile(io, .{ .sub_path = "app/src/index.js", .data = "console.log(2)" });
    const h3 = try hashDir(std.testing.allocator, io, app, index, &.{"app.h9"});
    try std.testing.expect(!std.mem.eql(u8, &h1, &h3));

    // A stale index entry with a matching size and mtime is believed: the
    // point of the index. Its mtime is set old, so it's kept.
    const old: Io.Timestamp = .{ .nanoseconds = 1_000_000 * std.time.ns_per_s };
    try tmp.dir.setTimestamps(io, "app/package.json", .{ .modify_timestamp = .{ .new = old } });
    const h4 = try hashDir(std.testing.allocator, io, app, index, &.{"app.h9"});
    var fake: std.ArrayList(u8) = .empty;
    try fake.print(ar, "2 {d} {s} package.json\n", .{ old.nanoseconds, repeat("f", 64) });
    try tmp.dir.writeFile(io, .{ .sub_path = "index", .data = fake.items });
    const h5 = try hashDir(std.testing.allocator, io, app, index, &.{"app.h9"});
    try std.testing.expect(!std.mem.eql(u8, &h4, &h5));
    // Without the index it's read again.
    try std.testing.expectEqualStrings(&h4, &(try hashDir(std.testing.allocator, io, app, null, &.{"app.h9"})));
}

test keepTree {
    const io = std.testing.io;
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", ar);
    try tmp.dir.createDirPath(io, "out/tree/app-1.0/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "out/tree/app-1.0/package.json", .data = "{}" });
    const trees = try std.fs.path.join(ar, &.{ root, "tree" });
    try keepTree(io, ar, try std.fs.path.join(ar, &.{ root, "out/tree" }), trees, "abc", true);
    try tmp.dir.access(io, "tree/abc/package.json", .{});
    // Kept once: a second fetch of the same digest leaves it alone.
    try tmp.dir.createDirPath(io, "out2/tree/other");
    try keepTree(io, ar, try std.fs.path.join(ar, &.{ root, "out2/tree" }), trees, "abc", true);
    try tmp.dir.access(io, "tree/abc/package.json", .{});
}

/// `s` `n` times, at comptime.
fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    comptime var out: [s.len * n]u8 = undefined;
    inline for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
    const final = out;
    return &final;
}
