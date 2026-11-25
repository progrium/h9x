//! Runners for packed executables (design/prototype.md, "Runners"): the
//! host's, embedded in h9x; the others, from h9x's release as
//! `h9x-runner-VERSION-TARGET`, pinned by version and sha256 here and
//! downloaded into `$cache/runners/` the first time a pack asks; and
//! `--runner FILE`, for one built by hand.
//!
//! Owned by W8.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const types = @import("types.zig");
const exe = @import("exe/exe.zig");

/// The target h9x itself runs on, whose runner it embeds, or null on a
/// host that isn't one of h9's release targets.
pub fn hostTarget() ?types.Target {
    return switch (builtin.os.tag) {
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => .@"linux-amd64",
            .aarch64 => .@"linux-arm64",
            else => null,
        },
        .macos => if (builtin.cpu.arch == .aarch64) .@"macos-arm64" else null,
        .windows => if (builtin.cpu.arch == .x86_64) .@"windows-amd64" else null,
        else => null,
    };
}

/// A released runner: its target and its sha256, in hex.
pub const Pin = struct {
    target: types.Target,
    sha256: []const u8,
};

/// The runners of h9x's release `version`, pinned. Empty until the first
/// release: before then, `--runner` gives the other targets' runners.
pub const pins = struct {
    pub const version = "";
    pub const list = [_]Pin{};
};

/// `h9x-runner-VERSION-TARGET`, with `.exe` on Windows.
pub fn releaseName(arena: Allocator, version: []const u8, t: types.Target) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "h9x-runner-{s}-{t}{s}", .{ version, t, if (t.container() == .pe) ".exe" else "" });
}

/// Where a release's runner is downloaded from.
pub fn releaseUrl(arena: Allocator, version: []const u8, t: types.Target) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "https://github.com/progrium/h9x/releases/download/v{s}/{s}", .{ version, try releaseName(arena, version, t) });
}

/// `pins.list`'s entry for `t`, or null.
pub fn pinFor(list: []const Pin, t: types.Target) ?Pin {
    for (list) |p| if (p.target == t) return p;
    return null;
}

/// What a `--runner` value names: `FILE` for every target that matches it,
/// or `TARGET=FILE` for one.
pub const Given = struct {
    target: ?types.Target,
    path: []const u8,

    pub fn parse(v: []const u8) Given {
        if (std.mem.indexOfScalar(u8, v, '=')) |i| {
            if (std.meta.stringToEnum(types.Target, v[0..i])) |t| return .{ .target = t, .path = v[i + 1 ..] };
        }
        return .{ .target = null, .path = v };
    }
};

/// Whether `bytes` is a runner for `t`: the container its OS uses, for
/// its architecture.
pub fn matches(bytes: []const u8, t: types.Target) bool {
    const c = exe.detect(bytes) orelse return false;
    if (c != t.container()) return false;
    const want: []const u8 = switch (t.arch()) {
        .amd64 => "x86_64",
        .arm64 => "arm64",
    };
    return std.mem.eql(u8, archOf(bytes, c), want);
}

/// The architecture an executable's header names, as `pack --inspect`
/// writes it.
fn archOf(head: []const u8, c: exe.Container) []const u8 {
    switch (c) {
        .elf => {
            if (head.len < 20) return "unknown";
            const m = std.mem.readInt(u16, head[18..20], if (head[5] == 2) .big else .little);
            return switch (m) {
                62 => "x86_64",
                183 => "arm64",
                else => "unknown",
            };
        },
        .macho => {
            if (head.len < 8) return "unknown";
            return switch (std.mem.readInt(u32, head[4..8], .little)) {
                0x01000007 => "x86_64",
                0x0100000c => "arm64",
                else => "unknown",
            };
        },
        .pe => {
            if (head.len < 0x40) return "unknown";
            const pe_off = std.mem.readInt(u32, head[0x3c..0x40], .little);
            if (pe_off + 6 > head.len) return "unknown";
            return switch (std.mem.readInt(u16, head[pe_off + 4 ..][0..2], .little)) {
                0x8664 => "x86_64",
                0xaa64 => "arm64",
                else => "unknown",
            };
        },
    }
}

