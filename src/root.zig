//! h9x as a library (design/prototype.md, "The library"): the `h9x`
//! module that embedders import. The CLI is a client of the same code.
//!
//!   var b = try h9x.Builder.init(gpa, io, .{ .cache_dir = cache });
//!   defer b.deinit();
//!   const src = try b.source(.{ .git = .{ .url = "https://github.com/foo/bar", .ref = "v1.2" } });
//!   const plan = try b.plan(src, .{});
//!   const art = try b.build(plan, .{ .out_dir = "bar.h9" });
//!   var m = try art.machine(.{ .policy = .untrusted });
//!   const code = try m.run(&.{});
//!   try art.exportOci("bar.oci.tar");
//!   try art.pack("bar.tar", .{});
//!
//! Every value a step returns lives until `deinit`. Events go to
//! `on_event`, as the CLI's `--json` writes them (spec/events.md). A step
//! that fails returns its error, and the `log` events before it say why;
//! `exitCode` gives the CLI's exit code for one.

const std = @import("std");
const h9 = @import("h9");
pub const types = @import("types.zig");
const cli = @import("cli.zig");
const events_mod = @import("events.zig");
const policy_mod = @import("policy.zig");
const machine_mod = @import("machine.zig");
const source_mod = @import("source.zig");
const session = @import("session.zig");
const build_cmd = @import("cmd/build.zig");
const run_cmd = @import("cmd/run.zig");
const pack_cmd = @import("cmd/pack.zig");
const export_cmd = @import("cmd/export.zig");
const input = @import("cmd/input.zig");

pub const Source = types.Source;
pub const Layer = types.Layer;
pub const Event = types.Event;
pub const Trust = types.Trust;
pub const Target = types.Target;
pub const Exit = types.Exit;
pub const Stdio = machine_mod.Stdio;

/// The CLI's exit code for an error a step returned (spec/cli.md).
pub fn exitCode(err: anyerror) u8 {
    return events_mod.exitFor(err).code();
}

/// A machine's policy: the run phase's defaults for a trust level, then
/// `text`, h9 plan lines, which only narrow them.
pub const Policy = struct {
    trust: Trust = .trusted,
    text: []const u8 = "",

    /// `h9x run`'s defaults for a directory source.
    pub const local: Policy = .{};
    /// `h9x run`'s defaults for a remote source: no host files, no
    /// network, and a timeout.
    pub const untrusted: Policy = .{ .trust = .untrusted };
};

