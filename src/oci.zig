//! OCI image layouts and `docker save` tarballs (design/prototype.md,
//! "Export"): the base root and each run layer as gzipped deterministic
//! tars, and the config's architecture, Env, WorkingDir, and Cmd.
//!
//! `write` takes the layer directories, bottom first, and writes one tar
//! to `out`:
//!
//!   blobs/sha256/HEX   each layer, gzipped, and the config and manifest
//!   index.json         the OCI image index, naming the manifest
//!   manifest.json      with `.docker` only: docker load's manifest
//!   oci-layout
//!
//! which is an OCI image layout (`--oci FILE`), and with `manifest.json`
//! also what `docker save` writes and `docker load` reads (`--docker`).
//! Layers keep their `.wh.` whiteouts, as OCI layers have them. Every part
//! is deterministic: the tars are `tar.zig`'s, gzip's header has no time or
//! name, the JSON is written in a fixed field order with no timestamps, and
//! the outer tar is sorted. So the same build makes the same image digest
//! (the manifest's sha256), and the same file.
//!
//! The gzipped layers are written to `work` first, a directory the caller
//! owns, since the outer tar needs each one's size before its data. They're
//! deleted as `write` returns.
//!
//! Owned by W3; `h9x export`'s wiring (cmd/export.zig) is W9's.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const flate = std.compress.flate;
const types = @import("types.zig");
const tar = @import("tar.zig");

pub const media = struct {
    pub const index = "application/vnd.oci.image.index.v1+json";
    pub const manifest = "application/vnd.oci.image.manifest.v1+json";
    pub const config = "application/vnd.oci.image.config.v1+json";
    pub const layer_gzip = "application/vnd.oci.image.layer.v1.tar+gzip";
};

/// What the image's config says about running it.
pub const Image = struct {
    arch: types.Arch,
    /// `NAME=VALUE` lines.
    env: []const []const u8 = &.{},
    /// The start command, run as `/bin/sh -c START`. Without one, the
    /// config has no `Cmd`.
    start: ?[]const u8 = null,
    cwd: []const u8 = "/app",

    pub fn ofArtifact(a: types.Artifact) Image {
        return .{ .arch = a.arch, .env = a.env, .start = a.start, .cwd = a.cwd };
    }
};

pub const Format = enum {
    /// An OCI image layout.
    oci,
    /// The layout, plus docker load's `manifest.json`.
    docker,
};

pub const Options = struct {
    format: Format = .oci,
    /// The image's name, as `NAME[:TAG]` (`latest` if it has no tag), for
    /// docker load's `RepoTags` and the index's annotations. Without one,
    /// docker load loads the image untagged.
    ref: ?[]const u8 = null,
    level: flate.Compress.Options = .default,
};

/// `sha256:` and 64 hex digits.
pub const Digest = [71]u8;

pub const Result = struct {
    /// The image's digest: the manifest's.
    digest: Digest,
    /// The image's ID, as docker names it: the config's digest.
    config: Digest,
};

/// A blob: a gzipped layer in `work`, or JSON in memory.
const Blob = struct {
    digest: Digest,
    size: u64,
    bytes: ?[]const u8 = null,

    fn hex(b: *const Blob) []const u8 {
        return b.digest["sha256:".len..];
    }
};

