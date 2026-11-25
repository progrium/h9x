//! The command line (design/prototype.md, "Commands"): parsing into a
//! `Command`, the usage text, and the context each command runs with.
//!
//! Parsing is complete here, so the commands' files (src/cmd/) get typed
//! options and never look at argv. A flag the prototype doesn't have yet is
//! added here and to its options struct.

const std = @import("std");
const types = @import("types.zig");
const units = @import("units.zig");
const events = @import("events.zig");

pub const usage =
    \\usage: h9x COMMAND [SOURCE] [FLAGS]
    \\
    \\  h9x run [SOURCE] [--trust] [--listen PORT] [--mount HOST:GUEST[:ro]] [--net MODE]
    \\          [--timeout D] [--print] [-- CMD ARGS...]
    \\  h9x build [SOURCE] [-o OUT] [--replan] [--secret NAME] [--json]
    \\  h9x shell [SOURCE] [--stage build|run] [--keep[=DIR]] [-- CMD ARGS...]
    \\  h9x plan [SOURCE] [--replan] [--json]
    \\  h9x pack [SOURCE|OUT.h9] [-o FILE|DIR] [--exe] [--target LIST|all]
    \\          [--mount HOST:GUEST[:ro]] [--runner [TARGET=]FILE] [--no-debug]
    \\  h9x pack --inspect FILE
    \\  h9x export [SOURCE|OUT.h9] (--oci FILE | --docker)
    \\  h9x cache ls
    \\  h9x cache prune [--unused DURATION] [--dry-run]
    \\
    \\SOURCE is a directory (default .), a git URL (https://..., git@...,
    \\github.com/OWNER/REPO, or gh:OWNER/REPO, with @REF and //SUBDIR), or
    \\an https:// tarball URL. Every command takes --json, --print, and --help.
    \\
;

/// Flags every command takes.
pub const Common = struct {
    /// Events as NDJSON on stderr.
    json: bool = false,
    /// Print each machine's policy, then exit.
    print: bool = false,
    /// `--secret NAME`: host variables passed to build steps only.
    secrets: []const []const u8 = &.{},
};

pub const RunOptions = struct {
    source: []const u8 = ".",
    trust: bool = false,
    listen: []const u16 = &.{},
    /// `--mount`s, with host paths as given.
    mounts: []const types.Mount = &.{},
    net: ?types.Net = null,
    timeout_ns: ?u64 = null,
    /// The command after `--`; empty runs the start command.
    argv: []const []const u8 = &.{},
};

pub const BuildOptions = struct {
    source: []const u8 = ".",
    out: ?[]const u8 = null,
    replan: bool = false,
    /// `h9x [-o OUT] DIR`, the POC's form: build with a warning.
    poc: bool = false,
};

pub const ShellOptions = struct {
    pub const Stage = enum { build, run };
    pub const Keep = union(enum) {
        no,
        /// `--keep`: keep the scratch layer where it was made.
        yes,
        /// `--keep=DIR`: keep it as DIR.
        dir: []const u8,
    };

    source: []const u8 = ".",
    stage: Stage = .build,
    keep: Keep = .no,
    argv: []const []const u8 = &.{},
};

pub const PlanOptions = struct {
    source: []const u8 = ".",
    replan: bool = false,
};

pub const PackOptions = struct {
    /// A source, or a build's output directory.
    source: []const u8 = ".",
    out: ?[]const u8 = null,
    exe: bool = false,
    /// `--target`; empty with `exe` means the host's. `all` is expanded by
    /// the pack command, since it depends on the layers' architecture.
    targets: []const types.Target = &.{},
    all_targets: bool = false,
    mounts: []const types.Mount = &.{},
    /// `--runner FILE` or `--runner TARGET=FILE`, each given.
    runners: []const []const u8 = &.{},
    no_debug: bool = false,
    /// `--inspect FILE`: print a packed executable's trailer and pack.json.
    inspect: ?[]const u8 = null,
};

pub const ExportOptions = struct {
    pub const Format = union(enum) {
        /// An OCI image layout, as a tar, at this path.
        oci: []const u8,
        /// A `docker save` tarball on stdout.
        docker,
    };

    source: []const u8 = ".",
    format: Format,
};

pub const CacheOptions = union(enum) {
    ls,
    prune: struct {
        unused_ns: ?u64 = null,
        dry_run: bool = false,
    },
};

pub const Command = union(enum) {
    run: RunOptions,
    build: BuildOptions,
    shell: ShellOptions,
    plan: PlanOptions,
    pack: PackOptions,
    @"export": ExportOptions,
    cache: CacheOptions,
    help,
    version,
};

pub const Parsed = struct {
    command: Command,
    common: Common = .{},
};

/// What a command runs with. main.zig makes one per process.
pub const Context = struct {
    gpa: std.mem.Allocator,
    /// Freed when the command ends.
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    /// The program's own output, such as `plan`'s summary or `--print`'s
    /// policies.
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    events: *events.Emitter,
    common: Common,
};

pub const Error = error{ Usage, OutOfMemory };

/// Why the last `parse` failed, for the message before the usage text.
pub var why: []const u8 = "";

/// Parses argv (without the program's name).
pub fn parse(arena: std.mem.Allocator, args: []const []const u8) Error!Parsed {
    why = "";
    if (args.len == 0) return .{ .command = .help };
    const first = args[0];
    if (eql(first, "-h") or eql(first, "--help") or eql(first, "help")) return .{ .command = .help };
    if (eql(first, "--version") or eql(first, "version")) return .{ .command = .version };

    const Name = std.meta.Tag(Command);
    const name = std.meta.stringToEnum(Name, first) orelse {
        // `h9x [-o OUT] DIR`: the POC's form.
        if (eql(first, "-o") or !std.mem.startsWith(u8, first, "-")) return parsePoc(arena, args);
        return fail("unknown flag {s}", .{first}, arena);
    };
    var p: Parser = .{ .arena = arena, .args = args[1..] };
    var out: Parsed = .{ .command = undefined };
    var secrets: std.ArrayList([]const u8) = .empty;
    var mounts: std.ArrayList(types.Mount) = .empty;
    var listen: std.ArrayList(u16) = .empty;
    var targets: std.ArrayList(types.Target) = .empty;
    var runner_list: std.ArrayList([]const u8) = .empty;
    var positional: std.ArrayList([]const u8) = .empty;

    var run: RunOptions = .{};
    var build: BuildOptions = .{};
    var shell: ShellOptions = .{};
    var plan: PlanOptions = .{};
    var pack: PackOptions = .{};
    var oci: ?[]const u8 = null;
    var docker = false;
    var unused_ns: ?u64 = null;
    var dry_run = false;

    while (p.next()) |a| {
        if (eql(a, "--")) {
            const rest = p.rest();
            switch (name) {
                .run => run.argv = rest,
                .shell => shell.argv = rest,
                else => return fail("{s} takes no command after --", .{first}, arena),
            }
            break;
        }
        if (a.len < 2 or a[0] != '-') {
            try positional.append(arena, a);
            continue;
        }
        // Every command's flags.
        if (eql(a, "-h") or eql(a, "--help")) return .{ .command = .help };
        if (eql(a, "--json")) {
            out.common.json = true;
            continue;
        }
        if (eql(a, "--print")) {
            out.common.print = true;
            continue;
        }
        const flag, const inline_val = splitFlag(a);
        if (eql(flag, "--secret") and (name == .build or name == .run or name == .shell or name == .pack or name == .@"export")) {
            try secrets.append(arena, try p.value(flag, inline_val));
            continue;
        }
        const ok: bool = switch (name) {
            .run => blk: {
                if (eql(flag, "--trust")) run.trust = true //
                else if (eql(flag, "--listen")) try listen.append(arena, try parsePort(arena, try p.value(flag, inline_val))) //
                else if (eql(flag, "--mount")) try mounts.append(arena, try parseMount(arena, try p.value(flag, inline_val))) //
                else if (eql(flag, "--net")) run.net = try parseNet(arena, try p.value(flag, inline_val)) //
                else if (eql(flag, "--timeout")) run.timeout_ns = try parseDuration(arena, flag, try p.value(flag, inline_val)) //
                else break :blk false;
                break :blk true;
            },
            .build => blk: {
                if (eql(flag, "-o")) build.out = try p.value(flag, inline_val) //
                else if (eql(flag, "--replan")) build.replan = true //
                else break :blk false;
                break :blk true;
            },
            .shell => blk: {
                if (eql(flag, "--stage")) {
                    const v = try p.value(flag, inline_val);
                    shell.stage = std.meta.stringToEnum(ShellOptions.Stage, v) orelse
                        return fail("--stage {s}: want build or run", .{v}, arena);
                } else if (eql(flag, "--keep")) {
                    shell.keep = if (inline_val) |d| .{ .dir = d } else .yes;
                } else break :blk false;
                break :blk true;
            },
            .plan => blk: {
                if (eql(flag, "--replan")) plan.replan = true else break :blk false;
                break :blk true;
            },
            .pack => blk: {
                if (eql(flag, "-o")) pack.out = try p.value(flag, inline_val) //
                else if (eql(flag, "--exe")) pack.exe = true //
                else if (eql(flag, "--target")) try parseTargets(arena, try p.value(flag, inline_val), &targets, &pack.all_targets) //
                else if (eql(flag, "--mount")) try mounts.append(arena, try parseMount(arena, try p.value(flag, inline_val))) //
                else if (eql(flag, "--runner")) try runner_list.append(arena, try p.value(flag, inline_val)) //
                else if (eql(flag, "--no-debug")) pack.no_debug = true //
                else if (eql(flag, "--inspect")) pack.inspect = try p.value(flag, inline_val) //
                else break :blk false;
                break :blk true;
            },
            .@"export" => blk: {
                if (eql(flag, "--oci")) oci = try p.value(flag, inline_val) //
                else if (eql(flag, "--docker")) docker = true //
                else break :blk false;
                break :blk true;
            },
            .cache => blk: {
                if (eql(flag, "--unused")) unused_ns = try parseDuration(arena, flag, try p.value(flag, inline_val)) //
                else if (eql(flag, "--dry-run")) dry_run = true //
                else break :blk false;
                break :blk true;
            },
            .help, .version => false,
        };
        if (!ok) return fail("{s} doesn't take {s}", .{ first, flag }, arena);
    }
    out.common.secrets = secrets.items;

    const pos = positional.items;
    if (name != .cache and pos.len > 1) return fail("{s} takes one SOURCE, not {d}", .{ first, pos.len }, arena);
    const source: []const u8 = if (pos.len == 1) pos[0] else ".";

    out.command = switch (name) {
        .run => blk: {
            run.source = source;
            run.listen = listen.items;
            run.mounts = mounts.items;
            break :blk .{ .run = run };
        },
        .build => blk: {
            build.source = source;
            break :blk .{ .build = build };
        },
        .shell => blk: {
            shell.source = source;
            break :blk .{ .shell = shell };
        },
        .plan => blk: {
            plan.source = source;
            break :blk .{ .plan = plan };
        },
        .pack => blk: {
            pack.source = source;
            pack.targets = targets.items;
            pack.runners = runner_list.items;
            pack.mounts = mounts.items;
            if (pack.inspect != null and pos.len > 0) return fail("pack --inspect takes no SOURCE", .{}, arena);
            if ((targets.items.len > 0 or pack.all_targets) and !pack.exe) pack.exe = true;
            break :blk .{ .pack = pack };
        },
        .@"export" => blk: {
            if ((oci != null) == docker) return fail("export takes one of --oci FILE and --docker", .{}, arena);
            break :blk .{ .@"export" = .{
                .source = source,
                .format = if (oci) |f| .{ .oci = f } else .docker,
            } };
        },
        .cache => blk: {
            if (pos.len != 1) return fail("cache takes ls or prune", .{}, arena);
            if (eql(pos[0], "ls")) {
                if (unused_ns != null or dry_run) return fail("cache ls takes no flags", .{}, arena);
                break :blk .{ .cache = .ls };
            }
            if (eql(pos[0], "prune")) break :blk .{ .cache = .{ .prune = .{ .unused_ns = unused_ns, .dry_run = dry_run } } };
            return fail("cache {s}: want ls or prune", .{pos[0]}, arena);
        },
        .help => .help,
        .version => .version,
    };
    return out;
}

fn parsePoc(arena: std.mem.Allocator, args: []const []const u8) Error!Parsed {
    var b: BuildOptions = .{ .poc = true };
    var i: usize = 0;
    var dir: ?[]const u8 = null;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "-o")) {
            i += 1;
            if (i == args.len) return fail("-o needs a value", .{}, arena);
            b.out = args[i];
        } else if (std.mem.startsWith(u8, a, "-")) {
            return fail("unknown flag {s}", .{a}, arena);
        } else if (dir == null) {
            dir = a;
        } else return fail("unknown command {s}", .{args[0]}, arena);
    }
    b.source = dir orelse return fail("-o needs a directory to build", .{}, arena);
    return .{ .command = .{ .build = b } };
}