pub const Builder = struct {
    pub const Options = struct {
        /// Roots, runtimes, sources, and builds. Null is `H9X_CACHE` in
        /// `env`, or `${XDG_CACHE_HOME:-~/.cache}/h9x`.
        cache_dir: ?[]const u8 = null,
        machine: struct {
            /// h9's backend for every machine, as `H9X_BACKEND` names it.
            backend: ?[]const u8 = null,
        } = .{},
        /// What h9x reads from the host's environment: the proxy and CA
        /// variables, `H9X_*` settings, secrets named for builds, and
        /// `HOME` for the user's config. Null is none of them.
        env: ?*const std.process.Environ.Map = null,
        /// Called for each event, from the calling thread or a machine's
        /// output thread, one at a time.
        on_event: ?*const fn (ctx: ?*anyopaque, ev: Event) void = null,
        event_ctx: ?*anyopaque = null,
    };

    gpa: std.mem.Allocator,
    arena_state: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    emitter: events_mod.Emitter,
    discard_out: std.Io.Writer.Discarding,
    discard_err: std.Io.Writer.Discarding,
    ctx: cli.Context,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: Options) !*Builder {
        const b = try gpa.create(Builder);
        errdefer gpa.destroy(b);
        b.gpa = gpa;
        b.arena_state = .init(gpa);
        errdefer b.arena_state.deinit();
        b.env = .init(b.arena_state.allocator());
        if (opts.env) |e| try b.env.putAll(e);
        if (opts.cache_dir) |c| try b.env.put("H9X_CACHE", c);
        if (opts.machine.backend) |be| try b.env.put("H9X_BACKEND", be);
        b.discard_out = .init(&.{});
        b.discard_err = .init(&.{});
        b.emitter = .{ .w = &b.discard_err.writer, .json = true, .io = io };
        if (opts.on_event) |f| b.emitter.sink = .{ .ctx = opts.event_ctx, .func = f };
        b.ctx = .{
            .gpa = gpa,
            .arena = b.arena_state.allocator(),
            .io = io,
            .env = &b.env,
            .stdout = &b.discard_out.writer,
            .stderr = &b.discard_err.writer,
            .events = &b.emitter,
            .common = .{},
        };
        return b;
    }

    pub fn deinit(b: *Builder) void {
        const gpa = b.gpa;
        b.arena_state.deinit();
        gpa.destroy(b);
    }

    /// Secrets passed to build steps only, by name, read from `env`.
    pub fn setSecrets(b: *Builder, names: []const []const u8) !void {
        b.ctx.common.secrets = try b.ctx.arena.dupe([]const u8, names);
    }

    pub const SourceSpec = union(enum) {
        /// A directory on the host.
        dir: []const u8,
        git: struct { url: []const u8, ref: ?[]const u8 = null, subdir: ?[]const u8 = null },
        tarball: struct { url: []const u8, subdir: ?[]const u8 = null },
        /// A SOURCE as the CLI takes it.
        spec: []const u8,
    };

    /// Resolves a source: a directory's hash, or a git or tarball source
    /// fetched into the cache.
    pub fn source(b: *Builder, s: SourceSpec) !Source {
        const a = b.ctx.arena;
        const spec: []const u8 = switch (s) {
            .dir => |d| d,
            .spec => |x| x,
            .git => |g| try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{
                g.url,
                if (g.ref != null) "@" else "",
                g.ref orelse "",
                if (g.subdir != null) "//" else "",
                g.subdir orelse "",
            }),
            .tarball => |t| try std.fmt.allocPrint(a, "{s}{s}{s}", .{ t.url, if (t.subdir != null) "//" else "", t.subdir orelse "" }),
        };
        return source_mod.resolve(&b.ctx, spec, .{ .builder = &fetchBuilder }) catch |e| switch (e) {
            error.SourceNotFound => error.BadSource,
            else => e,
        };
    }

    fn fetchBuilder(ctx: *cli.Context) anyerror![]const u8 {
        const roots = @import("roots.zig");
        var e = try roots.Env.init(ctx, .{});
        e.cfg.railpack = null;
        const boot = try roots.bootstrap(e);
        const r = try roots.make(e, boot, .builder, try roots.packagesFor(e, .builder, &.{}));
        return r.path;
    }

    pub const PlanOptions = struct {
        /// Where the plan is kept, and the build writes. Null is
        /// `$cache/builds/KEY`.
        out_dir: ?[]const u8 = null,
        /// Run Railpack's planner even when the source hasn't changed.
        replan: bool = false,
    };

    /// Plans a source: Railpack in a machine, or the plan kept from last
    /// time. Makes the builder root.
    pub fn plan(b: *Builder, src: Source, opts: PlanOptions) !Plan {
        const pr = try build_cmd.prepare(&b.ctx, .{
            .source = src.spec,
            .resolved = src,
            .out = opts.out_dir,
            .replan = opts.replan,
            .cache_out = true,
        });
        return .{ .b = b, .prepared = pr };
    }

    pub const BuildOptions = struct {
        /// Where the build's output goes. Null is where the plan is kept.
        out_dir: ?[]const u8 = null,
    };

    /// Builds the layers a plan makes, keeping each whose key matches,
    /// and writes the output directory.
    pub fn build(b: *Builder, p: Plan, opts: BuildOptions) !Artifact {
        var pr = p.prepared;
        if (opts.out_dir) |o| {
            const abs = try std.fs.path.resolve(b.ctx.arena, &.{ try std.process.currentPathAlloc(b.ctx.io, b.ctx.arena), o });
            if (!std.mem.eql(u8, abs, pr.out)) {
                // The kept plan goes with it, so it isn't planned again.
                const cwd = std.Io.Dir.cwd();
                try cwd.createDirPath(b.ctx.io, abs);
                for (@import("plan.zig").kept_files) |f| {
                    const from = try std.fs.path.join(b.ctx.arena, &.{ pr.out, f });
                    const to = try std.fs.path.join(b.ctx.arena, &.{ abs, f });
                    std.Io.Dir.copyFile(cwd, from, cwd, to, b.ctx.io, .{}) catch {};
                }
                pr = try build_cmd.prepare(&b.ctx, .{ .source = pr.source.spec, .resolved = pr.source, .out = abs });
            }
        }
        const r = try build_cmd.finish(pr);
        return b.open(r.out, r.source.remote());
    }

    /// A build's output directory, as an artifact. `remote` is whether
    /// it was built from a git or tarball source.
    pub fn open(b: *Builder, out_dir: []const u8, remote: bool) !Artifact {
        var in = (try input.output(&b.ctx, out_dir)) orelse return error.NoArtifact;
        in.remote = remote;
        return .{ .b = b, .in = in };
    }
};