/// Writes the image of `layers`, bottom first, to `out` as one tar.
pub fn write(
    gpa: Allocator,
    io: Io,
    image: Image,
    layers: []const Io.Dir,
    work: Io.Dir,
    out: *Io.Writer,
    opts: Options,
) !Result {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var blobs: std.ArrayList(Blob) = .empty;
    const diff_ids = try arena.alloc([]const u8, layers.len);
    const layer_blobs = try arena.alloc(Blob, layers.len);
    var staged: usize = 0;
    defer for (layer_blobs[0..staged]) |*b| work.deleteFile(io, b.hex()) catch {};

    for (layers, 0..) |dir, i| {
        const r = try writeLayer(gpa, io, dir, work, opts.level);
        diff_ids[i] = try arena.dupe(u8, &r.diff_id);
        layer_blobs[i] = r.blob;
        staged += 1;
        try blobs.append(arena, r.blob);
    }

    // The config: no timestamps or history, so it depends on the layers
    // and the image's settings alone.
    var cmd: ?[]const []const u8 = null;
    if (image.start) |s| cmd = try arena.dupe([]const u8, &.{ "/bin/sh", "-c", s });
    const config = try json(arena, .{
        .architecture = @tagName(image.arch),
        .os = "linux",
        .config = .{
            .Env = image.env,
            .Cmd = cmd,
            .WorkingDir = image.cwd,
        },
        .rootfs = .{ .type = "layers", .diff_ids = diff_ids },
    });
    const config_blob = blobOf(config);
    try blobs.append(arena, config_blob);

    const descs = try arena.alloc(Descriptor, layers.len);
    for (descs, layer_blobs) |*d, *b| d.* = .{ .mediaType = media.layer_gzip, .digest = &b.digest, .size = b.size };
    const manifest = try json(arena, .{
        .schemaVersion = 2,
        .mediaType = media.manifest,
        .config = Descriptor{ .mediaType = media.config, .digest = &config_blob.digest, .size = config_blob.size },
        .layers = descs,
    });
    const manifest_blob = blobOf(manifest);
    try blobs.append(arena, manifest_blob);

    const Annotations = struct {
        @"io.containerd.image.name": ?[]const u8 = null,
        @"org.opencontainers.image.ref.name": ?[]const u8 = null,
    };
    var annotations: ?Annotations = null;
    var repo_tag: ?[]const u8 = null;
    if (opts.ref) |ref| {
        const r = try Ref.parse(arena, ref);
        repo_tag = r.short;
        // The ref name annotation is the tag; containerd's, which docker
        // load names the image by, is the whole reference. docker load
        // takes the ref name alone as the image's name, so both are set
        // for an OCI layout too.
        annotations = .{
            .@"io.containerd.image.name" = r.full,
            .@"org.opencontainers.image.ref.name" = r.tag,
        };
    }
    const index_json = try json(arena, .{
        .schemaVersion = 2,
        .mediaType = media.index,
        .manifests = &[_]struct {
            mediaType: []const u8,
            digest: []const u8,
            size: u64,
            platform: struct { architecture: []const u8, os: []const u8 },
            annotations: ?Annotations,
        }{.{
            .mediaType = media.manifest,
            .digest = &manifest_blob.digest,
            .size = manifest_blob.size,
            .platform = .{ .architecture = @tagName(image.arch), .os = "linux" },
            .annotations = annotations,
        }},
    });

    // The outer tar, sorted: blobs/ first, then the files at the top.
    std.mem.sort(Blob, blobs.items, {}, struct {
        fn lt(_: void, a: Blob, b: Blob) bool {
            return std.mem.lessThan(u8, &a.digest, &b.digest);
        }
    }.lt);
    var w: tar.Writer = .init(gpa, out);
    try w.dir("blobs", 0o755);
    try w.dir("blobs/sha256", 0o755);
    var buf: [64 * 1024]u8 = undefined;
    var last: ?*const Digest = null;
    for (blobs.items) |*b| {
        // An empty layer, twice, is one blob.
        if (last) |l| if (std.mem.eql(u8, l, &b.digest)) continue;
        last = &b.digest;
        const p = try std.fmt.allocPrint(arena, "blobs/sha256/{s}", .{b.hex()});
        if (b.bytes) |bytes| {
            try w.file(p, 0o644, bytes);
            continue;
        }
        const f = try work.openFile(io, b.hex(), .{});
        defer f.close(io);
        var r = f.reader(io, &buf);
        w.fileStream(p, 0o644, b.size, &r.interface) catch |e| switch (e) {
            error.ReadFailed => return r.err.?,
            error.EndOfStream => return error.FileChanged,
            else => |x| return x,
        };
    }
    try w.file("index.json", 0o644, index_json);
    if (opts.format == .docker) {
        const paths = try arena.alloc([]const u8, layers.len);
        for (paths, layer_blobs) |*p, b| p.* = try std.fmt.allocPrint(arena, "blobs/sha256/{s}", .{b.hex()});
        const tags: ?[]const []const u8 = if (repo_tag) |t| try arena.dupe([]const u8, &.{t}) else null;
        const docker = try json(arena, [_]struct {
            Config: []const u8,
            RepoTags: ?[]const []const u8,
            Layers: []const []const u8,
        }{.{
            .Config = try std.fmt.allocPrint(arena, "blobs/sha256/{s}", .{config_blob.hex()}),
            .RepoTags = tags,
            .Layers = paths,
        }});
        try w.file("manifest.json", 0o644, docker);
    }
    try w.file("oci-layout", 0o644, "{\"imageLayoutVersion\":\"1.0.0\"}");
    try w.finish();
    return .{ .digest = manifest_blob.digest, .config = config_blob.digest };
}

