//! Starting h9 machines (design/prototype.md, "One program, two binaries"):
//! the one place h9x calls `h9.Machine`, so every machine gets the same
//! host settings.
//!
//! `Host` is what machines take from the host environment, read once per
//! process: the proxy, the CA bundle, DNS servers, the socket directory,
//! and the backend (`H9X_BACKEND`). `options` adds those to a machine's
//! options, and `run` starts a machine, runs one program, and ends it.
//!
//! Policy is compiled into `h9.Machine.Options` by policy.zig; this file
//! takes options as they are.

const std = @import("std");
const h9 = @import("h9");

pub const Options = h9.Machine.Options;
pub const Stdio = h9.Machine.Stdio;
pub const Status = h9.Status;

/// Where the guest finds the host's CA bundle, when `SSL_CERT_FILE` is set.
/// The roots have `/h9x` for the guest scripts' trees, and `ca` is a
/// member rooted under it.
pub const guest_ca_dir = "/h9x/ca";
pub const guest_ca_file = guest_ca_dir ++ "/ca.pem";

pub const Host = struct {
    /// For connections h9 makes itself.
    proxy: h9.Machine.Proxy = .{},
    /// HTTPS_PROXY, passed into the guest.
    https_proxy: ?[]const u8 = null,
    /// A directory holding a copy of `SSL_CERT_FILE` as `ca.pem`, mounted
    /// read-only at `guest_ca_dir`.
    ca_dir: ?[]const u8 = null,
    nameservers: []const []const u8 = &.{},
    tmp_dir: []const u8 = h9.Machine.default_tmp_dir,
    backend: h9.vmm.BackendKind = .auto,

    pub const InitError = error{ BadBackend, CaUnreadable, OutOfMemory };

    /// Reads the host's settings. `state_dir` is where the CA bundle's copy
    /// is kept (the cache), so the guest never sees the directory it came
    /// from.
    pub fn init(
        arena: std.mem.Allocator,
        io: std.Io,
        env: *const std.process.Environ.Map,
        state_dir: []const u8,
    ) InitError!Host {
        var h: Host = .{};
        h.proxy = .{
            .http = env.get("HTTP_PROXY") orelse env.get("http_proxy"),
            .https = env.get("HTTPS_PROXY") orelse env.get("https_proxy"),
            .no_proxy = env.get("NO_PROXY") orelse env.get("no_proxy") orelse "",
        };
        h.https_proxy = h.proxy.https;
        h.tmp_dir = env.get("TMPDIR") orelse h9.Machine.default_tmp_dir;
        if (env.get("H9X_BACKEND")) |b| {
            h.backend = std.meta.stringToEnum(h9.vmm.BackendKind, b) orelse return error.BadBackend;
        }
        h.nameservers = try hostNameservers(arena, io);
        if (env.get("SSL_CERT_FILE")) |f| if (f.len > 0) {
            h.ca_dir = copyCa(arena, io, f, state_dir) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CaUnreadable,
            };
        };
        return h;
    }

    /// `opts` with the host's settings added: the proxy and CA variables in
    /// the guest's environment, the CA's mount, the DNS servers, the socket
    /// directory, and the backend. The caller's env and mounts come first.
    pub fn options(h: Host, arena: std.mem.Allocator, opts: Options) error{OutOfMemory}!Options {
        var o = opts;
        o.backend = h.backend;
        o.proxy = h.proxy;
        o.tmp_dir = h.tmp_dir;
        if (o.nameservers.len == 0) o.nameservers = h.nameservers;

        var env: std.ArrayList(h9.EnvVar) = .empty;
        try env.appendSlice(arena, opts.env);
        if (h.https_proxy) |p| {
            try env.append(arena, .{ .name = "HTTPS_PROXY", .value = p });
            try env.append(arena, .{ .name = "https_proxy", .value = p });
        }
        var mounts: std.ArrayList(h9.Machine.Mount) = .empty;
        try mounts.appendSlice(arena, opts.mounts);
        if (h.ca_dir) |d| {
            try mounts.append(arena, .{ .kind = .dir, .src = d, .dst = "#L" ++ guest_ca_dir, .access = .ro });
            for ([_][]const u8{ "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS", "GIT_SSL_CAINFO" }) |n|
                try env.append(arena, .{ .name = n, .value = guest_ca_file });
        }
        o.env = env.items;
        o.mounts = mounts.items;
        return o;
    }
};

