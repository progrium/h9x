//! Config (design/prototype.md, "Config"): `h9x.toml` from the source and
//! from `~/.config/h9x/config.toml`, the `H9X_*` variables, and their
//! precedence: flags, then variables, then the source's file, then the
//! user's.
//!
//! Owned by W1, with toml.zig.
//!
//! `load` reads the three places into `Part`s and merges them into a
//! `Config`, strongest first, for the values that aren't policy: the
//! roots' packages, the pack's mounts and targets, and the variables that
//! keep their POC meanings. `policyFor` makes a machine's policy, where
//! precedence also decides who may widen it:
//!
//! 1. The phase's defaults for the trust level (policy.zig), with the
//!    plan's registries and the machine's own mounts.
//! 2. The user's config, which is the person's own: it may widen.
//! 3. The source's `h9x.toml`, which may widen only a trusted source's
//!    (a directory, or a remote one with `--trust`). An untrusted
//!    source's file can only narrow, so a repository can't loosen the
//!    sandbox it runs in.
//! 4. The `H9X_*` variables, then the flags: these only narrow, so a
//!    script can't widen a policy by accident. `run`'s `--net` and
//!    `--listen` are the exception the defaults table names, and set the
//!    mode as given.
//!
//! A config error or a widening is error.Config or error.Widens, after an
//! event saying where and why; both are exit 2.

const std = @import("std");
const types = @import("types.zig");
const cli = @import("cli.zig");
const toml = @import("toml.zig");
const policy = @import("policy.zig");
const units = @import("units.zig");

pub const Config = struct {
    pub const Roots = struct {
        base: []const []const u8 = &.{},
        build: []const []const u8 = &.{},
    };
    pub const Build = struct {
        memory: ?u64 = null,
        net: ?types.Net = null,
        netallow: []const []const u8 = &.{},
        secrets: []const []const u8 = &.{},
        timeout_ns: ?u64 = null,
    };
    pub const Run = struct {
        /// Plan lines that narrow the run's policy.
        policy: ?[]const u8 = null,
        /// Remote sources the person trusts, as `--trust` does: prefixes of
        /// a SOURCE as given or of its URL. Only the user's config sets it.
        trusted: []const []const u8 = &.{},
    };
    pub const Pack = struct {
        mount: []const []const u8 = &.{},
        targets: []const types.Target = &.{},
        /// `targets = ["all"]`.
        all_targets: bool = false,
    };

    roots: Roots = .{},
    build: Build = .{},
    run: Run = .{},
    pack: Pack = .{},

    /// `H9X_CACHE`: the cache's root, or null for the default.
    cache: ?[]const u8 = null,
    /// `H9X_RAILPACK`: a Railpack binary to use instead of the release.
    railpack: ?[]const u8 = null,
    /// `H9X_RUBY_COMPILE=1`: build Ruby from source.
    ruby_compile: bool = false,
    /// `H9X_REPLAN=1`, as `--replan`.
    replan: bool = false,
    /// Notes for the person, such as a POC variable that's ignored now.
    /// `load` emits them as `log` events too.
    warnings: []const []const u8 = &.{},

    /// What each place gave, weakest first: the user's file, the source's,
    /// then the environment. Absent places are left out.
    parts: []const Part = &.{},
};

/// Whether `[run] trusted` names a remote source: a prefix of its SOURCE
/// as given, or of the URL it's fetched from.
pub fn trusts(cfg: Config, spec: []const u8, url: ?[]const u8) bool {
    for (cfg.run.trusted) |t| {
        if (t.len == 0) continue;
        if (std.mem.startsWith(u8, spec, t)) return true;
        if (url) |u| if (std.mem.startsWith(u8, u, t)) return true;
    }
    return false;
}

test trusts {
    const c: Config = .{ .run = .{ .trusted = &.{ "gh:me/", "https://github.com/myorg/" } } };
    try std.testing.expect(trusts(c, "gh:me/app@v1", null));
    try std.testing.expect(trusts(c, "github.com/myorg/tool", "https://github.com/myorg/tool"));
    try std.testing.expect(!trusts(c, "gh:someone/app", "https://github.com/someone/app"));
}

/// Where a part of the config came from.
pub const Origin = enum { user, source, env };