/// An image reference, as docker names it: `[DOMAIN/]PATH[:TAG]`.
pub const Ref = struct {
    /// With the tag, `latest` if it had none: what `RepoTags` lists.
    short: []const u8,
    /// With the domain and, on Docker Hub, `library/`: what containerd
    /// names an image by.
    full: []const u8,
    tag: []const u8,

    pub fn parse(arena: Allocator, ref: []const u8) !Ref {
        if (ref.len == 0 or std.mem.indexOfScalar(u8, ref, '@') != null) return error.BadRef;
        const slash = std.mem.lastIndexOfScalar(u8, ref, '/');
        const after = if (slash) |s| s + 1 else 0;
        const colon = std.mem.lastIndexOfScalar(u8, ref[after..], ':');
        const name = if (colon) |c| ref[0 .. after + c] else ref;
        const tag = if (colon) |c| ref[after + c + 1 ..] else "latest";
        if (tag.len == 0 or name.len == 0) return error.BadRef;
        // A first part with a dot or port, or localhost, is a domain.
        const first_end = std.mem.indexOfScalar(u8, name, '/');
        const domain = if (first_end) |e| blk: {
            const first = name[0..e];
            break :blk std.mem.indexOfAny(u8, first, ".:") != null or std.mem.eql(u8, first, "localhost");
        } else false;
        const prefix: []const u8 = if (domain) "" else if (first_end == null) "docker.io/library/" else "docker.io/";
        return .{
            .short = try std.fmt.allocPrint(arena, "{s}:{s}", .{ name, tag }),
            .full = try std.fmt.allocPrint(arena, "{s}{s}:{s}", .{ prefix, name, tag }),
            .tag = tag,
        };
    }
};

test Ref {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][3][]const u8{
        .{ "app", "app:latest", "docker.io/library/app:latest" },
        .{ "me/app:v1", "me/app:v1", "docker.io/me/app:v1" },
        .{ "ghcr.io/me/app", "ghcr.io/me/app:latest", "ghcr.io/me/app:latest" },
        .{ "localhost:5000/app:2", "localhost:5000/app:2", "localhost:5000/app:2" },
    };
    for (cases) |c| {
        const r = try Ref.parse(a, c[0]);
        try testing.expectEqualStrings(c[1], r.short);
        try testing.expectEqualStrings(c[2], r.full);
    }
    try testing.expectError(error.BadRef, Ref.parse(a, "app@sha256:00"));
    try testing.expectError(error.BadRef, Ref.parse(a, "app:"));
}

const Descriptor = struct {
    mediaType: []const u8,
    digest: []const u8,
    size: u64,
};

fn json(arena: Allocator, v: anytype) Allocator.Error![]const u8 {
    return std.json.Stringify.valueAlloc(arena, v, .{ .emit_null_optional_fields = false });
}

fn blobOf(bytes: []const u8) Blob {
    var sum: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &sum, .{});
    return .{ .digest = digestOf(sum), .size = bytes.len, .bytes = bytes };
}

fn digestOf(sum: [Sha256.digest_length]u8) Digest {
    return ("sha256:" ++ std.fmt.bytesToHex(sum, .lower)).*;
}

/// sha256 and a byte count, for `Io.Writer.Hashed`.
const Counted = struct {
    sha: Sha256 = .init(.{}),
    n: u64 = 0,

    pub fn update(c: *Counted, bytes: []const u8) void {
        c.sha.update(bytes);
        c.n += bytes.len;
    }

    fn digest(c: *Counted) Digest {
        return digestOf(c.sha.finalResult());
    }
};

const LayerResult = struct {
    /// The uncompressed tar's digest, the config's `diff_ids` entry.
    diff_id: Digest,
    blob: Blob,
};

