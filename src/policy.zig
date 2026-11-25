//! Policy (design/prototype.md, "Policy"): policies as h9 plan lines, the
//! per-phase defaults, narrowing, the registry allowlist, and compiling a
//! policy into `h9.Machine.Options`.
//!
//! A policy is text in h9's plan format (hyper9's design/plan-format.md),
//! using these lines:
//!
//!   dir ro|rw|up SRC DST    a host directory, at DST (`#L` or a guest path)
//!   tmp DST                 an empty tree in memory
//!   net disable|outbound|enable
//!   netallow PATTERN...     h9 dial-string patterns, `tcp!HOST!PORT`;
//!                           `HOST:PORT` and a bare `HOST` (port 443) are
//!                           accepted and written as dial strings
//!   write ro|overlay|rw
//!   memory SIZE             `512M`, `4G`, or bytes
//!   pids N
//!   timeout DURATION        `30s`, `10m`, `2h`, or `1d`
//!   env NAME=VALUE
//!   cwd PATH
//!   run PROGRAM ARGS...
//!
//! with `#` comments, rc's single quotes (`''` is a quote inside them), and
//! a newline or `;` between lines. A line h9x doesn't know is an error with
//! its line number. `parse` reads text into a `Delta`, the lines given;
//! `apply` and `narrow` lay a `Delta` over a `Policy`; `print` writes a
//! `Policy` back as text that `parse` reads to the same policy, with
//! secrets' values hidden.
//!
//! When h9's `Machine.init` takes `.plan`, `compile` passes the text
//! through and goes away; the text doesn't change.

const std = @import("std");
const h9 = @import("h9");
const types = @import("types.zig");
const units = @import("units.zig");

pub const Policy = types.Policy;
pub const Phase = types.Phase;
pub const Trust = types.Trust;
pub const Net = types.Net;
pub const Mount = types.Mount;
pub const EnvVar = types.EnvVar;

/// What a parse, narrowing, or compile error was about, for the message
/// before exit 2.
pub const Diag = struct {
    /// 1-based, or 0 when the error isn't about a line.
    line: usize = 0,
    msg: []const u8 = "",
};

pub const ParseError = error{ Syntax, OutOfMemory };
pub const NarrowError = error{ Widens, OutOfMemory };

// ---------------------------------------------------------------- defaults

const GiB: u64 = 1 << 30;
const min = std.time.ns_per_min;

/// The default policy for a phase at a trust level, before mounts and the
/// plan's registries (design/prototype.md's table). `run` is the local
/// profile when trusted and the remote one when not; the other phases are
/// the same at both levels.
pub fn defaults(phase: Phase, trust: Trust) Policy {
    return switch (phase) {
        // Network to the source's host only, which the caller adds with
        // `allowHost`.
        .fetch => .{ .phase = phase, .trust = trust, .net = .outbound, .memory = 1 * GiB, .timeout_ns = 10 * min },
        .root => .{ .phase = phase, .trust = trust, .net = .outbound, .netallow = &root_hosts, .memory = 2 * GiB, .timeout_ns = 10 * min },
        .plan => .{ .phase = phase, .trust = trust, .net = .outbound, .netallow = &version_hosts, .memory = 2 * GiB, .timeout_ns = 2 * min },
        // Builds stay on `enable`, since Mix listens on 127.0.0.1 for its
        // lock and `outbound` refuses every listen. The allowlist is the
        // plan's registries: `registries`.
        .build => .{ .phase = phase, .trust = trust, .net = .enable, .netallow = &common_hosts, .memory = 4 * GiB, .timeout_ns = 30 * min },
        .run => switch (trust) {
            .trusted => .{ .phase = phase, .trust = trust, .net = .outbound, .write = .overlay, .memory = 1 * GiB },
            .untrusted => .{ .phase = phase, .trust = trust, .net = .disable, .write = .overlay, .memory = 1 * GiB, .timeout_ns = 10 * min },
        },
        .shell => .{ .phase = phase, .trust = trust, .net = .enable, .netallow = &common_hosts, .memory = 4 * GiB },
    };
}

// ---------------------------------------------------------------- registries

/// A host on port 443, as an h9 dial-string pattern.
fn https(comptime host: []const u8) []const u8 {
    return "tcp!" ++ host ++ "!443";
}

/// Every build's: GitHub for mise's downloads, mise's own hosts, and
/// Wolfi's.
const common_hosts = [_][]const u8{
    https("github.com"),
    https("api.github.com"),
    https("codeload.github.com"),
    https("objects.githubusercontent.com"),
    https("release-assets.githubusercontent.com"),
    https("raw.githubusercontent.com"),
    https("mise.jdx.dev"),
    https("mise-versions.jdx.dev"),
    https("packages.wolfi.dev"),
};

/// Where mise finds runtimes' versions and downloads the runtimes that
/// aren't on GitHub.
const runtime_hosts = [_][]const u8{
    https("nodejs.org"),
    https("go.dev"),
    https("dl.google.com"),
    https("static.rust-lang.org"),
    https("ziglang.org"),
    https("cache.ruby-lang.org"),
    https("builds.dotnet.microsoft.com"),
    https("dotnetcli.azureedge.net"),
    https("builds.hex.pm"),
    https("dl.deno.land"),
};

/// The plan phase's: version lookups only.
const version_hosts = common_hosts ++ runtime_hosts;

/// The root phase's: apk's repositories.
const root_hosts = [_][]const u8{
    https("dl-cdn.alpinelinux.org"),
    https("packages.wolfi.dev"),
};