const Parser = struct {
    arena: std.mem.Allocator,
    args: []const []const u8,
    i: usize = 0,

    fn next(p: *Parser) ?[]const u8 {
        if (p.i == p.args.len) return null;
        defer p.i += 1;
        return p.args[p.i];
    }

    fn rest(p: *Parser) []const []const u8 {
        defer p.i = p.args.len;
        return p.args[p.i..];
    }

    /// A flag's value: `--flag=V`, or the next argument.
    fn value(p: *Parser, flag: []const u8, inline_val: ?[]const u8) Error![]const u8 {
        if (inline_val) |v| return v;
        return p.next() orelse fail("{s} needs a value", .{flag}, p.arena);
    }
};

fn splitFlag(a: []const u8) struct { []const u8, ?[]const u8 } {
    if (std.mem.startsWith(u8, a, "--")) {
        if (std.mem.indexOfScalar(u8, a, '=')) |i| return .{ a[0..i], a[i + 1 ..] };
    }
    return .{ a, null };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn fail(comptime fmt: []const u8, args: anytype, arena: std.mem.Allocator) Error {
    why = std.fmt.allocPrint(arena, fmt, args) catch "out of memory";
    return error.Usage;
}

fn parsePort(arena: std.mem.Allocator, v: []const u8) Error!u16 {
    return std.fmt.parseInt(u16, v, 10) catch fail("--listen {s}: not a port", .{v}, arena);
}

fn parseNet(arena: std.mem.Allocator, v: []const u8) Error!types.Net {
    return units.parseNet(v) orelse fail("--net {s}: want disable, outbound, or enable", .{v}, arena);
}

fn parseDuration(arena: std.mem.Allocator, flag: []const u8, v: []const u8) Error!u64 {
    return units.parseDuration(v) orelse fail("{s} {s}: not a duration, such as 30s, 10m, 2h, or 30d", .{ flag, v }, arena);
}

/// `HOST:GUEST[:ro]`. The host path is resolved by whoever mounts it.
fn parseMount(arena: std.mem.Allocator, v: []const u8) Error!types.Mount {
    var it = std.mem.splitScalar(u8, v, ':');
    const host = it.next().?;
    const guest = it.next() orelse "";
    const opt = it.next();
    if (host.len == 0 or guest.len == 0 or guest[0] != '/' or it.next() != null)
        return fail("--mount {s}: want HOST:GUEST[:ro], with GUEST absolute", .{v}, arena);
    var access: types.Mount.Access = .rw;
    if (opt) |o| {
        if (!eql(o, "ro")) return fail("--mount {s}: the only option is ro", .{v}, arena);
        access = .ro;
    }
    return .{ .kind = .dir, .src = host, .dst = guest, .access = access };
}

fn parseTargets(arena: std.mem.Allocator, v: []const u8, list: *std.ArrayList(types.Target), all: *bool) Error!void {
    var it = std.mem.splitScalar(u8, v, ',');
    while (it.next()) |t| {
        if (eql(t, "all")) {
            all.* = true;
            continue;
        }
        const target = std.meta.stringToEnum(types.Target, t) orelse
            return fail("--target {s}: want linux-amd64, linux-arm64, macos-arm64, windows-amd64, or all", .{t}, arena);
        try list.append(arena, target);
    }
}

test "commands and their flags" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const r = try parse(arena, &.{ "run", "gh:me/app@v1", "--trust", "--listen", "8080", "--mount=./data:/data:ro", "--net", "enable", "--timeout", "5m", "--", "node", "-v" });
    try std.testing.expectEqualStrings("gh:me/app@v1", r.command.run.source);
    try std.testing.expect(r.command.run.trust);
    try std.testing.expectEqual(@as(u16, 8080), r.command.run.listen[0]);
    try std.testing.expectEqual(types.Mount.Access.ro, r.command.run.mounts[0].access);
    try std.testing.expectEqual(types.Net.enable, r.command.run.net.?);
    try std.testing.expectEqual(@as(u64, 5 * std.time.ns_per_min), r.command.run.timeout_ns.?);
    try std.testing.expectEqualStrings("-v", r.command.run.argv[1]);

    const b = try parse(arena, &.{ "build", "--json", "-o", "out.h9", "--secret", "NPM_TOKEN" });
    try std.testing.expectEqualStrings(".", b.command.build.source);
    try std.testing.expectEqualStrings("out.h9", b.command.build.out.?);
    try std.testing.expect(b.common.json);
    try std.testing.expectEqualStrings("NPM_TOKEN", b.common.secrets[0]);

    const s = try parse(arena, &.{ "shell", "--stage", "run", "--keep=scratch" });
    try std.testing.expectEqual(ShellOptions.Stage.run, s.command.shell.stage);
    try std.testing.expectEqualStrings("scratch", s.command.shell.keep.dir);

    const p = try parse(arena, &.{ "pack", "app.h9", "--target", "linux-amd64,macos-arm64" });
    try std.testing.expect(p.command.pack.exe);
    try std.testing.expectEqual(types.Target.@"macos-arm64", p.command.pack.targets[1]);

    const e = try parse(arena, &.{ "export", "--docker" });
    try std.testing.expect(e.command.@"export".format == .docker);

    const c = try parse(arena, &.{ "cache", "prune", "--unused", "30d", "--dry-run" });
    try std.testing.expectEqual(@as(u64, 30 * std.time.ns_per_day), c.command.cache.prune.unused_ns.?);
}

test "the POC's form is build, with a flag for the warning" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const r = try parse(a.allocator(), &.{ "-o", "out", "./app" });
    try std.testing.expect(r.command.build.poc);
    try std.testing.expectEqualStrings("./app", r.command.build.source);
    try std.testing.expectEqualStrings("out", r.command.build.out.?);
    const d = try parse(a.allocator(), &.{"./app"});
    try std.testing.expect(d.command.build.poc);
}

test "usage errors" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try std.testing.expectError(error.Usage, parse(arena, &.{ "build", "--trust" }));
    try std.testing.expectError(error.Usage, parse(arena, &.{ "export", "." }));
    try std.testing.expectError(error.Usage, parse(arena, &.{ "export", "--docker", "--oci", "x.tar" }));
    try std.testing.expectError(error.Usage, parse(arena, &.{ "run", "--net", "wide" }));
    try std.testing.expectError(error.Usage, parse(arena, &.{ "pack", "--target", "macos-amd64" }));
    try std.testing.expectError(error.Usage, parse(arena, &.{ "cache", "rm" }));
    try std.testing.expectError(error.Usage, parse(arena, &.{ "build", "a", "b" }));
    try std.testing.expectError(error.Usage, parse(arena, &.{ "plan", "--", "x" }));
}