/// One place's config, each value null where that place doesn't set it.
pub const Part = struct {
    origin: Origin,
    /// The file, or `environment`.
    path: []const u8,
    roots_base: ?[]const []const u8 = null,
    roots_build: ?[]const []const u8 = null,
    memory: ?u64 = null,
    net: ?types.Net = null,
    netallow: ?[]const []const u8 = null,
    secrets: ?[]const []const u8 = null,
    timeout_ns: ?u64 = null,
    run_policy: ?[]const u8 = null,
    /// `run_policy`, parsed.
    run_delta: policy.Delta = .{},
    /// Where `run_policy` starts in its file, for errors.
    run_policy_line: usize = 0,
    run_trusted: ?[]const []const u8 = null,
    pack_mount: ?[]const []const u8 = null,
    pack_targets: ?[]const types.Target = null,
    pack_all_targets: bool = false,

    /// The part's change to a phase's policy.
    pub fn delta(p: Part, phase: types.Phase) policy.Delta {
        return switch (phase) {
            .build, .shell => .{
                .memory = p.memory,
                .timeout_ns = p.timeout_ns,
                .net = p.net,
                .netallow_add = p.netallow orelse &.{},
            },
            .run => p.run_delta,
            else => .{},
        };
    }
};

pub const Error = error{ Config, OutOfMemory };

/// Where a config error was.
pub const Diag = struct {
    path: []const u8 = "",
    line: usize = 0,
    msg: []const u8 = "",

    pub fn format(d: Diag, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (d.path.len > 0) {
            try w.writeAll(d.path);
            if (d.line > 0) try w.print(":{d}", .{d.line});
            try w.writeAll(": ");
        }
        try w.writeAll(d.msg);
    }
};

/// The source's file, at its root.
pub const source_file = "h9x.toml";

/// The config for `source`, from its files and the environment. Flags are
/// applied by the command.
pub fn load(ctx: *cli.Context, source: types.Source) !Config {
    var diag: Diag = .{};
    const cfg = loadFrom(ctx.arena, ctx.io, ctx.env, source.path, &diag) catch |e| switch (e) {
        error.Config => {
            ctx.events.log("{f}", .{diag});
            return error.Config;
        },
        else => |x| return x,
    };
    for (cfg.warnings) |w| ctx.events.log("warning: {s}", .{w});
    return cfg;
}

/// `load`, without a context: `dir` is the source's tree, or null when
/// it isn't known yet (a remote source before it's fetched), which reads
/// the user's config and the environment only.
pub fn loadFrom(
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    dir: ?[]const u8,
    diag: *Diag,
) (Error || std.Io.Dir.ReadFileAllocError)!Config {
    var parts: std.ArrayList(Part) = .empty;
    if (try userPath(arena, env)) |path| {
        if (try readOptional(arena, io, path)) |text| try parts.append(arena, try parsePart(arena, .user, path, text, diag));
    }
    if (dir) |d| {
        const path = try std.fs.path.join(arena, &.{ d, source_file });
        if (try readOptional(arena, io, path)) |text| try parts.append(arena, try parsePart(arena, .source, path, text, diag));
    }
    var warnings: std.ArrayList([]const u8) = .empty;
    try parts.append(arena, try fromEnv(arena, env, diag, &warnings));
    var cfg = merge(parts.items);
    applyEnv(&cfg, env);
    cfg.warnings = warnings.items;
    return cfg;
}

/// `$XDG_CONFIG_HOME/h9x/config.toml`, or `~/.config/h9x/config.toml`.
pub fn userPath(arena: std.mem.Allocator, env: *const std.process.Environ.Map) error{OutOfMemory}!?[]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |x| if (x.len > 0) return try std.fs.path.join(arena, &.{ x, "h9x", "config.toml" });
    const home = env.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return try std.fs.path.join(arena, &.{ home, ".config", "h9x", "config.toml" });
}

fn readOptional(arena: std.mem.Allocator, io: std.Io, path: []const u8) std.Io.Dir.ReadFileAllocError!?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => |x| x,
    };
}