/// Each ecosystem's package registries, by Railpack's provider name.
pub const registry_table = [_]struct { provider: []const u8, hosts: []const []const u8 }{
    .{ .provider = "node", .hosts = &.{ https("registry.npmjs.org"), https("registry.yarnpkg.com"), https("repo.yarnpkg.com") } },
    .{ .provider = "python", .hosts = &.{ https("pypi.org"), https("files.pythonhosted.org") } },
    .{ .provider = "ruby", .hosts = &.{ https("rubygems.org"), https("index.rubygems.org") } },
    .{ .provider = "golang", .hosts = &.{ https("proxy.golang.org"), https("sum.golang.org"), https("storage.googleapis.com") } },
    .{ .provider = "rust", .hosts = &.{ https("crates.io"), https("index.crates.io"), https("static.crates.io") } },
    .{ .provider = "dotnet", .hosts = &.{ https("api.nuget.org"), https("globalcdn.nuget.org") } },
    .{ .provider = "elixir", .hosts = &.{ https("hex.pm"), https("repo.hex.pm") } },
    .{ .provider = "gleam", .hosts = &.{ https("hex.pm"), https("repo.hex.pm") } },
    .{ .provider = "deno", .hosts = &.{ https("deno.land"), https("jsr.io"), https("registry.npmjs.org") } },
    .{ .provider = "php", .hosts = &.{ https("repo.packagist.org"), https("packagist.org"), https("getcomposer.org") } },
    .{ .provider = "java", .hosts = &.{ https("repo.maven.apache.org"), https("repo1.maven.org"), https("services.gradle.org"), https("downloads.gradle.org"), https("plugins.gradle.org") } },
};

/// `go` is `golang`, as Railpack's provider is named.
fn providerName(p: []const u8) []const u8 {
    if (std.mem.eql(u8, p, "go")) return "golang";
    return p;
}

/// The build and shell allowlist for a plan's providers: every build's
/// hosts, the runtimes' release hosts (the runtime layer installs them),
/// and each provider's registries. An unknown provider adds nothing.
pub fn registries(arena: std.mem.Allocator, providers: []const []const u8) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try appendNew(arena, &out, &common_hosts);
    try appendNew(arena, &out, &runtime_hosts);
    for (providers) |p| {
        const name = providerName(p);
        for (registry_table) |r| if (std.mem.eql(u8, r.provider, name)) try appendNew(arena, &out, r.hosts);
    }
    return out.items;
}

/// `p` with its allowlist set to the plan's registries, for the build and
/// shell phases. Other phases are returned as they are.
pub fn withRegistries(arena: std.mem.Allocator, p: Policy, providers: []const []const u8) error{OutOfMemory}!Policy {
    if (p.phase != .build and p.phase != .shell) return p;
    var out = p;
    out.netallow = try registries(arena, providers);
    return out;
}

/// `p` with `host` allowed on port 443, for a fetch machine: the source's
/// host only.
pub fn allowHost(arena: std.mem.Allocator, p: Policy, host: []const u8) error{OutOfMemory}!Policy {
    var out = p;
    var list: std.ArrayList([]const u8) = .empty;
    try list.appendSlice(arena, p.netallow);
    try appendNew(arena, &list, &.{try std.fmt.allocPrint(arena, "tcp!{s}!443", .{host})});
    out.netallow = list.items;
    return out;
}

fn appendNew(arena: std.mem.Allocator, list: *std.ArrayList([]const u8), items: []const []const u8) error{OutOfMemory}!void {
    outer: for (items) |it| {
        for (list.items) |have| if (std.mem.eql(u8, have, it)) continue :outer;
        try list.append(arena, it);
    }
}

// ---------------------------------------------------------------- deltas

/// The lines a piece of policy text gives, each null or empty when the
/// text doesn't have it: what `[run] policy`, a config value, or a flag
/// changes about a policy.
pub const Delta = struct {
    /// `dir` and `tmp` lines. Applied, a mount replaces the one with the
    /// same source and destination, or is added after the rest (mounts on
    /// one destination stack, as h9's do); narrowed, a `dir` must restate
    /// one already there, with the same or less access.
    mounts: []const Mount = &.{},
    net: ?Net = null,
    /// `netallow` lines: the allowlist replaced.
    netallow: ?[]const []const u8 = null,
    /// Patterns added to the allowlist (`build.netallow`). An allowlist
    /// that's empty allows any host already, so adding to it does nothing.
    netallow_add: []const []const u8 = &.{},
    write: ?Policy.Write = null,
    memory: ?u64 = null,
    pids: ?u32 = null,
    timeout_ns: ?u64 = null,
    /// Added, or replacing a variable of the same name.
    env: []const EnvVar = &.{},
    cwd: ?[]const u8 = null,
    run: ?[]const []const u8 = null,

    pub fn empty(d: Delta) bool {
        return d.mounts.len == 0 and d.net == null and d.netallow == null and d.netallow_add.len == 0 and
            d.write == null and d.memory == null and d.pids == null and d.timeout_ns == null and
            d.env.len == 0 and d.cwd == null and d.run == null;
    }
};

/// `by` laid over `base`, whatever it changes. For what the person sets
/// in their own config, and for a trusted source's.
pub fn apply(arena: std.mem.Allocator, base: Policy, by: Delta) error{OutOfMemory}!Policy {
    var p = base;
    if (by.mounts.len > 0) {
        var list: std.ArrayList(Mount) = .empty;
        try list.appendSlice(arena, base.mounts);
        for (by.mounts) |m| {
            for (list.items) |*have| {
                if (have.kind == m.kind and std.mem.eql(u8, have.dst, m.dst) and std.mem.eql(u8, have.src, m.src)) {
                    have.* = m;
                    break;
                }
            } else try list.append(arena, m);
        }
        p.mounts = list.items;
    }
    if (by.net) |n| p.net = n;
    if (by.netallow) |na| p.netallow = na;
    if (by.netallow_add.len > 0 and p.netallow.len > 0) {
        var list: std.ArrayList([]const u8) = .empty;
        try list.appendSlice(arena, p.netallow);
        try appendNew(arena, &list, by.netallow_add);
        p.netallow = list.items;
    }
    if (by.write) |w| p.write = w;
    if (by.memory) |v| p.memory = v;
    if (by.pids) |v| p.pids = v;
    if (by.timeout_ns) |v| p.timeout_ns = v;
    if (by.env.len > 0) p.env = try mergeEnv(arena, base.env, by.env);
    if (by.cwd) |c| p.cwd = c;
    if (by.run) |r| p.run = r;
    return p;
}