/// Writes `dir` as a gzipped tar into `work`, named by its digest.
pub fn writeLayer(gpa: Allocator, io: Io, dir: Io.Dir, work: Io.Dir, level: flate.Compress.Options) !LayerResult {
    var tmp_name_buf: [32]u8 = undefined;
    var rand: [8]u8 = undefined;
    io.random(&rand);
    const tmp_name = try std.fmt.bufPrint(&tmp_name_buf, ".layer-{x}", .{&rand});
    const f = try work.createFile(io, tmp_name, .{});
    var keep = false;
    defer if (!keep) work.deleteFile(io, tmp_name) catch {};
    {
        defer f.close(io);
        var file_buf: [64 * 1024]u8 = undefined;
        var fw = f.writer(io, &file_buf);
        // tar -> sha256 (diff_id) -> gzip -> sha256 and size (blob) -> file
        var blob_buf: [256]u8 = undefined;
        var blob: Io.Writer.Hashed(Counted) = .init(&fw.interface, &blob_buf);
        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        var gz: flate.Compress = try .init(&blob.writer, window, .gzip, level);
        var diff_buf: [256]u8 = undefined;
        var diff: Io.Writer.Hashed(Counted) = .init(&gz.writer, &diff_buf);

        tar.writeLayer(gpa, io, dir, &diff.writer) catch |e| return flushError(e, &fw);
        diff.writer.flush() catch |e| return flushError(e, &fw);
        gz.finish() catch |e| return flushError(e, &fw);
        blob.writer.flush() catch |e| return flushError(e, &fw);
        fw.interface.flush() catch |e| return flushError(e, &fw);

        const r: LayerResult = .{
            .diff_id = diff.hasher.digest(),
            .blob = .{ .digest = blob.hasher.digest(), .size = blob.hasher.n },
        };
        try work.rename(tmp_name, work, r.blob.hex(), io);
        keep = true;
        return r;
    }
}

/// The file's error for a write that failed on it.
fn flushError(e: anyerror, fw: *Io.File.Writer) anyerror {
    if (e == error.WriteFailed) if (fw.err) |x| return x;
    return e;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn mkfile(dir: Io.Dir, path: []const u8, data: []const u8) !void {
    const io = testing.io;
    if (std.fs.path.dirname(path)) |d| try dir.createDirPath(io, d);
    try dir.writeFile(io, .{ .sub_path = path, .data = data, .flags = .{ .permissions = .fromMode(0o644) } });
}

/// The files in a tar, by name.
const Files = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    fn init(gpa: Allocator, bytes: []const u8) !Files {
        var f: Files = .{ .arena = .init(gpa) };
        errdefer f.arena.deinit();
        const a = f.arena.allocator();
        var in: Io.Reader = .fixed(bytes);
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        var it: std.tar.Iterator = .init(&in, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
        while (try it.next()) |e| {
            if (e.kind != .file) continue;
            var data: Io.Writer.Allocating = .init(a);
            try it.streamRemaining(e, &data.writer);
            try f.map.put(a, try a.dupe(u8, e.name), data.written());
        }
        return f;
    }

    fn deinit(f: *Files) void {
        f.arena.deinit();
    }

    fn blob(f: *Files, digest: []const u8) ![]const u8 {
        var buf: [128]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "blobs/sha256/{s}", .{digest["sha256:".len..]});
        return f.map.get(p) orelse error.NoBlob;
    }
};

fn gunzip(gpa: Allocator, bytes: []const u8) ![]u8 {
    var in: Io.Reader = .fixed(bytes);
    var window: [flate.max_window_len]u8 = undefined;
    var gz: flate.Decompress = .init(&in, .gzip, &window);
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    _ = try gz.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

fn sha(bytes: []const u8) Digest {
    var sum: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &sum, .{});
    return digestOf(sum);
}

