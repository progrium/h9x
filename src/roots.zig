//! Roots (design/prototype.md, "The build engine"): the bootstrap (Alpine's
//! minirootfs and Railpack, pinned by version and sha256), and the base and
//! builder roots, made by the embedded roots.sh in a machine on the Alpine
//! root, keyed by architecture, repository, and package set.
//!
//! Every root gets `/app` and the mount points the guest scripts' trees
//! need, `/h9x/{src,tools,guest,railpack,ca}`.
//!
//! `Env` is what the build's machines share, and `guest` is how roots.zig
//! and layers.zig start one: a policy compiled into machine options, with
//! the cwd, stdio, and the host's settings added.

const std = @import("std");
const types = @import("types.zig");
const cli = @import("cli.zig");
const cache = @import("cache.zig");
const config = @import("config.zig");
const policy = @import("policy.zig");
const machine = @import("machine.zig");
const embedded = @import("embedded.zig");
const download = @import("download.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const alpine_version = "3.22.2";
pub const railpack_version = "0.43.0";
pub const wolfi_repo = "https://packages.wolfi.dev/os";

/// The base root every app runs on, as Railpack's runtime image: glibc,
/// its loader, the C++ runtime most prebuilt runtimes link against,
/// OpenSSL and zlib, certificates, time zones, busybox for /bin/sh (start
/// commands and npm scripts run through it), and bash, which some of
/// mise's runtimes use for their wrappers (node's npm).
pub const base_packages = [_][]const u8{
    "wolfi-baselayout", "glibc",  "ld-linux",               "libgcc", "libstdc++", "libssl3", "zlib",
    "ca-certificates-bundle", "tzdata", "busybox", "bash",
};

/// What the builder adds, as Railpack's builder image has it: compilers
/// and the usual headers, which runtimes mise builds from source and
/// native packages (node-gyp, gems, cgo) need, and jq and git, which
/// build.sh and the package managers use.
pub const builder_packages = [_][]const u8{
    "jq",          "git",       "curl",      "unzip",       "zip",        "xz",        "zstd",      "rsync",
    "build-base",  "cmake",     "autoconf",  "automake",    "libtool",    "pkgconf",   "perl",      "openssl-dev",
    "zlib-dev",    "bzip2-dev", "xz-dev",    "zstd-dev",    "readline-dev", "sqlite-dev", "ncurses-dev", "libxml2-dev",
    "icu-dev",     "libffi-dev", "yaml-dev", "gmp-dev",
};

/// A download pinned by its sha256.
pub const Pin = struct { url: []const u8, sha256: []const u8 };

pub fn alpinePin(arch: types.Arch) Pin {
    return switch (arch) {
        .amd64 => .{
            .url = "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/alpine-minirootfs-3.22.2-x86_64.tar.gz",
            .sha256 = "412454ed98025ad9cd910d13f3d448b184e81502baa83180e89f98d0f13674be",
        },
        .arm64 => .{
            .url = "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/aarch64/alpine-minirootfs-3.22.2-aarch64.tar.gz",
            .sha256 = "6bf491907b705caa5fc65773fbbc1d0954530b6c455d4446f670a4c1fdcea489",
        },
    };
}

pub fn railpackPin(arch: types.Arch) Pin {
    return switch (arch) {
        .amd64 => .{
            .url = "https://github.com/railwayapp/railpack/releases/download/v0.43.0/railpack-v0.43.0-x86_64-unknown-linux-musl.tar.gz",
            .sha256 = "248a8f60f36854aabed6124113631078a802de3461660855fc4de9c26065c1fb",
        },
        .arm64 => .{
            .url = "https://github.com/railwayapp/railpack/releases/download/v0.43.0/railpack-v0.43.0-arm64-unknown-linux-musl.tar.gz",
            .sha256 = "732ece14eb4f4676a43ebba19431f954edf7b130acb76159ef0f2ff86ac42ac9",
        },
    };
}

pub const wolfi_key: Pin = .{
    .url = wolfi_repo ++ "/wolfi-signing.rsa.pub",
    .sha256 = "f0031424cf46f7db780ce63a45f0fd6aa6f85f601e6bb3b7a91fe3d4d5b7d2cc",
};

// ---------------------------------------------------------------- the environment

/// What every machine a build starts shares.
pub const Env = struct {
    ctx: *cli.Context,
    cache_dir: []const u8,
    arch: types.Arch,
    host: machine.Host,
    cfg: config.Config,
    /// The source's trust: a remote source's is untrusted.
    trust: types.Trust = .trusted,

    pub fn init(ctx: *cli.Context, cfg: config.Config) !Env {
        const arch = types.Arch.host() orelse {
            ctx.events.log("h9x builds on amd64 and arm64 hosts only", .{});
            return error.UnsupportedHost;
        };
        const cache_dir = try cache.dir(ctx.arena, ctx.env);
        const host = machine.Host.init(ctx.arena, ctx.io, ctx.env, cache_dir) catch |e| switch (e) {
            error.BadBackend => {
                ctx.events.log("H9X_BACKEND: not a backend h9 has", .{});
                return error.BadBackend;
            },
            error.CaUnreadable => {
                ctx.events.log("SSL_CERT_FILE: can't read it", .{});
                return error.CaUnreadable;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        return .{ .ctx = ctx, .cache_dir = cache_dir, .arch = arch, .host = host, .cfg = cfg };
    }

    pub fn path(e: Env, kind: cache.Kind, name: []const u8) ![]const u8 {
        return cache.path(e.ctx.arena, e.cache_dir, kind, name);
    }

    /// The `netallow` patterns every machine with a network needs: the
    /// HTTPS proxy's endpoint, since guest connections go to it directly.
    pub fn proxyAllow(e: Env) ![]const []const u8 {
        const p = e.host.https_proxy orelse return &.{};
        var s = p;
        if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
        if (std.mem.lastIndexOfScalar(u8, s, '@')) |i| s = s[i + 1 ..];
        if (std.mem.indexOfScalar(u8, s, '/')) |i| s = s[0..i];
        const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse
            return e.ctx.arena.dupe([]const u8, &.{try std.fmt.allocPrint(e.ctx.arena, "tcp!{s}!80", .{s})});
        return e.ctx.arena.dupe([]const u8, &.{try std.fmt.allocPrint(e.ctx.arena, "tcp!{s}!{s}", .{ s[0..colon], s[colon + 1 ..] })});
    }

    /// Host variables passed to every build machine when they're set:
    /// mise's attestation switches, which a proxy that refuses GitHub's API
    /// and Sigstore needs turned off.
    pub fn passEnv(e: Env) ![]const types.EnvVar {
        const names = [_][]const u8{ "MISE_GITHUB_ATTESTATIONS", "MISE_AQUA_COSIGN", "MISE_AQUA_SLSA", "MISE_AQUA_MINISIGN", "MISE_AQUA_GITHUB_ATTESTATIONS" };
        var out: std.ArrayList(types.EnvVar) = .empty;
        for (names) |n| if (e.ctx.env.get(n)) |v| try out.append(e.ctx.arena, .{ .name = n, .value = v });
        return out.items;
    }

    /// A machine's policy, by config.zig's rules, with exit 2's errors
    /// named for events.zig.
    pub fn policyFor(e: Env, req: config.Request) !types.Policy {
        return config.policyFor(e.ctx, e.cfg, req) catch |err| switch (err) {
            error.Widens => error.PolicyWidens,
            error.Config => error.BadConfig,
            error.OutOfMemory => error.OutOfMemory,
        };
    }
};

/// The first 16 hex digits of `text`'s sha256, as the POC's `sha`.
pub fn shortHash(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var d: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(text, &d, .{});
    return arena.dupe(u8, &std.fmt.bytesToHex(d[0..8], .lower));
}

// ---------------------------------------------------------------- machines

/// Where a guest's output goes.
pub const Output = struct {
    out: *Io.Writer,
    err: *Io.Writer,
};

/// Starts a machine with policy `p` (mounts, network, limits, and env),
/// `cwd` as its host working directory (written to by the guest), and
/// runs `argv`. Returns the exit code, as h9 maps the guest's status;
/// error.Timeout for a timeout, and error.MachineFailed, logged, when
/// h9 couldn't start it.
pub fn guest(e: Env, p: types.Policy, cwd: ?[]const u8, argv: []const []const u8, out: Output) !u8 {
    const ctx = e.ctx;
    var diag: policy.Diag = .{};
    var o = policy.compile(ctx.arena, p, &diag) catch |err| switch (err) {
        error.Conflict => {
            ctx.events.log("{t} policy: {s}", .{ p.phase, diag.msg });
            return error.PolicyConflict;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    var in: Io.Reader = .fixed("");
    o.stdio = .{ .in = &in, .out = out.out, .err = out.err };
    o.cwd = cwd;
    o.console_tty = false;
    o.guest_tools = false;
    if (cwd != null) o.policy.cwd_writable = true;
    var why: []const u8 = "";
    const status = machine.run(ctx.gpa, ctx.arena, ctx.io, e.host, o, argv, &why) catch |err| {
        out.out.flush() catch {};
        out.err.flush() catch {};
        ctx.events.log("{t}: {s}: {s}", .{ p.phase, argv[argv.len - 1], if (why.len > 0) why else @errorName(err) });
        return error.MachineFailed;
    };
    out.out.flush() catch {};
    out.err.flush() catch {};
    const code = machine.exitCode(status);
    if (code == 124) return error.Timeout;
    return code;
}

// ---------------------------------------------------------------- the bootstrap

pub const Bootstrap = struct {
    /// Alpine's minirootfs, unpacked.
    alpine: []const u8,
    /// Wolfi's signing key.
    key_file: []const u8,
};

/// Downloads `pin` into `dl/NAME` unless it's there, and checks its sha256.
fn fetch(e: Env, pin: Pin, name: []const u8) ![]const u8 {
    const ctx = e.ctx;
    const dest = try e.path(.dl, name);
    if (Dir.cwd().access(ctx.io, dest, .{})) |_| {
        cache.touch(ctx.io, dest);
        return dest;
    } else |_| {}
    ctx.events.emit(.{ .fetch = .{ .url = pin.url, .state = .start } });
    var why: []const u8 = "";
    download.toFile(ctx.gpa, ctx.io, pin.url, dest, download.optionsFrom(ctx.env), &why) catch |err| {
        ctx.events.emit(.{ .fetch = .{ .url = pin.url, .state = .failed } });
        ctx.events.log("fetching {s}: {s}", .{ pin.url, if (why.len > 0) why else @errorName(err) });
        return error.DownloadFailed;
    };
    const got = try fileSha256(ctx.io, dest);
    if (!std.mem.eql(u8, &got, pin.sha256)) {
        Dir.cwd().deleteFile(ctx.io, dest) catch {};
        ctx.events.log("{s}: sha256 {s}, but h9x pins {s}", .{ pin.url, &got, pin.sha256 });
        return error.DownloadFailed;
    }
    ctx.events.emit(.{ .fetch = .{ .url = pin.url, .state = .done } });
    return dest;
}

fn fileSha256(io: Io, p: []const u8) ![64]u8 {
    var f = try Dir.cwd().openFile(io, p, .{});
    defer f.close(io);
    var rbuf: [64 << 10]u8 = undefined;
    var buf: [64 << 10]u8 = undefined;
    var r = f.reader(io, &rbuf);
    var h = Sha256.init(.{});
    while (true) {
        const n = r.interface.readSliceShort(&buf) catch return error.ReadFailed;
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}

/// Unpacks a gzipped tar into `dest`, through `dest.tmp`.
fn untgz(e: Env, tgz: []const u8, dest: []const u8, only: ?[]const u8) !void {
    const io = e.ctx.io;
    const cwd = Dir.cwd();
    const tmp = try std.fmt.allocPrint(e.ctx.arena, "{s}.tmp", .{dest});
    cache.removeTree(io, tmp) catch {};
    try cwd.createDirPath(io, tmp);
    {
        var d = try cwd.openDir(io, tmp, .{});
        defer d.close(io);
        var f = try cwd.openFile(io, tgz, .{});
        defer f.close(io);
        var fbuf: [64 << 10]u8 = undefined;
        var fr = f.reader(io, &fbuf);
        var zbuf: [std.compress.flate.max_window_len]u8 = undefined;
        var z: std.compress.flate.Decompress = .init(&fr.interface, .gzip, &zbuf);
        if (only) |name| {
            try extractOne(io, d, &z.reader, name);
        } else {
            try std.tar.extract(io, d, &z.reader, .{ .mode_mode = .executable_bit_only });
        }
    }
    try Dir.rename(cwd, tmp, cwd, dest, io);
}

/// Extracts the file `name` from a tar.
fn extractOne(io: Io, d: Dir, r: *Io.Reader, name: []const u8) !void {
    var file_name: [std.fs.max_path_bytes]u8 = undefined;
    var link_name: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(r, .{ .file_name_buffer = &file_name, .link_name_buffer = &link_name });
    while (try it.next()) |f| {
        if (f.kind != .file or !std.mem.eql(u8, std.mem.trimStart(u8, f.name, "./"), name)) continue;
        var out = try d.createFile(io, name, .{ .permissions = .executable_file });
        defer out.close(io);
        var buf: [64 << 10]u8 = undefined;
        var w = out.writer(io, &buf);
        try it.streamRemaining(f, &w.interface);
        try w.interface.flush();
        return;
    }
    return error.NotInArchive;
}

/// Alpine's minirootfs and Wolfi's key, downloaded and unpacked once.
pub fn bootstrap(e: Env) !Bootstrap {
    const ctx = e.ctx;
    const io = ctx.io;
    const name = try std.fmt.allocPrint(ctx.arena, "alpine-{s}-{s}", .{ alpine_version, e.arch.linuxName() });
    const dir = try e.path(.bootstrap, name);
    const etc = try std.fs.path.join(ctx.arena, &.{ dir, "etc" });
    if (Dir.cwd().access(io, etc, .{})) |_| {} else |_| {
        ctx.events.emit(.{ .root = .{ .root = .bootstrap, .key = name, .state = .building } });
        const tgz = try fetch(e, alpinePin(e.arch), try std.fmt.allocPrint(ctx.arena, "{s}.tgz", .{name}));
        cache.removeTree(io, dir) catch {};
        try untgz(e, tgz, dir, null);
        ctx.events.emit(.{ .root = .{ .root = .bootstrap, .key = name, .state = .done } });
    }
    // roots.sh's up layer is mounted at /r, and the CA bundle at /h9x/ca.
    try Dir.cwd().createDirPath(io, try std.fs.path.join(ctx.arena, &.{ dir, "r" }));
    try Dir.cwd().createDirPath(io, try std.fs.path.join(ctx.arena, &.{ dir, "h9x", "ca" }));
    cache.touch(io, dir);
    const key_file = try fetch(e, wolfi_key, "wolfi-signing.rsa.pub");
    return .{ .alpine = dir, .key_file = key_file };
}

/// Railpack's binary: `H9X_RAILPACK`, or the pinned release in the tools.
pub fn railpack(e: Env) ![]const u8 {
    const ctx = e.ctx;
    const io = ctx.io;
    if (e.cfg.railpack) |r| {
        const abs = Dir.cwd().realPathFileAlloc(io, r, ctx.arena) catch {
            ctx.events.log("H9X_RAILPACK: {s}: no such file", .{r});
            return error.BadConfig;
        };
        return abs;
    }
    const name = try std.fmt.allocPrint(ctx.arena, "railpack-{s}-{s}", .{ railpack_version, e.arch.linuxName() });
    const dir = try e.path(.tools, name);
    const bin = try std.fs.path.join(ctx.arena, &.{ dir, "railpack" });
    if (Dir.cwd().access(io, bin, .{})) |_| {} else |_| {
        const tgz = try fetch(e, railpackPin(e.arch), try std.fmt.allocPrint(ctx.arena, "{s}.tgz", .{name}));
        cache.removeTree(io, dir) catch {};
        try untgz(e, tgz, dir, "railpack");
    }
    cache.touch(io, dir);
    return bin;
}

/// The version string the plan key takes for Railpack: the pinned
/// version, or for `H9X_RAILPACK`, its path, size, and mtime, as the POC's
/// `ls -lL` did.
pub fn railpackIdentity(e: Env, bin: []const u8) ![]const u8 {
    if (e.cfg.railpack == null) return railpack_version;
    const st = try Dir.cwd().statFile(e.ctx.io, bin, .{});
    return std.fmt.allocPrint(e.ctx.arena, "{s} {d} {d}", .{ bin, st.size, st.mtime.nanoseconds });
}

/// The guest scripts, written into the tools once per version of them:
/// `tools/guest-HASH/build.sh`, mounted read-only at /h9x/guest.
pub fn guestDir(e: Env) ![]const u8 {
    const io = e.ctx.io;
    const h = try shortHash(e.ctx.arena, embedded.build_sh);
    const dir = try e.path(.tools, try std.fmt.allocPrint(e.ctx.arena, "guest-{s}", .{h}));
    const file = try std.fs.path.join(e.ctx.arena, &.{ dir, "build.sh" });
    if (Dir.cwd().access(io, file, .{})) |_| {} else |_| {
        const tmp = try std.fmt.allocPrint(e.ctx.arena, "{s}.tmp", .{dir});
        cache.removeTree(io, tmp) catch {};
        try Dir.cwd().createDirPath(io, tmp);
        try Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(e.ctx.arena, &.{ tmp, "build.sh" }), .data = embedded.build_sh });
        cache.removeTree(io, dir) catch {};
        try Dir.rename(Dir.cwd(), tmp, Dir.cwd(), dir, io);
    }
    cache.touch(io, dir);
    return dir;
}

// ---------------------------------------------------------------- roots

/// A root's key: the architecture, the repository, Alpine's version, and
/// the packages, in order.
pub fn rootKey(arena: std.mem.Allocator, arch: types.Arch, packages: []const []const u8) ![]const u8 {
    var w: Io.Writer.Allocating = .init(arena);
    try w.writer.print("root {s} {s} {s}", .{ arch.linuxName(), wolfi_repo, alpine_version });
    for (packages) |p| try w.writer.print(" {s}", .{p});
    return shortHash(arena, w.written());
}

/// The packages a root of `kind` has: its list, then the config's and
/// `extra`'s (the plan's apt packages as Wolfi names).
pub fn packagesFor(e: Env, kind: types.Root.Kind, extra: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const a = e.ctx.arena;
    try out.appendSlice(a, &base_packages);
    try out.appendSlice(a, e.cfg.roots.base);
    if (kind == .builder) {
        try out.appendSlice(a, &builder_packages);
        try out.appendSlice(a, e.cfg.roots.build);
    }
    try out.appendSlice(a, extra);
    return out.items;
}

/// The root of `kind` with `packages`, made once per package set: apk,
/// in a machine on the bootstrap root, installs them into the new root's
/// directory, mounted as the up layer at /r.
pub fn make(e: Env, boot: Bootstrap, kind: types.Root.Kind, packages: []const []const u8) !types.Root {
    std.debug.assert(kind != .bootstrap);
    const ctx = e.ctx;
    const io = ctx.io;
    const a = ctx.arena;
    const cwd = Dir.cwd();
    const key = try rootKey(a, e.arch, packages);
    const name = try std.fmt.allocPrint(a, "{t}-{s}", .{ kind, key });
    const dir = try e.path(.roots, name);
    const root: types.Root = .{ .kind = kind, .path = dir, .packages = packages };
    if (cwd.access(io, try std.fs.path.join(a, &.{ dir, "usr" }), .{})) |_| {
        ctx.events.emit(.{ .root = .{ .root = kind, .key = key, .state = .cached } });
        cache.touch(io, dir);
        return root;
    } else |_| {}

    ctx.events.emit(.{ .root = .{ .root = kind, .key = key, .state = .building } });
    const tmp = try e.path(.roots, try std.fmt.allocPrint(a, ".{s}.tmp", .{name}));
    const work = try e.path(.roots, try std.fmt.allocPrint(a, ".work-{s}", .{name}));
    cache.removeTree(io, tmp) catch {};
    cache.removeTree(io, work) catch {};
    try cwd.createDirPath(io, tmp);
    try cwd.createDirPath(io, work);
    defer cache.removeTree(io, work) catch {};
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ work, "roots.sh" }), .data = embedded.roots_sh });
    const key_bytes = try cwd.readFileAlloc(io, boot.key_file, a, .limited(64 << 10));
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ work, "wolfi-signing.rsa.pub" }), .data = key_bytes });

    var p = policy.defaults(.root, .trusted);
    p = try policy.apply(a, p, .{
        .mounts = &.{
            .{ .kind = .dir, .src = boot.alpine, .dst = "#L", .access = .ro },
            .{ .kind = .dir, .src = tmp, .dst = "/r", .access = .up },
            .{ .kind = .tmp, .dst = "/tmp" },
        },
        .netallow_add = try e.proxyAllow(),
        .env = &.{.{ .name = "PATH", .value = "/usr/sbin:/usr/bin:/sbin:/bin" }},
    });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "/bin/sh", "/mnt/term/cwd/roots.sh", e.arch.linuxName(), wolfi_repo });
    try argv.appendSlice(a, packages);
    var obuf: [4096]u8 = undefined;
    var ebuf: [4096]u8 = undefined;
    var o = ctx.events.output(null, null, .stderr, &obuf);
    var er = ctx.events.output(null, null, .stderr, &ebuf);
    const code = try guest(e, p, work, argv.items, .{ .out = &o.interface, .err = &er.interface });
    if (code != 0) {
        ctx.events.emit(.{ .root = .{ .root = kind, .key = key, .state = .failed } });
        ctx.events.log("making the {t} root: roots.sh exited {d}", .{ kind, code });
        cache.removeTree(io, tmp) catch {};
        return error.RootFailed;
    }

    // apk's scripts can't run, so do busybox's install here: a link for
    // each applet that no package provides.
    var list: Io.Writer.Allocating = .init(a);
    var lerr: Io.Writer.Allocating = .init(a);
    const lp = try policy.apply(a, .{ .phase = .root, .memory = 1 << 30 }, .{ .mounts = &.{.{ .kind = .dir, .src = tmp, .dst = "#L", .access = .ro }} });
    const lcode = try guest(e, lp, null, &.{ "/usr/bin/busybox", "--list" }, .{ .out = &list.writer, .err = &lerr.writer });
    if (lcode != 0) {
        ctx.events.log("busybox --list exited {d}: {s}", .{ lcode, lerr.written() });
        cache.removeTree(io, tmp) catch {};
        return error.RootFailed;
    }
    var bin = try cwd.openDir(io, try std.fs.path.join(a, &.{ tmp, "usr", "bin" }), .{});
    defer bin.close(io);
    var it = std.mem.tokenizeAny(u8, list.written(), " \r\n\t");
    while (it.next()) |applet| {
        if (std.mem.indexOfScalar(u8, applet, '/') != null) continue;
        if (bin.statFile(io, applet, .{ .follow_symlinks = false })) |_| continue else |_| {}
        try bin.symLink(io, "busybox", applet, .{});
    }

    // /app, where the run starts, and mount points for the guest scripts'
    // trees: stack members rooted below the top need their parent.
    for ([_][]const u8{ "app", "h9x/src", "h9x/tools", "h9x/guest", "h9x/railpack", "h9x/ca" }) |d|
        try cwd.createDirPath(io, try std.fs.path.join(a, &.{ tmp, d }));
    cache.removeTree(io, dir) catch {};
    try Dir.rename(cwd, tmp, cwd, dir, io);
    ctx.events.emit(.{ .root = .{ .root = kind, .key = key, .state = .done } });
    return root;
}

test rootKey {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const k1 = try rootKey(a.allocator(), .amd64, &.{ "glibc", "busybox" });
    const k2 = try rootKey(a.allocator(), .arm64, &.{ "glibc", "busybox" });
    const k3 = try rootKey(a.allocator(), .amd64, &.{ "glibc", "busybox", "jq" });
    try std.testing.expectEqual(@as(usize, 16), k1.len);
    try std.testing.expect(!std.mem.eql(u8, k1, k2));
    try std.testing.expect(!std.mem.eql(u8, k1, k3));
}