/// `base` narrowed by `by`; error.Widens, with `diag` saying which line,
/// if `by` would give the guest anything `base` doesn't (exit 2). `env`,
/// `cwd`, `run`, and `tmp` lines change what runs, not what it can reach,
/// so they're taken as they are.
pub fn narrow(arena: std.mem.Allocator, base: Policy, by: Delta, diag: *Diag) NarrowError!Policy {
    for (by.mounts) |m| {
        if (m.kind == .tmp) continue;
        const have = for (base.mounts) |b| {
            if (b.kind == .dir and std.mem.eql(u8, b.dst, m.dst) and std.mem.eql(u8, b.src, m.src)) break b;
        } else return widens(arena, diag, "dir {t} {s} {s}: not in the policy it narrows", .{ m.access, m.src, m.dst });
        if (!accessNarrows(m.access, have.access))
            return widens(arena, diag, "dir {t} {s} {s}: the policy has it {t}", .{ m.access, m.src, m.dst, have.access });
    }
    if (by.net) |n| if (!n.narrows(base.net))
        return widens(arena, diag, "net {t}: the policy has net {t}", .{ n, base.net });
    if (by.netallow) |na| {
        if (base.netallow.len > 0) for (na) |pat| {
            if (!covered(pat, base.netallow))
                return widens(arena, diag, "netallow {s}: not in the policy's allowlist", .{pat});
        };
    }
    if (base.netallow.len > 0) for (by.netallow_add) |pat| {
        if (!covered(pat, base.netallow))
            return widens(arena, diag, "netallow {s}: not in the policy's allowlist", .{pat});
    };
    if (by.write) |w| if (@intFromEnum(w) > @intFromEnum(base.write orelse .overlay))
        return widens(arena, diag, "write {t}: the policy has write {t}", .{ w, base.write orelse .overlay });
    if (by.memory) |v| if (base.memory) |b| if (v > b)
        return widens(arena, diag, "memory {f}: the policy has memory {f}", .{ fmtSize(v), fmtSize(b) });
    if (by.pids) |v| if (base.pids) |b| if (v > b)
        return widens(arena, diag, "pids {d}: the policy has pids {d}", .{ v, b });
    if (by.timeout_ns) |v| if (base.timeout_ns) |b| if (v > b)
        return widens(arena, diag, "timeout {f}: the policy has timeout {f}", .{ fmtDuration(v), fmtDuration(b) });
    return apply(arena, base, by);
}

fn widens(arena: std.mem.Allocator, diag: *Diag, comptime fmt: []const u8, args: anytype) NarrowError {
    diag.* = .{ .msg = try std.fmt.allocPrint(arena, fmt ++ " (widening needs --trust, or an edit to your own config)", args) };
    return error.Widens;
}

/// Whether access `a` gives no more than `b`: `ro` narrows anything, and
/// `up` and `rw` narrow only themselves.
fn accessNarrows(a: Mount.Access, b: Mount.Access) bool {
    return a == b or a == .ro;
}

/// Whether `pat` allows nothing that one of `allow` doesn't. Patterns that
/// don't parse are covered only by the same text.
pub fn covered(pat: []const u8, allow: []const []const u8) bool {
    var why: []const u8 = "";
    const p = h9.policy.parseNetPattern(pat, &why) catch {
        for (allow) |a| if (std.mem.eql(u8, a, pat)) return true;
        return false;
    };
    for (allow) |a| {
        const b = h9.policy.parseNetPattern(a, &why) catch continue;
        if (patternCovers(b, p)) return true;
    }
    return false;
}

fn patternCovers(b: h9.policy.NetPattern, p: h9.policy.NetPattern) bool {
    if (b.proto) |bp| if (p.proto == null or p.proto.? != bp) return false;
    if (p.port_lo < b.port_lo or p.port_hi > b.port_hi) return false;
    return switch (b.host) {
        .any => true,
        .name => |bn| switch (p.host) {
            .name => |pn| std.ascii.eqlIgnoreCase(bn, pn),
            else => false,
        },
        .suffix => |bs| switch (p.host) {
            .name => |pn| pn.len > bs.len and std.ascii.eqlIgnoreCase(pn[pn.len - bs.len ..], bs),
            .suffix => |ps| ps.len >= bs.len and std.ascii.eqlIgnoreCase(ps[ps.len - bs.len ..], bs),
            else => false,
        },
        .cidr => |bc| switch (p.host) {
            .cidr => |pc| pc.v4 == bc.v4 and pc.bits >= bc.bits and prefixEql(&bc.addr, &pc.addr, bc.bits),
            else => false,
        },
    };
}

fn prefixEql(a: *const [16]u8, b: *const [16]u8, bits: u8) bool {
    const whole = bits / 8;
    if (!std.mem.eql(u8, a[0..whole], b[0..whole])) return false;
    const rest: u3 = @intCast(bits % 8);
    if (rest == 0) return true;
    const mask: u8 = @as(u8, 0xff) << @intCast(8 - @as(u4, rest));
    return a[whole] & mask == b[whole] & mask;
}

fn mergeEnv(arena: std.mem.Allocator, base: []const EnvVar, add: []const EnvVar) error{OutOfMemory}![]const EnvVar {
    var list: std.ArrayList(EnvVar) = .empty;
    try list.appendSlice(arena, base);
    for (add) |e| {
        for (list.items) |*have| {
            if (std.mem.eql(u8, have.name, e.name)) {
                have.* = e;
                break;
            }
        } else try list.append(arena, e);
    }
    return list.items;
}

// ---------------------------------------------------------------- parsing

/// A `netallow` pattern as h9 takes it: a dial string as it is, `HOST:PORT`
/// as `tcp!HOST!PORT`, and a bare `HOST` as `tcp!HOST!443`. Null if h9
/// wouldn't take the result, with `why` saying why.
pub fn normalizePattern(arena: std.mem.Allocator, text: []const u8, why: *[]const u8) error{OutOfMemory}!?[]const u8 {
    const out = if (std.mem.indexOfScalar(u8, text, '!') != null)
        text
    else if (std.mem.lastIndexOfScalar(u8, text, ':')) |c|
        try std.fmt.allocPrint(arena, "tcp!{s}!{s}", .{ text[0..c], text[c + 1 ..] })
    else
        try std.fmt.allocPrint(arena, "tcp!{s}!443", .{text});
    _ = h9.policy.parseNetPattern(out, why) catch return null;
    return out;
}