test "an image's layers, config, and manifest agree, and the same layers make the same digest" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try mkfile(tmp.dir, "base/bin/sh", "#!/bin/busybox");
    try mkfile(tmp.dir, "base/etc/motd", "hi");
    try mkfile(tmp.dir, "app/app/server.js", "listen()");
    try mkfile(tmp.dir, "app/etc/.wh.motd", "");
    try tmp.dir.createDirPath(io, "empty");
    try tmp.dir.createDirPath(io, "work1");
    try tmp.dir.createDirPath(io, "work2");

    var dirs: [3]Io.Dir = undefined;
    for (&dirs, [_][]const u8{ "base", "app", "empty" }) |*d, name| d.* = try tmp.dir.openDir(io, name, .{ .iterate = true });
    defer for (dirs) |d| d.close(io);
    const image: Image = .{ .arch = .amd64, .env = &.{"PATH=/usr/bin:/bin"}, .start = "node server.js" };

    var outs: [2]Io.Writer.Allocating = .{ .init(gpa), .init(gpa) };
    defer for (&outs) |*o| o.deinit();
    var results: [2]Result = undefined;
    for (&outs, &results, [_][]const u8{ "work1", "work2" }) |*o, *r, wname| {
        var work = try tmp.dir.openDir(io, wname, .{ .iterate = true });
        defer work.close(io);
        r.* = try write(gpa, io, image, &dirs, work, &o.writer, .{ .format = .docker, .ref = "h9x/app:latest" });
        // The staged layers are gone.
        var it = work.iterate();
        try testing.expect(try it.next(io) == null);
    }
    try testing.expectEqualSlices(u8, outs[0].written(), outs[1].written());
    try testing.expectEqualStrings(&results[0].digest, &results[1].digest);

    var files: Files = try .init(gpa, outs[0].written());
    defer files.deinit();
    try testing.expectEqualStrings("{\"imageLayoutVersion\":\"1.0.0\"}", files.map.get("oci-layout").?);

    const manifest_bytes = try files.blob(&results[0].digest);
    try testing.expectEqualStrings(&results[0].digest, &sha(manifest_bytes));
    const index_json = files.map.get("index.json").?;
    try testing.expect(std.mem.indexOf(u8, index_json, &results[0].digest) != null);
    try testing.expect(std.mem.indexOf(u8, index_json, "\"org.opencontainers.image.ref.name\":\"latest\"") != null);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const M = struct {
        config: Descriptor,
        layers: []Descriptor,
    };
    const m = try std.json.parseFromSliceLeaky(M, a, manifest_bytes, .{ .ignore_unknown_fields = true });
    const C = struct {
        architecture: []const u8,
        config: struct { Env: []const []const u8, Cmd: []const []const u8, WorkingDir: []const u8 },
        rootfs: struct { diff_ids: []const []const u8 },
    };
    const config_bytes = try files.blob(m.config.digest);
    try testing.expectEqualStrings(&results[0].config, &sha(config_bytes));
    const c = try std.json.parseFromSliceLeaky(C, a, config_bytes, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings("amd64", c.architecture);
    try testing.expectEqualStrings("node server.js", c.config.Cmd[2]);
    try testing.expectEqualStrings("/app", c.config.WorkingDir);
    try testing.expectEqual(@as(usize, 3), m.layers.len);

    for (m.layers, c.rootfs.diff_ids, dirs) |l, diff_id, d| {
        const gz = try files.blob(l.digest);
        try testing.expectEqual(l.size, gz.len);
        try testing.expectEqualStrings(l.digest, &sha(gz));
        // The layer is the deterministic tar of its directory.
        const layer = try gunzip(gpa, gz);
        defer gpa.free(layer);
        try testing.expectEqualStrings(diff_id, &sha(layer));
        var want: Io.Writer.Allocating = .init(gpa);
        defer want.deinit();
        try tar.writeLayer(gpa, io, d, &want.writer);
        try testing.expectEqualSlices(u8, want.written(), layer);
    }
    // The whiteout is kept.
    const app_layer = try gunzip(gpa, try files.blob(m.layers[1].digest));
    defer gpa.free(app_layer);
    var app_files: Files = try .init(gpa, app_layer);
    defer app_files.deinit();
    try testing.expect(app_files.map.contains("etc/.wh.motd"));

    // docker load's manifest names the same blobs.
    const D = struct { Config: []const u8, RepoTags: []const []const u8, Layers: []const []const u8 };
    const docker = try std.json.parseFromSliceLeaky([]D, a, files.map.get("manifest.json").?, .{});
    try testing.expectEqualStrings("h9x/app:latest", docker[0].RepoTags[0]);
    try testing.expect(std.mem.endsWith(u8, docker[0].Config, m.config.digest["sha256:".len..]));
    try testing.expect(std.mem.endsWith(u8, docker[0].Layers[2], m.layers[2].digest["sha256:".len..]));
}

test "an OCI layout has no docker manifest, and no Cmd without a start command" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try mkfile(tmp.dir, "base/bin/sh", "sh");
    try tmp.dir.createDirPath(io, "work");
    var base = try tmp.dir.openDir(io, "base", .{ .iterate = true });
    defer base.close(io);
    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const r = try write(gpa, io, .{ .arch = .arm64 }, &.{base}, work, &out.writer, .{});
    var files: Files = try .init(gpa, out.written());
    defer files.deinit();
    try testing.expect(!files.map.contains("manifest.json"));
    const config = try files.blob(&r.config);
    try testing.expect(std.mem.indexOf(u8, config, "Cmd") == null);
    try testing.expect(std.mem.indexOf(u8, config, "\"architecture\":\"arm64\"") != null);
    try testing.expect(std.mem.indexOf(u8, files.map.get("index.json").?, "annotations") == null);
}