pub const Error = error{
    /// No runner for the target: not the host's, no `--runner`, and no
    /// release pins one.
    NoRunner,
    /// A `--runner` file isn't a runner for its target.
    WrongRunner,
    /// A download's sha256 isn't the pinned one.
    DigestMismatch,
    DownloadFailed,
};

/// The runner in the cache for `pin`, downloading it first if it isn't
/// there, checked against the pin. Returns its bytes.
pub fn fetch(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    cache_dir: []const u8,
    version: []const u8,
    pin: Pin,
) ![]const u8 {
    const name = try releaseName(arena, version, pin.target);
    const dir_path = try std.fs.path.join(arena, &.{ cache_dir, "runners" });
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, dir_path);
    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);

    if (dir.readFileAlloc(io, name, arena, .limited(256 << 20))) |bytes| {
        if (checkDigest(bytes, pin.sha256)) {
            touch(io, dir, name);
            return bytes;
        }
        // A partial or changed file: download it again.
    } else |e| if (e != error.FileNotFound) return e;

    const url = try releaseUrl(arena, version, pin.target);
    var body: Io.Writer.Allocating = .init(arena);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    client.initDefaultProxies(arena, env) catch {};
    const res = client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer }) catch return error.DownloadFailed;
    if (res.status != .ok) return error.DownloadFailed;
    const bytes = body.written();
    if (!checkDigest(bytes, pin.sha256)) return error.DigestMismatch;

    var tmp_buf: [64]u8 = undefined;
    var rand: [8]u8 = undefined;
    io.random(&rand);
    const tmp = try std.fmt.bufPrint(&tmp_buf, ".dl-{x}", .{&rand});
    try dir.writeFile(io, .{ .sub_path = tmp, .data = bytes });
    errdefer dir.deleteFile(io, tmp) catch {};
    try dir.rename(tmp, dir, name, io);
    return bytes;
}

fn checkDigest(bytes: []const u8, want_hex: []const u8) bool {
    var sum: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &sum, .{});
    const hex = std.fmt.bytesToHex(sum, .lower);
    return std.ascii.eqlIgnoreCase(&hex, want_hex);
}

fn touch(io: Io, dir: Io.Dir, name: []const u8) void {
    dir.setTimestamps(io, name, .{ .modify_timestamp = .now }) catch {};
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "Given.parse" {
    const a = Given.parse("./r");
    try testing.expectEqual(@as(?types.Target, null), a.target);
    const b = Given.parse("macos-arm64=out/h9x-runner");
    try testing.expectEqual(types.Target.@"macos-arm64", b.target.?);
    try testing.expectEqualStrings("out/h9x-runner", b.path);
    // An `=` in a path that doesn't start with a target is the path's.
    try testing.expectEqualStrings("a=b", Given.parse("a=b").path);
}

test "release names" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    try testing.expectEqualStrings(
        "https://github.com/progrium/h9x/releases/download/v0.1.0/h9x-runner-0.1.0-windows-amd64.exe",
        try releaseUrl(a.allocator(), "0.1.0", .@"windows-amd64"),
    );
}

test "fetch uses a cached runner whose digest matches" {
    const io = testing.io;
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "runners");
    try tmp.dir.writeFile(io, .{ .sub_path = "runners/h9x-runner-9.9.9-linux-arm64", .data = "runner" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    var sum: [32]u8 = undefined;
    Sha256.hash("runner", &sum, .{});
    const hex = std.fmt.bytesToHex(sum, .lower);
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    const got = try fetch(testing.allocator, arena, io, &env, root, "9.9.9", .{ .target = .@"linux-arm64", .sha256 = &hex });
    try testing.expectEqualStrings("runner", got);
}