/// Reads policy text into the lines it gives. On error.Syntax, `diag`
/// has the line and what's wrong.
pub fn parse(arena: std.mem.Allocator, text: []const u8, diag: *Diag) ParseError!Delta {
    var d: Delta = .{};
    var mounts: std.ArrayList(Mount) = .empty;
    var env: std.ArrayList(EnvVar) = .empty;
    var netallow: std.ArrayList([]const u8) = .empty;
    var any_netallow = false;

    var lx: Lexer = .{ .text = text };
    while (true) {
        const words = lx.nextLine(arena) catch |e| switch (e) {
            error.Unterminated => return syntax(arena, diag, lx.line, "a quote isn't closed", .{}),
            error.OutOfMemory => return error.OutOfMemory,
        } orelse break;
        if (words.len == 0) continue;
        const ln = lx.start_line;
        const w = words[0];
        const args = words[1..];
        if (eql(w, "dir")) {
            if (args.len != 3) return syntax(arena, diag, ln, "want dir ro|rw|up SRC DST", .{});
            const access = std.meta.stringToEnum(Mount.Access, args[0]) orelse
                return syntax(arena, diag, ln, "dir {s}: the access is ro, rw, or up", .{args[0]});
            try checkDst(arena, diag, ln, args[2]);
            if (args[1].len == 0) return syntax(arena, diag, ln, "dir: the source is empty", .{});
            try mounts.append(arena, .{ .kind = .dir, .access = access, .src = args[1], .dst = args[2] });
        } else if (eql(w, "tmp")) {
            if (args.len != 1) return syntax(arena, diag, ln, "want tmp DST", .{});
            try checkDst(arena, diag, ln, args[0]);
            try mounts.append(arena, .{ .kind = .tmp, .dst = args[0], .access = .rw });
        } else if (eql(w, "net")) {
            if (args.len != 1) return syntax(arena, diag, ln, "want net disable|outbound|enable", .{});
            d.net = units.parseNet(args[0]) orelse return syntax(arena, diag, ln, "net {s}: want disable, outbound, or enable", .{args[0]});
        } else if (eql(w, "netallow")) {
            if (args.len == 0) return syntax(arena, diag, ln, "want netallow PATTERN...", .{});
            any_netallow = true;
            for (args) |a| {
                var why: []const u8 = "";
                const pat = try normalizePattern(arena, a, &why) orelse
                    return syntax(arena, diag, ln, "netallow {s}: {s}", .{ a, why });
                try appendNew(arena, &netallow, &.{pat});
            }
        } else if (eql(w, "write")) {
            if (args.len != 1) return syntax(arena, diag, ln, "want write ro|overlay|rw", .{});
            d.write = std.meta.stringToEnum(Policy.Write, args[0]) orelse
                return syntax(arena, diag, ln, "write {s}: want ro, overlay, or rw", .{args[0]});
        } else if (eql(w, "memory")) {
            if (args.len != 1) return syntax(arena, diag, ln, "want memory SIZE", .{});
            d.memory = units.parseSize(args[0]) orelse return syntax(arena, diag, ln, "memory {s}: not a size, such as 512M or 4G", .{args[0]});
        } else if (eql(w, "pids")) {
            if (args.len != 1) return syntax(arena, diag, ln, "want pids N", .{});
            d.pids = std.fmt.parseInt(u32, args[0], 10) catch return syntax(arena, diag, ln, "pids {s}: not a number", .{args[0]});
        } else if (eql(w, "timeout")) {
            if (args.len != 1) return syntax(arena, diag, ln, "want timeout DURATION", .{});
            d.timeout_ns = units.parseDuration(args[0]) orelse return syntax(arena, diag, ln, "timeout {s}: not a duration, such as 30s, 10m, or 2h", .{args[0]});
        } else if (eql(w, "env")) {
            if (args.len != 1) return syntax(arena, diag, ln, "want env NAME=VALUE", .{});
            const eq = std.mem.indexOfScalar(u8, args[0], '=') orelse return syntax(arena, diag, ln, "env {s}: want NAME=VALUE", .{args[0]});
            if (!validName(args[0][0..eq])) return syntax(arena, diag, ln, "env {s}: not a variable name", .{args[0][0..eq]});
            const e: EnvVar = .{ .name = args[0][0..eq], .value = args[0][eq + 1 ..] };
            for (env.items) |*have| {
                if (eql(have.name, e.name)) {
                    have.* = e;
                    break;
                }
            } else try env.append(arena, e);
        } else if (eql(w, "cwd")) {
            if (args.len != 1 or args[0].len == 0 or args[0][0] != '/') return syntax(arena, diag, ln, "want cwd PATH, with PATH absolute", .{});
            d.cwd = args[0];
        } else if (eql(w, "run")) {
            if (args.len == 0) return syntax(arena, diag, ln, "want run PROGRAM ARGS...", .{});
            d.run = args;
        } else {
            return syntax(arena, diag, ln, "unknown line {s}", .{w});
        }
    }
    d.mounts = mounts.items;
    d.env = env.items;
    if (any_netallow) d.netallow = netallow.items;
    return d;
}

/// A whole policy from text: `parse` applied to `defaults`-free base.
pub fn parsePolicy(arena: std.mem.Allocator, phase: Phase, trust: Trust, text: []const u8, diag: *Diag) ParseError!Policy {
    const d = try parse(arena, text, diag);
    return apply(arena, .{ .phase = phase, .trust = trust }, d);
}

fn checkDst(arena: std.mem.Allocator, diag: *Diag, ln: usize, dst: []const u8) ParseError!void {
    if (eql(dst, "#L") or std.mem.startsWith(u8, dst, "#L/") or (dst.len > 0 and dst[0] == '/')) return;
    return syntax(arena, diag, ln, "{s}: the destination is #L or an absolute path", .{dst});
}

fn syntax(arena: std.mem.Allocator, diag: *Diag, line: usize, comptime fmt: []const u8, args: anytype) ParseError {
    diag.* = .{ .line = line, .msg = try std.fmt.allocPrint(arena, fmt, args) };
    return error.Syntax;
}