pub const RunError = h9.Machine.InitError || h9.Machine.RunError || error{OutOfMemory};

/// Starts a machine with `opts` and the host's settings, runs `argv` (a
/// guest path or name first), and ends the machine. On a setup failure,
/// `why` says what h9 said, for exit 125.
pub fn run(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    host: Host,
    opts: Options,
    argv: []const []const u8,
    why: *[]const u8,
) RunError!Status {
    std.debug.assert(argv.len > 0);
    why.* = "";
    var m = try h9.Machine.init(gpa, io, try host.options(arena, opts));
    defer m.deinit();
    return m.run(.{ .guest = argv[0] }, argv) catch |e| {
        why.* = try arena.dupe(u8, if (m.err_msg.len > 0) m.err_msg else @errorName(e));
        return e;
    };
}

/// The exit code for a program's status, as h9 maps it: an empty status
/// is 0, a number is itself, anything else is 1, and a timeout is 124.
pub fn exitCode(status: Status) u8 {
    switch (status) {
        .exited => |msg| {
            if (msg.len == 0) return 0;
            if (msg.len <= 3 and msg[0] != '0') {
                if (std.fmt.parseInt(u8, msg, 10)) |n| return n else |_| {}
            }
            return 1;
        },
        .killed => |msg| {
            if (std.mem.eql(u8, msg, "h9: timeout")) return 124;
            return 125;
        },
    }
}

/// Copies the CA bundle into `STATE/ca/SHA/ca.pem`, keyed by its contents,
/// and returns the directory.
fn copyCa(arena: std.mem.Allocator, io: std.Io, file: []const u8, state_dir: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const pem = try cwd.readFileAlloc(io, file, arena, .limited(16 << 20));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pem, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..8], .lower);
    const dir = try std.fs.path.join(arena, &.{ state_dir, "ca", &hex });
    try cwd.createDirPath(io, dir);
    const dst = try std.fs.path.join(arena, &.{ dir, "ca.pem" });
    try cwd.writeFile(io, .{ .sub_path = dst, .data = pem });
    return dir;
}

/// The host's DNS servers from /etc/resolv.conf, or Google's, as h9's CLI
/// does.
fn hostNameservers(arena: std.mem.Allocator, io: std.Io) error{OutOfMemory}![]const []const u8 {
    const fallback: []const []const u8 = &.{ "8.8.8.8", "8.8.4.4" };
    const text = std.Io.Dir.cwd().readFileAlloc(io, "/etc/resolv.conf", arena, .limited(64 << 10)) catch return fallback;
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        var words = std.mem.tokenizeAny(u8, l, " \t\r");
        const w = words.next() orelse continue;
        if (!std.mem.eql(u8, w, "nameserver")) continue;
        const addr = words.next() orelse continue;
        try out.append(arena, addr);
    }
    return if (out.items.len == 0) fallback else out.items;
}

test exitCode {
    try std.testing.expectEqual(@as(u8, 0), exitCode(.{ .exited = "" }));
    try std.testing.expectEqual(@as(u8, 3), exitCode(.{ .exited = "3" }));
    try std.testing.expectEqual(@as(u8, 1), exitCode(.{ .exited = "boom" }));
    try std.testing.expectEqual(@as(u8, 124), exitCode(.{ .killed = "h9: timeout" }));
}

test "Host.options adds the proxy and CA" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const h: Host = .{ .https_proxy = "http://proxy:3128", .ca_dir = "/cache/ca/0011", .nameservers = &.{"1.1.1.1"} };
    const o = try h.options(a.allocator(), .{
        .env = &.{.{ .name = "HOME", .value = "/root" }},
        .stdio = undefined,
    });
    try std.testing.expectEqualStrings("HOME", o.env[0].name);
    try std.testing.expectEqualStrings("HTTPS_PROXY", o.env[1].name);
    try std.testing.expectEqualStrings(guest_ca_file, o.env[3].value);
    try std.testing.expectEqualStrings("#L/h9x/ca", o.mounts[0].dst);
    try std.testing.expectEqualStrings("1.1.1.1", o.nameservers[0]);
}

// The test binary links h9's libkern, which calls back into Zig code that
// only `Machine.init` and `Machine.run` reach; reference them so it's there
// even when no test starts a machine.
test {
    _ = &h9.Machine.init;
    _ = &h9.Machine.run;
}