/// A plan: Railpack's, with the layer split and keys (`types.Plan`), and
/// the source and roots it was made with.
pub const Plan = struct {
    b: *Builder,
    prepared: build_cmd.Prepared,

    pub fn value(p: Plan) types.Plan {
        return p.prepared.plan;
    }

    /// Where the plan is kept: the build's output directory.
    pub fn dir(p: Plan) []const u8 {
        return p.prepared.out;
    }
};

/// A build's output: the stacked layers, the env, and the start command.
pub const Artifact = struct {
    b: *Builder,
    in: input.Input,

    pub fn value(a: Artifact) types.Artifact {
        return a.in.art;
    }

    /// The output directory, absolute.
    pub fn dir(a: Artifact) []const u8 {
        return a.in.dir;
    }

    /// The base root and the run layers, bottom first, as host paths.
    pub fn stack(a: Artifact) struct { base: []const u8, layers: []const Layer } {
        return .{ .base = a.in.base, .layers = a.in.layers };
    }

    pub const MachineOptions = struct {
        pub const Stage = enum { run };
        stage: Stage = .run,
        policy: Policy = .local,
        /// Host directories, as `--mount` gives them. Refused under an
        /// untrusted policy.
        mounts: []const types.Mount = &.{},
        net: ?types.Net = null,
        timeout_ns: ?u64 = null,
    };

    /// A machine on the run stage, under `opts.policy`: start it with
    /// `run`.
    pub fn machine(a: Artifact, opts: MachineOptions) !Machine {
        const ctx = &a.b.ctx;
        const ar = ctx.arena;
        const delta = try session.runDelta(ar, a.in.base, a.in.layers, a.in.art.env, a.in.art.cwd);
        var p = try run_cmd.policyFor(ctx, a.in.cfg, opts.policy.trust, delta, .{
            .mounts = opts.mounts,
            .net = opts.net,
            .timeout_ns = opts.timeout_ns,
        }, a.in.art.start);
        if (opts.policy.text.len > 0) {
            var diag: policy_mod.Diag = .{};
            const by = policy_mod.parse(ar, opts.policy.text, &diag) catch |e| switch (e) {
                error.Syntax => return ctx.events.failErr(error.BadPolicy, "policy: {s}", .{diag.msg}),
                error.OutOfMemory => return e,
            };
            p = policy_mod.narrow(ar, p, by, &diag) catch |e| switch (e) {
                error.Widens => return ctx.events.failErr(error.PolicyWidens, "policy: {s}", .{diag.msg}),
                error.OutOfMemory => return e,
            };
        }
        return .{ .b = a.b, .policy = p };
    }

    /// Writes an OCI image layout, as a tar, to `path`.
    pub fn exportOci(a: Artifact, path: []const u8) !void {
        try check(&a.b.ctx, try export_cmd.run(&a.b.ctx, .{ .source = a.in.dir, .format = .{ .oci = path } }));
    }

    pub const PackOptions = struct {
        /// Executables rather than a tar: the host's with no targets.
        exe: bool = false,
        targets: []const Target = &.{},
        /// `--runner` values: FILE or TARGET=FILE.
        runners: []const []const u8 = &.{},
        mounts: []const types.Mount = &.{},
        debug: bool = true,
    };

    /// Writes a pack to `path`, or with `exe`, an executable to `path`
    /// (one target) or one per target into the directory `path`.
    pub fn pack(a: Artifact, path: []const u8, opts: PackOptions) !void {
        try check(&a.b.ctx, try pack_cmd.run(&a.b.ctx, .{
            .source = a.in.dir,
            .out = path,
            .exe = opts.exe or opts.targets.len > 0,
            .targets = opts.targets,
            .runners = opts.runners,
            .mounts = opts.mounts,
            .no_debug = !opts.debug,
        }));
    }

    fn check(ctx: *cli.Context, code: u8) !void {
        _ = ctx;
        return switch (code) {
            0 => {},
            2 => error.Usage,
            else => error.Failed,
        };
    }
};