pub fn validName(n: []const u8) bool {
    if (n.len == 0 or std.ascii.isDigit(n[0])) return false;
    for (n) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Words, lines, comments, and rc quoting.
const Lexer = struct {
    text: []const u8,
    pos: usize = 0,
    /// The line `pos` is on, 1-based.
    line: usize = 1,
    /// The line the last `nextLine` started on.
    start_line: usize = 1,

    /// The next line's words, or null at the end. An empty slice is a
    /// blank line.
    fn nextLine(lx: *Lexer, arena: std.mem.Allocator) error{ Unterminated, OutOfMemory }!?[]const []const u8 {
        if (lx.pos >= lx.text.len) return null;
        var words: std.ArrayList([]const u8) = .empty;
        lx.start_line = lx.line;
        while (lx.pos < lx.text.len) {
            const c = lx.text[lx.pos];
            switch (c) {
                '\n' => {
                    lx.pos += 1;
                    lx.line += 1;
                    break;
                },
                ';' => {
                    lx.pos += 1;
                    break;
                },
                ' ', '\t', '\r' => lx.pos += 1,
                // A `#` that starts a word is a comment, to the end of the
                // line or a `;`, as h9's namespace files have it.
                '#' => while (lx.pos < lx.text.len and lx.text[lx.pos] != '\n' and lx.text[lx.pos] != ';') {
                    lx.pos += 1;
                },
                else => try words.append(arena, try lx.word(arena)),
            }
        }
        return words.items;
    }

    fn word(lx: *Lexer, arena: std.mem.Allocator) error{ Unterminated, OutOfMemory }![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        while (lx.pos < lx.text.len) {
            const c = lx.text[lx.pos];
            switch (c) {
                ' ', '\t', '\r', '\n', ';' => break,
                '\'' => {
                    lx.pos += 1;
                    while (true) {
                        if (lx.pos >= lx.text.len or lx.text[lx.pos] == '\n') return error.Unterminated;
                        const q = lx.text[lx.pos];
                        lx.pos += 1;
                        if (q == '\'') {
                            if (lx.pos < lx.text.len and lx.text[lx.pos] == '\'') {
                                try out.append(arena, '\'');
                                lx.pos += 1;
                                continue;
                            }
                            break;
                        }
                        try out.append(arena, q);
                    }
                },
                else => {
                    try out.append(arena, c);
                    lx.pos += 1;
                },
            }
        }
        return out.items;
    }
};

// ---------------------------------------------------------------- printing

/// The policy as plan text, one line each, with secrets' values hidden:
/// what `--print` shows and `pack.json` seals. `parse` reads it back to
/// the same policy, but for secrets.
pub fn print(p: Policy, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (p.mounts) |m| switch (m.kind) {
        .dir => {
            try w.print("dir {t} ", .{m.access});
            try quote(w, m.src);
            try w.writeByte(' ');
            try quote(w, m.dst);
            try w.writeByte('\n');
        },
        .tmp => {
            try w.writeAll("tmp ");
            try quote(w, m.dst);
            try w.writeByte('\n');
        },
    };
    try w.print("net {t}\n", .{p.net});
    if (p.net != .disable and p.netallow.len > 0) {
        for (p.netallow) |pat| {
            try w.writeAll("netallow ");
            try quote(w, pat);
            try w.writeByte('\n');
        }
    }
    if (p.write) |wr| try w.print("write {t}\n", .{wr});
    if (p.memory) |v| try w.print("memory {f}\n", .{fmtSize(v)});
    if (p.pids) |v| try w.print("pids {d}\n", .{v});
    if (p.timeout_ns) |v| try w.print("timeout {f}\n", .{fmtDuration(v)});
    for (p.env) |e| {
        try w.writeAll("env ");
        if (e.secret) {
            try w.print("{s}=\u{2026}", .{e.name});
        } else {
            const kv = KeyValue{ .name = e.name, .value = e.value };
            try quote(w, kv);
        }
        try w.writeByte('\n');
    }
    if (p.cwd) |c| {
        try w.writeAll("cwd ");
        try quote(w, c);
        try w.writeByte('\n');
    }
    if (p.run.len > 0) {
        try w.writeAll("run");
        for (p.run) |a| {
            try w.writeByte(' ');
            try quote(w, a);
        }
        try w.writeByte('\n');
    }
}

/// `print`'s text, allocated, for a `policy` event.
pub fn toText(arena: std.mem.Allocator, p: Policy) error{OutOfMemory}![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    print(p, &aw.writer) catch return error.OutOfMemory;
    return aw.written();
}

const KeyValue = struct { name: []const u8, value: []const u8 };

/// A word, quoted as rc quotes it when it needs to be.
fn quote(w: *std.Io.Writer, v: anytype) std.Io.Writer.Error!void {
    const parts: []const []const u8 = if (@TypeOf(v) == KeyValue) &.{ v.name, "=", v.value } else &.{v};
    var needs = false;
    var total: usize = 0;
    for (parts) |s| {
        total += s.len;
        for (s) |c| switch (c) {
            ' ', '\t', '\r', '\n', ';', '#', '\'' => needs = true,
            else => {},
        };
    }
    if (total == 0) needs = true;
    if (!needs) {
        for (parts) |s| try w.writeAll(s);
        return;
    }
    try w.writeByte('\'');
    for (parts) |s| for (s) |c| {
        if (c == '\'') try w.writeByte('\'');
        try w.writeByte(c);
    };
    try w.writeByte('\'');
}

const Size = struct {
    bytes: u64,
    pub fn format(s: Size, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const b = s.bytes;
        if (b != 0 and b % (1 << 30) == 0) return w.print("{d}G", .{b >> 30});
        if (b != 0 and b % (1 << 20) == 0) return w.print("{d}M", .{b >> 20});
        if (b != 0 and b % (1 << 10) == 0) return w.print("{d}K", .{b >> 10});
        return w.print("{d}", .{b});
    }
};

/// A size as `memory` takes it, in the largest exact unit.
pub fn fmtSize(bytes: u64) Size {
    return .{ .bytes = bytes };
}

const Duration = struct {
    ns: u64,
    pub fn format(d: Duration, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const n = d.ns;
        // `timeout` takes whole seconds; round anything finer up.
        const s = std.math.divCeil(u64, n, std.time.ns_per_s) catch unreachable;
        if (s != 0 and s % std.time.s_per_day == 0) return w.print("{d}d", .{s / std.time.s_per_day});
        if (s != 0 and s % std.time.s_per_hour == 0) return w.print("{d}h", .{s / std.time.s_per_hour});
        if (s != 0 and s % std.time.s_per_min == 0) return w.print("{d}m", .{s / std.time.s_per_min});
        return w.print("{d}s", .{s});
    }
};

/// A duration as `timeout` takes it, in the largest exact unit.
pub fn fmtDuration(ns: u64) Duration {
    return .{ .ns = ns };
}

// ---------------------------------------------------------------- compiling

pub const CompileError = error{ Conflict, OutOfMemory };

/// The policy as `h9.Machine.Options`, without `stdio`, which the caller
/// sets, and without `cwd` and `run`, which `command` puts in the argv,
/// since h9's options have no guest working directory. A mount's guest
/// path (`/app`) goes under `#L`. error.Conflict, with `diag`, for a
/// policy h9 would refuse.
pub fn compile(arena: std.mem.Allocator, p: Policy, diag: *Diag) CompileError!h9.Machine.Options {
    var mounts = try arena.alloc(h9.Machine.Mount, p.mounts.len);
    for (p.mounts, 0..) |m, i| {
        const dst = if (m.dst.len > 0 and m.dst[0] == '/')
            try std.mem.concat(arena, u8, &.{ "#L", m.dst })
        else
            m.dst;
        mounts[i] = switch (m.kind) {
            .dir => .{ .kind = .dir, .src = m.src, .dst = dst, .access = switch (m.access) {
                .ro => .ro,
                .rw => .rw,
                .up => .up,
            } },
            .tmp => .{ .kind = .tmp, .dst = dst },
        };
    }
    var net_allow: []const []const u8 = &.{};
    if (p.net != .disable) {
        const list = try arena.alloc([]const u8, p.netallow.len);
        for (p.netallow, list) |pat, *out| {
            var why: []const u8 = "";
            out.* = try normalizePattern(arena, pat, &why) orelse {
                diag.* = .{ .msg = try std.fmt.allocPrint(arena, "netallow {s}: {s}", .{ pat, why }) };
                return error.Conflict;
            };
        }
        net_allow = list;
    }
    if (p.write == .ro) for (p.mounts) |m| if (m.kind == .dir and m.access != .ro) {
        diag.* = .{ .msg = try std.fmt.allocPrint(arena, "write ro conflicts with dir {t} {s} {s}", .{ m.access, m.src, m.dst }) };
        return error.Conflict;
    };
    const env = try arena.alloc(h9.EnvVar, p.env.len);
    for (p.env, env) |e, *out| out.* = .{ .name = e.name, .value = e.value };

    return .{
        .mounts = mounts,
        .env = env,
        .policy = .{
            .net = switch (p.net) {
                .disable => .disable,
                .outbound => .outbound,
                .enable => .enable,
            },
            .net_allow = net_allow,
            .write = if (p.write) |w| switch (w) {
                .ro => .none,
                .overlay => .overlay,
                .rw => .scope,
            } else null,
            .memory = p.memory,
            .pids = p.pids,
            .timeout_ns = p.timeout_ns,
        },
        .stdio = undefined,
    };
}

/// The argv to run for `p`: `argv`, or the policy's `run` if `argv` is
/// empty, in the policy's `cwd` when it has one (through `/bin/sh`, which
/// every h9x root has). Null if there's nothing to run.
pub fn command(arena: std.mem.Allocator, p: Policy, argv: []const []const u8) error{OutOfMemory}!?[]const []const u8 {
    const prog = if (argv.len > 0) argv else p.run;
    if (prog.len == 0) return null;
    const cwd = p.cwd orelse return prog;
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(arena, &.{ "/bin/sh", "-c", "cd \"$0\" && exec \"$@\"", cwd });
    try out.appendSlice(arena, prog);
    return out.items;
}

// ---------------------------------------------------------------- tests

const t = std.testing;

fn printed(arena: std.mem.Allocator, p: Policy) ![]const u8 {
    return toText(arena, p);
}

test "parse and print round-trip" {
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const src =
        \\# a run policy
        \\dir ro /cache/roots/base '#L'
        \\dir up '/home/me/my app/.tmp' '#L/app'; tmp /tmp
        \\net outbound
        \\netallow registry.npmjs.org *.example.com:8080 udp!10.0.0.53!53
        \\write overlay
        \\memory 512M
        \\pids 64
        \\timeout 90s
        \\env HOME=/root
        \\env 'GREETING=it''s here'
        \\cwd /app
        \\run /bin/sh -c 'node server.js'
        \\
    ;
    var diag: Diag = .{};
    const p = try parsePolicy(ar, .run, .trusted, src, &diag);
    try t.expectEqual(@as(usize, 3), p.mounts.len);
    try t.expectEqualStrings("/home/me/my app/.tmp", p.mounts[1].src);
    try t.expectEqual(Mount.Access.up, p.mounts[1].access);
    try t.expectEqual(Mount.Kind.tmp, p.mounts[2].kind);
    try t.expectEqualStrings("tcp!registry.npmjs.org!443", p.netallow[0]);
    try t.expectEqualStrings("tcp!*.example.com!8080", p.netallow[1]);
    try t.expectEqual(@as(?u64, 512 << 20), p.memory);
    try t.expectEqual(@as(?u64, 90 * std.time.ns_per_s), p.timeout_ns);
    try t.expectEqualStrings("it's here", p.env[1].value);
    try t.expectEqualStrings("node server.js", p.run[2]);

    const out = try printed(ar, p);
    try t.expectEqualStrings(
        \\dir ro /cache/roots/base '#L'
        \\dir up '/home/me/my app/.tmp' '#L/app'
        \\tmp /tmp
        \\net outbound
        \\netallow tcp!registry.npmjs.org!443
        \\netallow tcp!*.example.com!8080
        \\netallow udp!10.0.0.53!53
        \\write overlay
        \\memory 512M
        \\pids 64
        \\timeout 90s
        \\env HOME=/root
        \\env 'GREETING=it''s here'
        \\cwd /app
        \\run /bin/sh -c 'node server.js'
        \\
    , out);
    // And back.
    const again = try parsePolicy(ar, .run, .trusted, out, &diag);
    try t.expectEqualStrings(out, try printed(ar, again));
}

test "an unknown or bad line is an error with its line number" {
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    var diag: Diag = .{};
    try t.expectError(error.Syntax, parse(a.allocator(), "net enable\n\ndeny read ~/.ssh\n", &diag));
    try t.expectEqual(@as(usize, 3), diag.line);
    try t.expectEqualStrings("unknown line deny", diag.msg);
    try t.expectError(error.Syntax, parse(a.allocator(), "memory lots", &diag));
    try t.expectEqual(@as(usize, 1), diag.line);
    try t.expectError(error.Syntax, parse(a.allocator(), "net enable\nenv 'A=b\n", &diag));
    try t.expectError(error.Syntax, parse(a.allocator(), "netallow tcp!x", &diag));
    try t.expectError(error.Syntax, parse(a.allocator(), "dir ro /a app", &diag));
    try t.expectError(error.Syntax, parse(a.allocator(), "env 1X=2", &diag));
}

test "secrets print without their values" {
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    const p: Policy = .{ .phase = .build, .env = &.{
        .{ .name = "HOME", .value = "/root" },
        .{ .name = "NPM_TOKEN", .value = "s3cret", .secret = true },
    } };
    const out = try printed(a.allocator(), p);
    try t.expect(std.mem.indexOf(u8, out, "s3cret") == null);
    try t.expect(std.mem.indexOf(u8, out, "env NPM_TOKEN=\u{2026}\n") != null);
}

test "defaults follow the design's table" {
    const pl = defaults(.plan, .trusted);
    try t.expectEqual(Net.outbound, pl.net);
    try t.expectEqual(@as(?u64, 2 << 30), pl.memory);
    try t.expectEqual(@as(?u64, 2 * min), pl.timeout_ns);
    const b = defaults(.build, .untrusted);
    try t.expectEqual(Net.enable, b.net);
    try t.expectEqual(@as(?u64, 30 * min), b.timeout_ns);
    try t.expect(b.netallow.len > 0);
    const rl = defaults(.run, .trusted);
    try t.expectEqual(Net.outbound, rl.net);
    try t.expectEqual(@as(?u64, null), rl.timeout_ns);
    try t.expectEqual(@as(usize, 0), rl.netallow.len);
    const rr = defaults(.run, .untrusted);
    try t.expectEqual(Net.disable, rr.net);
    try t.expectEqual(@as(?u64, 10 * min), rr.timeout_ns);
    try t.expectEqual(@as(?u64, 1 << 30), rr.memory);
    try t.expectEqual(@as(?u64, null), defaults(.shell, .trusted).timeout_ns);
}

test "registries for a plan's providers" {
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    const r = try registries(a.allocator(), &.{ "node", "go" });
    try t.expect(covered("tcp!registry.npmjs.org!443", r));
    try t.expect(covered("tcp!proxy.golang.org!443", r));
    try t.expect(covered("tcp!packages.wolfi.dev!443", r));
    try t.expect(covered("tcp!github.com!443", r));
    try t.expect(!covered("tcp!pypi.org!443", r));
    // Every pattern in the table is one h9 takes.
    var why: []const u8 = "";
    for (registry_table) |e| for (e.hosts) |h| {
        _ = try h9.policy.parseNetPattern(h, &why);
    };
    for (version_hosts) |h| _ = try h9.policy.parseNetPattern(h, &why);
    // Only build and shell take them.
    const b = try withRegistries(a.allocator(), defaults(.build, .trusted), &.{"python"});
    try t.expect(covered("tcp!files.pythonhosted.org!443", b.netallow));
    const run = try withRegistries(a.allocator(), defaults(.run, .trusted), &.{"python"});
    try t.expectEqual(@as(usize, 0), run.netallow.len);
}

test "allowHost for a fetch" {
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    const f = try allowHost(a.allocator(), defaults(.fetch, .untrusted), "github.com");
    try t.expectEqual(@as(usize, 1), f.netallow.len);
    try t.expectEqualStrings("tcp!github.com!443", f.netallow[0]);
}

test "narrowing takes what's narrower and refuses what's wider" {
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    const ar = a.allocator();
    var diag: Diag = .{};
    var base = defaults(.build, .untrusted);
    base.mounts = &.{
        .{ .kind = .dir, .src = "/src", .dst = "#L/app", .access = .rw },
        .{ .kind = .dir, .src = "/cache/builder", .dst = "#L", .access = .ro },
    };

    // Narrower: less memory, net outbound, a host already allowed, a
    // writable mount made read-only, and a tmp.
    const n = try narrow(ar, base, try parse(ar,
        \\memory 2G
        \\net outbound
        \\netallow github.com
        \\dir ro /src '#L/app'
        \\tmp /scratch
        \\env FOO=bar
    , &diag), &diag);
    try t.expectEqual(@as(?u64, 2 << 30), n.memory);
    try t.expectEqual(Net.outbound, n.net);
    try t.expectEqual(@as(usize, 1), n.netallow.len);
    try t.expectEqual(Mount.Access.ro, n.mounts[0].access);
    try t.expectEqual(@as(usize, 3), n.mounts.len);

    const cases = [_][]const u8{
        "memory 8G",
        "timeout 1h",
        "netallow evil.example.com",
        "dir rw /home/me/.ssh /root/.ssh",
    };
    for (cases) |c| {
        try t.expectError(error.Widens, narrow(ar, base, try parse(ar, c, &diag), &diag));
        try t.expect(diag.msg.len > 0);
    }
    // net enable over outbound widens.
    try t.expectError(error.Widens, narrow(ar, n, .{ .net = .enable }, &diag));
    // Write: rw over the default overlay widens; ro narrows.
    try t.expectError(error.Widens, narrow(ar, base, .{ .write = .rw }, &diag));
    _ = try narrow(ar, base, .{ .write = .ro }, &diag);
    // Adding a host to an allowlist widens it; to no allowlist, it's moot.
    try t.expectError(error.Widens, narrow(ar, base, .{ .netallow_add = &.{"tcp!api.example.com!443"} }, &diag));
    const local = defaults(.run, .trusted);
    const moot = try narrow(ar, local, .{ .netallow_add = &.{"tcp!api.example.com!443"} }, &diag);
    try t.expectEqual(@as(usize, 0), moot.netallow.len);
    // Any limit narrows no limit.
    const lim = try narrow(ar, local, .{ .timeout_ns = 5 * min, .pids = 10 }, &diag);
    try t.expectEqual(@as(?u64, 5 * min), lim.timeout_ns);
    // Narrowing an open allowlist sets one.
    const one = try narrow(ar, local, .{ .netallow = &.{"tcp!api.example.com!443"} }, &diag);
    try t.expectEqual(@as(usize, 1), one.netallow.len);
}

test "apply adds what narrow refuses" {
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const base = defaults(.build, .trusted);
    const p = try apply(ar, base, .{ .memory = 8 << 30, .netallow_add = &.{"tcp!api.example.com!443"} });
    try t.expectEqual(@as(?u64, 8 << 30), p.memory);
    try t.expect(covered("tcp!api.example.com!443", p.netallow));
    try t.expectEqual(base.netallow.len + 1, p.netallow.len);
}

test "pattern coverage" {
    try t.expect(covered("tcp!a.example.com!443", &.{"tcp!*.example.com!443"}));
    try t.expect(covered("tcp!*.b.example.com!443", &.{"tcp!*.example.com!443"}));
    try t.expect(!covered("tcp!example.com!443", &.{"tcp!*.example.com!443"}));
    try t.expect(covered("tcp!x.org!8080", &.{"tcp!x.org!8000-8099"}));
    try t.expect(!covered("tcp!x.org!80", &.{"tcp!x.org!443"}));
    try t.expect(!covered("net!x.org!443", &.{"tcp!x.org!443"}));
    try t.expect(covered("tcp!x.org!443", &.{"net!x.org!*"}));
    try t.expect(covered("tcp!10.1.2.0/24!22", &.{"tcp!10.0.0.0/8!*"}));
    try t.expect(!covered("tcp!11.0.0.0/24!22", &.{"tcp!10.0.0.0/8!*"}));
    try t.expect(!covered("tcp!10.0.0.0/7!22", &.{"tcp!10.0.0.0/8!*"}));
    try t.expect(covered("tcp!anything!1", &.{"*!*!*"}));
}

test "compile to Machine.Options" {
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    const ar = a.allocator();
    var diag: Diag = .{};
    const p = try parsePolicy(ar, .build, .trusted,
        \\dir ro /cache/builder '#L'
        \\dir up /out/layers/deps.tmp '#L'
        \\dir rw /out/cache /cache
        \\tmp /tmp
        \\net enable
        \\netallow registry.npmjs.org
        \\memory 4G
        \\timeout 30m
        \\env HOME=/root
        \\cwd /app
    , &diag);
    const o = try compile(ar, p, &diag);
    try t.expectEqual(@as(usize, 4), o.mounts.len);
    try t.expectEqualStrings("#L", o.mounts[0].dst);
    try t.expectEqual(h9.policy.mount.Access.up, o.mounts[1].access.?);
    try t.expectEqualStrings("#L/cache", o.mounts[2].dst);
    try t.expectEqual(h9.policy.mount.Kind.tmp, o.mounts[3].kind);
    try t.expectEqual(h9.policy.NetMode.enable, o.policy.net.?);
    try t.expectEqualStrings("tcp!registry.npmjs.org!443", o.policy.net_allow[0]);
    try t.expectEqual(@as(?u64, 4 << 30), o.policy.memory);
    try t.expectEqual(@as(?u64, 30 * min), o.policy.timeout_ns);
    try t.expectEqualStrings("HOME", o.env[0].name);

    // net disable drops the allowlist, which h9 would refuse beside it.
    const off = try compile(ar, try narrow(ar, p, .{ .net = .disable }, &diag), &diag);
    try t.expectEqual(@as(usize, 0), off.policy.net_allow.len);
    // write ro with a writable mount is a conflict, as in h9.
    try t.expectError(error.Conflict, compile(ar, try apply(ar, p, .{ .write = .ro }), &diag));

    const argv = (try command(ar, p, &.{ "npm", "ci" })).?;
    try t.expectEqualStrings("/bin/sh", argv[0]);
    try t.expectEqualStrings("/app", argv[3]);
    try t.expectEqualStrings("ci", argv[5]);
    try t.expectEqual(@as(?[]const []const u8, null), try command(ar, .{ .phase = .run }, &.{}));
}

test "every phase's defaults print and compile" {
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    const ar = a.allocator();
    var diag: Diag = .{};
    for (std.enums.values(Phase)) |ph| for (std.enums.values(Trust)) |tr| {
        const p = try withRegistries(ar, defaults(ph, tr), &.{"node"});
        const out = try toText(ar, p);
        const back = try parsePolicy(ar, ph, tr, out, &diag);
        try t.expectEqualStrings(out, try toText(ar, back));
        _ = try compile(ar, p, &diag);
    };
}

test "sizes and durations print in their largest exact unit" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("4G", try std.fmt.bufPrint(&buf, "{f}", .{fmtSize(4 << 30)}));
    try t.expectEqualStrings("1536M", try std.fmt.bufPrint(&buf, "{f}", .{fmtSize(1536 << 20)}));
    try t.expectEqualStrings("1000", try std.fmt.bufPrint(&buf, "{f}", .{fmtSize(1000)}));
    try t.expectEqualStrings("2m", try std.fmt.bufPrint(&buf, "{f}", .{fmtDuration(2 * min)}));
    try t.expectEqualStrings("1d", try std.fmt.bufPrint(&buf, "{f}", .{fmtDuration(std.time.ns_per_day)}));
    try t.expectEqualStrings("90s", try std.fmt.bufPrint(&buf, "{f}", .{fmtDuration(90 * std.time.ns_per_s)}));
}