/// One file's config. Every table and key is one h9x knows, with the type
/// it takes, or error.Config.
pub fn parsePart(arena: std.mem.Allocator, origin: Origin, path: []const u8, text: []const u8, diag: *Diag) Error!Part {
    var td: toml.Diag = .{};
    const doc = toml.parse(arena, text, &td) catch |e| switch (e) {
        error.Syntax => return fail(arena, diag, path, td.line, "{s}", .{td.msg}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    var p: Part = .{ .origin = origin, .path = path };
    for (doc.tables) |t| {
        const known = std.meta.stringToEnum(enum { roots, build, run, pack }, t.name) orelse {
            if (t.name.len == 0) {
                if (t.entries.len > 0) return fail(arena, diag, path, t.entries[0].line, "{s} isn't in a table: h9x.toml has [roots], [build], [run], and [pack]", .{t.entries[0].key});
                continue;
            }
            return fail(arena, diag, path, t.line, "unknown table [{s}]: h9x.toml has [roots], [build], [run], and [pack]", .{t.name});
        };
        for (t.entries) |e| {
            const f: Field = .{ .arena = arena, .diag = diag, .path = path, .table = t.name, .e = e };
            switch (known) {
                .roots => if (eql(e.key, "base")) {
                    p.roots_base = try f.packages();
                } else if (eql(e.key, "build")) {
                    p.roots_build = try f.packages();
                } else return f.unknown("base and build"),
                .build => if (eql(e.key, "memory")) {
                    p.memory = try f.size();
                } else if (eql(e.key, "net")) {
                    const s = try f.string();
                    p.net = buildNet(s) orelse return f.bad("want \"none\", \"registries\", \"outbound\", or \"enable\"", .{});
                } else if (eql(e.key, "netallow")) {
                    const list = try f.strings();
                    const out = try arena.alloc([]const u8, list.len);
                    for (list, out) |s, *o| {
                        var why: []const u8 = "";
                        o.* = try policy.normalizePattern(arena, s, &why) orelse return f.bad("{s}: {s}", .{ s, why });
                    }
                    p.netallow = out;
                } else if (eql(e.key, "secrets")) {
                    const list = try f.strings();
                    for (list) |s| if (!policy.validName(s)) return f.bad("{s} isn't a variable name", .{s});
                    p.secrets = list;
                } else if (eql(e.key, "timeout")) {
                    p.timeout_ns = units.parseDuration(try f.string()) orelse return f.bad("not a duration, such as 30m or 2h", .{});
                } else return f.unknown("memory, net, netallow, secrets, and timeout"),
                .run => if (eql(e.key, "policy")) {
                    const s = try f.string();
                    var pd: policy.Diag = .{};
                    p.run_delta = policy.parse(arena, s, &pd) catch |err| switch (err) {
                        // A multi-line string's text starts on the line after
                        // the key.
                        error.Syntax => return fail(arena, diag, path, e.line + pd.line, "[run] policy: {s}", .{pd.msg}),
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    p.run_policy = s;
                    p.run_policy_line = e.line;
                } else if (eql(e.key, "trusted")) {
                    if (origin != .user) return f.bad("only your own config, not a source's, can trust sources", .{});
                    p.run_trusted = try f.strings();
                } else return f.unknown("policy and trusted"),
                .pack => if (eql(e.key, "mount")) {
                    const list = try f.strings();
                    for (list) |s| _ = parseMount(s) orelse return f.bad("{s}: want HOST:GUEST[:ro], with GUEST absolute", .{s});
                    p.pack_mount = list;
                } else if (eql(e.key, "targets")) {
                    const list = try f.strings();
                    var out: std.ArrayList(types.Target) = .empty;
                    for (list) |s| {
                        if (eql(s, "all")) {
                            p.pack_all_targets = true;
                            continue;
                        }
                        try out.append(arena, std.meta.stringToEnum(types.Target, s) orelse
                            return f.bad("{s}: want linux-amd64, linux-arm64, macos-arm64, windows-amd64, or all", .{s}));
                    }
                    p.pack_targets = out.items;
                } else return f.unknown("mount and targets"),
            }
        }
    }
    return p;
}

/// `build.net`'s names: design.md's `none`, `registries`, and `outbound`,
/// and `enable`, which is `registries`.
fn buildNet(s: []const u8) ?types.Net {
    if (eql(s, "registries")) return .enable;
    return units.parseNet(s);
}

/// `HOST:GUEST[:ro]`, as `--mount` takes it. Access is `rw` unless `ro`.
pub fn parseMount(s: []const u8) ?types.Mount {
    var it = std.mem.splitScalar(u8, s, ':');
    const host = it.next().?;
    const guest = it.next() orelse return null;
    const opt = it.next();
    if (host.len == 0 or guest.len == 0 or guest[0] != '/' or it.next() != null) return null;
    var access: types.Mount.Access = .rw;
    if (opt) |o| {
        if (!eql(o, "ro")) return null;
        access = .ro;
    }
    return .{ .kind = .dir, .src = host, .dst = guest, .access = access };
}

const Field = struct {
    arena: std.mem.Allocator,
    diag: *Diag,
    path: []const u8,
    table: []const u8,
    e: toml.Entry,

    fn bad(f: Field, comptime fmt: []const u8, args: anytype) Error {
        const msg = try std.fmt.allocPrint(f.arena, fmt, args);
        return fail(f.arena, f.diag, f.path, f.e.line, "{s}.{s}: {s}", .{ f.table, f.e.key, msg });
    }

    fn unknown(f: Field, known: []const u8) Error {
        return fail(f.arena, f.diag, f.path, f.e.line, "unknown key {s} in [{s}], which has {s}", .{ f.e.key, f.table, known });
    }

    fn want(f: Field, what: []const u8) Error {
        return f.bad("want {s}, not {s}", .{ what, f.e.value.kind() });
    }

    fn string(f: Field) Error![]const u8 {
        return switch (f.e.value) {
            .string => |s| s,
            else => f.want("a string"),
        };
    }

    fn strings(f: Field) Error![]const []const u8 {
        return switch (f.e.value) {
            .strings => |s| s,
            else => f.want("an array of strings"),
        };
    }

    fn packages(f: Field) Error![]const []const u8 {
        const list = try f.strings();
        for (list) |s| if (s.len == 0 or std.mem.indexOfAny(u8, s, " \t\n") != null) return f.bad("\"{s}\" isn't a package name", .{s});
        return list;
    }

    /// `"4G"`, or an integer of bytes.
    fn size(f: Field) Error!u64 {
        return switch (f.e.value) {
            .string => |s| units.parseSize(s) orelse f.bad("not a size, such as 512M or 4G", .{}),
            .integer => |n| if (n > 0) @intCast(n) else f.bad("want a size above 0", .{}),
            else => f.want("a size, such as \"4G\""),
        };
    }
};

fn fail(arena: std.mem.Allocator, diag: *Diag, path: []const u8, line: usize, comptime fmt: []const u8, args: anytype) Error {
    diag.* = .{ .path = path, .line = line, .msg = try std.fmt.allocPrint(arena, fmt, args) };
    return error.Config;
}

/// The variables that map onto config values (design/prototype.md,
/// "Config"): `H9X_MEMORY` is `build.memory`, and `H9X_BASE_PACKAGES` and
/// `H9X_BUILD_PACKAGES`, space-separated, are `roots.base` and
/// `roots.build`. `H9` and `H9_FLAGS` are ignored with a warning.
pub fn fromEnv(
    arena: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    diag: *Diag,
    warnings: *std.ArrayList([]const u8),
) Error!Part {
    var p: Part = .{ .origin = .env, .path = "environment" };
    if (env.get("H9X_MEMORY")) |v| if (v.len > 0) {
        p.memory = units.parseSize(v) orelse return fail(arena, diag, "", 0, "H9X_MEMORY={s}: not a size, such as 512M or 4G", .{v});
    };
    if (env.get("H9X_BASE_PACKAGES")) |v| if (v.len > 0) {
        p.roots_base = try words(arena, v);
    };
    if (env.get("H9X_BUILD_PACKAGES")) |v| if (v.len > 0) {
        p.roots_build = try words(arena, v);
    };
    if (env.get("H9") != null)
        try warnings.append(arena, "H9 is ignored: h9 is part of h9x now");
    if (env.get("H9_FLAGS") != null)
        try warnings.append(arena, "H9_FLAGS is ignored: use H9X_BACKEND for the backend, and h9x.toml for limits and policy");
    // h9x's name while incubating.
    for (env.keys()) |k| if (std.mem.startsWith(u8, k, "H9BUILD_"))
        try warnings.append(arena, try std.fmt.allocPrint(arena, "{s} is ignored: h9build is h9x now, and its variables are H9X_*", .{k}));
    return p;
}

fn words(arena: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, s, " \t\n");
    while (it.next()) |w| try out.append(arena, w);
    return out.items;
}

/// The variables that keep their POC meanings and aren't in any file.
fn applyEnv(cfg: *Config, env: *const std.process.Environ.Map) void {
    if (env.get("H9X_CACHE")) |v| if (v.len > 0) {
        cfg.cache = v;
    };
    if (env.get("H9X_RAILPACK")) |v| if (v.len > 0) {
        cfg.railpack = v;
    };
    cfg.ruby_compile = eqlOpt(env.get("H9X_RUBY_COMPILE"), "1");
    cfg.replan = eqlOpt(env.get("H9X_REPLAN"), "1");
}

fn eqlOpt(a: ?[]const u8, b: []const u8) bool {
    return if (a) |x| eql(x, b) else false;
}

/// The parts merged, `parts` weakest first: each value is the strongest
/// part's that sets it.
pub fn merge(parts: []const Part) Config {
    var c: Config = .{ .parts = parts };
    for (parts) |p| {
        if (p.roots_base) |v| c.roots.base = v;
        if (p.roots_build) |v| c.roots.build = v;
        if (p.memory) |v| c.build.memory = v;
        if (p.net) |v| c.build.net = v;
        if (p.netallow) |v| c.build.netallow = v;
        if (p.secrets) |v| c.build.secrets = v;
        if (p.timeout_ns) |v| c.build.timeout_ns = v;
        if (p.run_policy) |v| c.run.policy = v;
        if (p.run_trusted) |v| c.run.trusted = v;
        if (p.pack_mount) |v| c.pack.mount = v;
        if (p.pack_targets) |v| {
            c.pack.targets = v;
            c.pack.all_targets = p.pack_all_targets;
        }
    }
    return c;
}

// ---------------------------------------------------------------- policy

/// What a command asks `policyFor` for: one machine's policy.
pub const Request = struct {
    phase: types.Phase,
    trust: types.Trust,
    /// The plan's providers, for build and shell's registries.
    providers: []const []const u8 = &.{},
    /// The machine itself: its roots, layers, source, and caches, and the
    /// env, cwd, and program the command runs. Taken as given, before any
    /// config.
    machine: policy.Delta = .{},
    /// `--mount`s: the person's host directories. A trusted source's run
    /// takes them; an untrusted one's refuses them (nothing from the host
    /// without `--trust`).
    host_mounts: []const types.Mount = &.{},
    /// Flags' changes, such as `--timeout`. These only narrow.
    flags: policy.Delta = .{},
    /// `run`'s `--net`, or `enable` for `--listen`: set as given.
    net: ?types.Net = null,
    /// `--secret` names, beside `build.secrets`.
    secrets: []const []const u8 = &.{},
};

pub const PolicyError = error{ Config, Widens, OutOfMemory };

/// A machine's policy: the phase's defaults, the machine, then the config
/// and flags in precedence order, each allowed to widen or not as the
/// file's comment says, then the secrets for a build. On an error, an
/// event says why.
pub fn policyFor(ctx: *cli.Context, cfg: Config, req: Request) PolicyError!types.Policy {
    var diag: Diag = .{};
    return resolve(ctx.arena, ctx.env, cfg, req, &diag) catch |e| {
        if (e != error.OutOfMemory) ctx.events.log("{f}", .{diag});
        return e;
    };
}

/// `policyFor`, without a context.
pub fn resolve(
    arena: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    cfg: Config,
    req: Request,
    diag: *Diag,
) PolicyError!types.Policy {
    var p = try policy.withRegistries(arena, policy.defaults(req.phase, req.trust), req.providers);
    p = try policy.apply(arena, p, req.machine);
    if (req.host_mounts.len > 0) {
        if (req.trust == .untrusted) {
            diag.* = .{ .msg = "--mount gives an untrusted source host files; pass --trust if you trust it" };
            return error.Widens;
        }
        p = try policy.apply(arena, p, .{ .mounts = req.host_mounts });
    }

    for (cfg.parts) |part| {
        const d = part.delta(req.phase);
        if (d.empty()) continue;
        const may_widen = part.origin == .user or (part.origin == .source and req.trust == .trusted);
        if (may_widen) {
            p = try policy.apply(arena, p, d);
            continue;
        }
        var pd: policy.Diag = .{};
        p = policy.narrow(arena, p, d, &pd) catch |e| switch (e) {
            error.Widens => {
                const line = if (req.phase == .run and part.run_policy_line > 0) part.run_policy_line else 0;
                diag.* = .{ .path = part.path, .line = line, .msg = pd.msg };
                if (part.origin == .env) diag.msg = try std.fmt.allocPrint(arena, "{s}; H9X_* variables only narrow, so set it in {s} instead", .{
                    pd.msg,
                    (try userPath(arena, env)) orelse "~/.config/h9x/config.toml",
                });
                return error.Widens;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    var pd: policy.Diag = .{};
    p = policy.narrow(arena, p, req.flags, &pd) catch |e| switch (e) {
        error.Widens => {
            diag.* = .{ .path = "flags", .msg = pd.msg };
            return error.Widens;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (req.net) |n| {
        std.debug.assert(req.phase == .run);
        p.net = n;
    }

    if (req.phase == .build) {
        var secrets: std.ArrayList(types.EnvVar) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        for ([_][]const []const u8{ cfg.build.secrets, req.secrets }) |list| for (list) |name| {
            for (names.items) |have| {
                if (eql(have, name)) break;
            } else {
                try names.append(arena, name);
                if (!policy.validName(name)) {
                    diag.* = .{ .msg = try std.fmt.allocPrint(arena, "secret {s}: not a variable name", .{name}) };
                    return error.Config;
                }
                const value = env.get(name) orelse {
                    diag.* = .{ .msg = try std.fmt.allocPrint(arena, "secret {s} isn't set in the environment", .{name}) };
                    return error.Config;
                };
                try secrets.append(arena, .{ .name = name, .value = value, .secret = true });
            }
        };
        if (secrets.items.len > 0) p = try policy.apply(arena, p, .{ .env = secrets.items });
    }
    return p;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const example =
    \\[roots]
    \\base  = ["libjemalloc"]
    \\build = ["protobuf-dev"]
    \\
    \\[build]
    \\memory = "2G"
    \\net    = "registries"
    \\netallow = ["tcp!api.example.com!443", "npm.example.com"]
    \\secrets  = ["NPM_TOKEN"]
    \\
    \\[run]
    \\policy = """
    \\net disable
    \\write overlay
    \\memory 512M
    \\"""
    \\
    \\[pack]
    \\mount = [".:/work"]
    \\targets = ["linux-amd64", "all"]
    \\
;

test "a source's h9x.toml" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    var diag: Diag = .{};
    const p = try parsePart(a.allocator(), .source, "app/h9x.toml", example, &diag);
    try testing.expectEqualStrings("libjemalloc", p.roots_base.?[0]);
    try testing.expectEqual(@as(?u64, 2 << 30), p.memory);
    try testing.expectEqual(@as(?types.Net, .enable), p.net);
    try testing.expectEqualStrings("tcp!npm.example.com!443", p.netallow.?[1]);
    try testing.expectEqualStrings("NPM_TOKEN", p.secrets.?[0]);
    try testing.expectEqual(@as(?types.Net, .disable), p.run_delta.net);
    try testing.expectEqual(@as(?u64, 512 << 20), p.run_delta.memory);
    try testing.expectEqual(@as(usize, 12), p.run_policy_line);
    try testing.expectEqualStrings(".:/work", p.pack_mount.?[0]);
    try testing.expect(p.pack_all_targets);
    try testing.expectEqual(types.Target.@"linux-amd64", p.pack_targets.?[0]);
}

test "a config error names the file and line" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const cases = [_]struct { []const u8, usize, []const u8 }{
        .{ "[build]\nmemroy = \"4G\"", 2, "unknown key memroy" },
        .{ "[builds]\n", 1, "unknown table [builds]" },
        .{ "memory = 1", 1, "isn't in a table" },
        .{ "[build]\nmemory = \"lots\"", 2, "build.memory: not a size" },
        .{ "[build]\nnet = \"wide\"", 2, "build.net" },
        .{ "[build]\nnet = 1", 2, "want a string, not an integer" },
        .{ "[build]\nnetallow = [\"tcp!x\"]", 2, "build.netallow" },
        .{ "[build]\nsecrets = [\"NOT-A-NAME\"]", 2, "isn't a variable name" },
        .{ "[roots]\nbase = \"glibc\"", 2, "want an array of strings" },
        .{ "[run]\npolicy = \"\"\"\nnet disable\nbogus line\n\"\"\"", 4, "[run] policy: unknown line bogus" },
        .{ "[pack]\ntargets = [\"plan9-386\"]", 2, "pack.targets" },
        .{ "[pack]\nmount = [\"relative\"]", 2, "pack.mount" },
        .{ "[build]\nmemory = 4.5", 2, "isn't a decimal integer" },
    };
    for (cases) |c| {
        var diag: Diag = .{};
        try testing.expectError(error.Config, parsePart(ar, .source, "h9x.toml", c[0], &diag));
        testing.expectEqual(c[1], diag.line) catch |e| {
            std.debug.print("{s}: {f}\n", .{ c[0], diag });
            return e;
        };
        const msg = try std.fmt.allocPrint(ar, "{f}", .{diag});
        if (std.mem.indexOf(u8, msg, c[2]) == null) {
            std.debug.print("want {s} in {s}\n", .{ c[2], msg });
            return error.TestUnexpectedResult;
        }
        try testing.expect(std.mem.startsWith(u8, msg, "h9x.toml:"));
    }
}

test "precedence: the environment over the source over the user" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    var env: std.process.Environ.Map = .init(ar);
    try env.put("H9X_BASE_PACKAGES", "jq  curl");
    try env.put("H9X_CACHE", "/tmp/c");
    try env.put("H9X_REPLAN", "1");
    try env.put("H9_FLAGS", "--net enable");
    var diag: Diag = .{};
    var warnings: std.ArrayList([]const u8) = .empty;
    const user = try parsePart(ar, .user, "config.toml", "[roots]\nbase = [\"a\"]\nbuild = [\"b\"]\n[build]\nmemory = \"8G\"\n", &diag);
    const source = try parsePart(ar, .source, "h9x.toml", "[roots]\nbuild = [\"c\"]\n", &diag);
    const e = try fromEnv(ar, &env, &diag, &warnings);
    var cfg = merge(&.{ user, source, e });
    applyEnv(&cfg, &env);
    try testing.expectEqualStrings("jq", cfg.roots.base[0]);
    try testing.expectEqualStrings("curl", cfg.roots.base[1]);
    try testing.expectEqualStrings("c", cfg.roots.build[0]);
    try testing.expectEqual(@as(?u64, 8 << 30), cfg.build.memory);
    try testing.expectEqualStrings("/tmp/c", cfg.cache.?);
    try testing.expect(cfg.replan);
    try testing.expect(!cfg.ruby_compile);
    try testing.expectEqual(@as(usize, 1), warnings.items.len);
}

test "load reads the source's file and the user's" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "app");
    try tmp.dir.createDirPath(io, "xdg/h9x");
    try tmp.dir.writeFile(io, .{ .sub_path = "app/h9x.toml", .data = "[build]\nmemory = \"2G\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "xdg/h9x/config.toml", .data = "[build]\nmemory = \"6G\"\ntimeout = \"1h\"\n" });
    const root = try std.fs.path.join(ar, &.{ ".zig-cache", "tmp", &tmp.sub_path });

    var env: std.process.Environ.Map = .init(ar);
    try env.put("XDG_CONFIG_HOME", try std.fs.path.join(ar, &.{ root, "xdg" }));
    var diag: Diag = .{};
    const cfg = try loadFrom(ar, io, &env, try std.fs.path.join(ar, &.{ root, "app" }), &diag);
    try testing.expectEqual(@as(usize, 3), cfg.parts.len);
    try testing.expectEqual(@as(?u64, 2 << 30), cfg.build.memory);
    try testing.expectEqual(@as(?u64, std.time.ns_per_hour), cfg.build.timeout_ns);

    // No files: only the environment's part.
    var none: std.process.Environ.Map = .init(ar);
    try none.put("HOME", try std.fs.path.join(ar, &.{ root, "nohome" }));
    const empty = try loadFrom(ar, io, &none, try std.fs.path.join(ar, &.{ root, "xdg" }), &diag);
    try testing.expectEqual(@as(usize, 1), empty.parts.len);

    // A bad file is error.Config, naming it.
    try tmp.dir.writeFile(io, .{ .sub_path = "app/h9x.toml", .data = "[build]\nnope = 1\n" });
    try testing.expectError(error.Config, loadFrom(ar, io, &env, try std.fs.path.join(ar, &.{ root, "app" }), &diag));
    try testing.expect(std.mem.endsWith(u8, diag.path, "app/h9x.toml"));
}

fn testConfig(ar: std.mem.Allocator, user: ?[]const u8, source: ?[]const u8, env: *const std.process.Environ.Map) !Config {
    var diag: Diag = .{};
    var parts: std.ArrayList(Part) = .empty;
    if (user) |u| try parts.append(ar, try parsePart(ar, .user, "config.toml", u, &diag));
    if (source) |s| try parts.append(ar, try parsePart(ar, .source, "h9x.toml", s, &diag));
    var warnings: std.ArrayList([]const u8) = .empty;
    try parts.append(ar, try fromEnv(ar, env, &diag, &warnings));
    return merge(parts.items);
}

test "an untrusted source's file can only narrow" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    var env: std.process.Environ.Map = .init(ar);
    var diag: Diag = .{};

    // Narrowing is fine at either trust level.
    const narrow_cfg = try testConfig(ar, null, "[build]\nmemory = \"2G\"\nnet = \"outbound\"\n", &env);
    for ([_]types.Trust{ .trusted, .untrusted }) |tr| {
        const p = try resolve(ar, &env, narrow_cfg, .{ .phase = .build, .trust = tr, .providers = &.{"node"} }, &diag);
        try testing.expectEqual(@as(?u64, 2 << 30), p.memory);
        try testing.expectEqual(types.Net.outbound, p.net);
    }

    // Widening: refused for an untrusted source, taken for a trusted one.
    const wide = [_][]const u8{
        "[build]\nmemory = \"16G\"\n",
        "[build]\ntimeout = \"2h\"\n",
        "[build]\nnetallow = [\"evil.example.com\"]\n",
        "[run]\npolicy = \"net enable\"\n",
        "[run]\npolicy = \"dir rw /home/me /home\"\n",
    };
    for (wide) |text| {
        // An added host widens only an allowlist.
        if (policy.open_builds and std.mem.indexOf(u8, text, "netallow") != null) continue;
        const cfg = try testConfig(ar, null, text, &env);
        const phase: types.Phase = if (std.mem.indexOf(u8, text, "[run]") != null) .run else .build;
        try testing.expectError(error.Widens, resolve(ar, &env, cfg, .{ .phase = phase, .trust = .untrusted }, &diag));
        try testing.expectEqualStrings("h9x.toml", diag.path);
        _ = try resolve(ar, &env, cfg, .{ .phase = phase, .trust = .trusted }, &diag);
    }
    // The line of [run] policy is named.
    const run_cfg = try testConfig(ar, null, "\n[run]\npolicy = \"net enable\"\n", &env);
    try testing.expectError(error.Widens, resolve(ar, &env, run_cfg, .{ .phase = .run, .trust = .untrusted }, &diag));
    try testing.expectEqual(@as(usize, 3), diag.line);

    // build.netallow adds to a trusted build's allowlist, and leaves an
    // open network open.
    const add = try testConfig(ar, null, "[build]\nnetallow = [\"api.example.com\"]\n", &env);
    const p = try resolve(ar, &env, add, .{ .phase = .build, .trust = .trusted, .providers = &.{"node"} }, &diag);
    if (policy.open_builds) {
        try testing.expectEqual(@as(usize, 0), p.netallow.len);
    } else {
        try testing.expect(policy.covered("tcp!api.example.com!443", p.netallow));
        try testing.expect(policy.covered("tcp!registry.npmjs.org!443", p.netallow));
    }
}

test "the user's config may widen; variables and flags only narrow" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    var diag: Diag = .{};

    var env: std.process.Environ.Map = .init(ar);
    const user = try testConfig(ar, "[build]\nmemory = \"8G\"\n", null, &env);
    const p = try resolve(ar, &env, user, .{ .phase = .build, .trust = .untrusted }, &diag);
    try testing.expectEqual(@as(?u64, 8 << 30), p.memory);

    // H9X_MEMORY narrows, and is refused if it widens.
    var small: std.process.Environ.Map = .init(ar);
    try small.put("H9X_MEMORY", "1G");
    const s = try resolve(ar, &small, try testConfig(ar, null, null, &small), .{ .phase = .build, .trust = .trusted }, &diag);
    try testing.expectEqual(@as(?u64, 1 << 30), s.memory);
    var big: std.process.Environ.Map = .init(ar);
    try big.put("H9X_MEMORY", "16G");
    try testing.expectError(error.Widens, resolve(ar, &big, try testConfig(ar, null, null, &big), .{ .phase = .build, .trust = .trusted }, &diag));
    try testing.expectEqualStrings("environment", diag.path);
    // Unless the user's config made room for it.
    const roomy = try testConfig(ar, "[build]\nmemory = \"16G\"\n", null, &big);
    _ = try resolve(ar, &big, roomy, .{ .phase = .build, .trust = .trusted }, &diag);

    // --timeout past a remote run's 10m widens; under it narrows.
    const none = try testConfig(ar, null, null, &env);
    try testing.expectError(error.Widens, resolve(ar, &env, none, .{ .phase = .run, .trust = .untrusted, .flags = .{ .timeout_ns = std.time.ns_per_hour } }, &diag));
    try testing.expectEqualStrings("flags", diag.path);
    const r = try resolve(ar, &env, none, .{ .phase = .run, .trust = .untrusted, .flags = .{ .timeout_ns = std.time.ns_per_min } }, &diag);
    try testing.expectEqual(@as(?u64, std.time.ns_per_min), r.timeout_ns);

    // --net and --listen set run's mode as given.
    const l = try resolve(ar, &env, none, .{ .phase = .run, .trust = .untrusted, .net = .enable }, &diag);
    try testing.expectEqual(types.Net.enable, l.net);

    // --mount: a trusted run takes it, an untrusted one refuses it.
    const m: []const types.Mount = &.{parseMount("/home/me/data:/data:ro").?};
    const lm = try resolve(ar, &env, none, .{ .phase = .run, .trust = .trusted, .host_mounts = m }, &diag);
    try testing.expectEqualStrings("/data", lm.mounts[0].dst);
    try testing.expectError(error.Widens, resolve(ar, &env, none, .{ .phase = .run, .trust = .untrusted, .host_mounts = m }, &diag));
}

test "secrets reach the build only, and never print" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    var diag: Diag = .{};
    var env: std.process.Environ.Map = .init(ar);
    try env.put("NPM_TOKEN", "s3cret");
    try env.put("GH_TOKEN", "hunter2");
    const cfg = try testConfig(ar, null, "[build]\nsecrets = [\"NPM_TOKEN\"]\n", &env);

    const b = try resolve(ar, &env, cfg, .{ .phase = .build, .trust = .trusted, .secrets = &.{ "GH_TOKEN", "NPM_TOKEN" } }, &diag);
    try testing.expectEqual(@as(usize, 2), b.env.len);
    try testing.expectEqualStrings("s3cret", b.env[0].value);
    try testing.expect(b.env[0].secret and b.env[1].secret);
    const text = try policy.toText(ar, b);
    try testing.expect(std.mem.indexOf(u8, text, "s3cret") == null);
    try testing.expect(std.mem.indexOf(u8, text, "hunter2") == null);

    for ([_]types.Phase{ .plan, .run, .shell }) |ph| {
        const p = try resolve(ar, &env, cfg, .{ .phase = ph, .trust = .trusted, .secrets = &.{"GH_TOKEN"} }, &diag);
        try testing.expectEqual(@as(usize, 0), p.env.len);
    }
    try testing.expectError(error.Config, resolve(ar, &env, cfg, .{ .phase = .build, .trust = .trusted, .secrets = &.{"MISSING"} }, &diag));
    try testing.expectEqualStrings("secret MISSING isn't set in the environment", diag.msg);
}

test "--print shows each phase's policy" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    var diag: Diag = .{};
    var env: std.process.Environ.Map = .init(ar);
    const cfg = try testConfig(ar, null, example, &env);
    const p = try resolve(ar, &env, cfg, .{
        .phase = .run,
        .trust = .trusted,
        .machine = .{ .mounts = &.{.{ .kind = .dir, .src = "/cache/roots/base-1", .dst = "#L" }}, .cwd = "/app" },
    }, &diag);
    try testing.expectEqualStrings(
        \\dir ro /cache/roots/base-1 '#L'
        \\net disable
        \\write overlay
        \\memory 512M
        \\cwd /app
        \\
    , try policy.toText(ar, p));
}