/// A machine's policy, ready to start.
pub const Machine = struct {
    b: *Builder,
    policy: types.Policy,

    /// The policy as h9 plan text, as `--print` shows it.
    pub fn print(m: Machine, w: *std.Io.Writer) !void {
        try policy_mod.print(m.policy, w);
    }

    /// Starts the machine and runs `argv`, or the start command if it's
    /// empty, with the process's stdin, stdout, and stderr. Returns the
    /// program's exit code (124 for a timeout).
    pub fn run(m: *Machine, argv: []const []const u8) !u8 {
        const ctx = &m.b.ctx;
        var p = m.policy;
        if (argv.len > 0) p.run = argv;
        return session.interactive(ctx, try run_cmd.hostFor(ctx), p, null);
    }

    /// `run`, with the given stdio instead of the process's.
    pub fn runWith(m: *Machine, argv: []const []const u8, stdio: Stdio) !u8 {
        const ctx = &m.b.ctx;
        const a = ctx.arena;
        var p = m.policy;
        if (argv.len > 0) p.run = argv;
        var diag: policy_mod.Diag = .{};
        var o = policy_mod.compile(a, p, &diag) catch |e| switch (e) {
            error.Conflict => return ctx.events.failErr(error.PolicyConflict, "policy: {s}", .{diag.msg}),
            error.OutOfMemory => return e,
        };
        const prog = (try policy_mod.command(a, p, &.{})) orelse return ctx.events.failErr(error.Usage, "nothing to run", .{});
        o.stdio = stdio;
        o.guest_tools = false;
        o.console_tty = false;
        var why: []const u8 = "";
        const status = machine_mod.run(ctx.gpa, a, ctx.io, try run_cmd.hostFor(ctx), o, prog, &why) catch |e| {
            ctx.events.log("run: {s}", .{if (why.len > 0) why else @errorName(e)});
            return error.MachineFailed;
        };
        return machine_mod.exitCode(status);
    }
};

test "the library's surface compiles" {
    std.testing.refAllDecls(Builder);
    std.testing.refAllDecls(Artifact);
    std.testing.refAllDecls(Machine);
    std.testing.refAllDecls(Plan);
}

test "a Builder starts and ends without touching the cache" {
    var b = try Builder.init(std.testing.allocator, std.testing.io, .{ .cache_dir = "/nonexistent/h9x-cache" });
    defer b.deinit();
    try std.testing.expectEqualStrings("/nonexistent/h9x-cache", b.env.get("H9X_CACHE").?);
    const src = b.source(.{ .dir = "/nonexistent/h9x-source" });
    try std.testing.expectError(error.BadSource, src);
}
