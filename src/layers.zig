//! Layers (design/prototype.md, "The build engine"): building the runtime,
//! deps, and app layers with the embedded build.sh, each as an up layer
//! over the builder root and the layers below, the shared runtime layer,
//! pruning, and `layers.txt`.
//!
//! Each layer is built by `build.sh LAYER` in its own machine: the builder
//! root, the layers below stacked over it read-only, and the new layer's
//! `.tmp` directory as the up layer on top, so whatever its steps change
//! lands there as an OCI layer with `.wh.` whiteouts. It's moved into
//! place when its steps succeed, so a failed step leaves no layer.
//!
//! Keys chain: the runtime layer's shared key (the builder root, build.sh,
//! the plan's runtime steps, and the architecture), then each layer's own
//! key from the plan over the one below, so changing the app's code
//! rebuilds only the app layer.

const std = @import("std");
const build_options = @import("build_options");
const types = @import("types.zig");
const events = @import("events.zig");
const roots = @import("roots.zig");
const embedded = @import("embedded.zig");
const cache = @import("cache.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const LayerName = types.LayerName;

pub const Input = struct {
    env: roots.Env,
    plan: types.Plan,
    source: types.Source,
    builder: types.Root,
    /// The output directory, absolute: the build machines' cwd, where
    /// build.sh finds plan.json and steps.txt and keeps `cache/`.
    out: []const u8,
    /// `$cache/tools`, with mise, at /h9x/tools.
    tools: []const u8,
    /// The guest scripts, at /h9x/guest.
    guest_dir: []const u8,
    /// A guest path under the source to hide with an empty tree: the
    /// output directory, when it's inside the source.
    hide: ?[]const u8 = null,
};

/// What `build` made.
pub const Built = struct {
    /// Every layer, built or kept, bottom first, with absolute paths.
    all: [3]types.Layer,
    /// The layers the run stacks (`layers.txt`), bottom first.
    stack: []const LayerName,
    /// The run environment (`env`): `NAME=VALUE` lines.
    env: []const []const u8,
};

/// The runtime layer's shared key.
pub fn runtimeKey(arena: std.mem.Allocator, arch: types.Arch, builder: []const u8, shared_key: []const u8, ruby_compile: bool) ![]const u8 {
    const bh = try roots.shortHash(arena, embedded.build_sh);
    return roots.shortHash(arena, try std.fmt.allocPrint(arena, "runtime {s} {s} {s} {s} {s} {s}\n", .{
        arch.linuxName(),
        std.fs.path.basename(builder),
        bh,
        shared_key,
        if (ruby_compile) "1" else "",
        build_options.version,
    }));
}

/// The next key in the chain: `below`'s, then the layer's own.
pub fn chain(arena: std.mem.Allocator, below: []const u8, own: []const u8) ![]const u8 {
    return roots.shortHash(arena, try std.fmt.allocPrint(arena, "{s} {s}\n", .{ below, own }));
}

/// Builds the layers the plan's steps make, keeping each whose key
/// matches, then prunes the app layer and writes `layers.txt` and `env`.
pub fn build(in: Input) !Built {
    const e = in.env;
    const ctx = e.ctx;
    const a = ctx.arena;
    const io = ctx.io;
    const cwd = Dir.cwd();
    const layers_dir = try std.fs.path.join(a, &.{ in.out, "layers" });
    try cwd.createDirPath(io, layers_dir);
    try cwd.createDirPath(io, try std.fs.path.join(a, &.{ in.out, "cache" }));
    for ([_][]const u8{ "run", "layers.txt" }) |f|
        cwd.deleteFile(io, try std.fs.path.join(a, &.{ in.out, f })) catch {};
    // What an interrupted build left.
    {
        var d = try cwd.openDir(io, layers_dir, .{ .iterate = true });
        defer d.close(io);
        var stale: std.ArrayList([]const u8) = .empty;
        var it = d.iterate();
        while (try it.next(io)) |ent| {
            if (std.mem.endsWith(u8, ent.name, ".tmp") or std.mem.endsWith(u8, ent.name, ".keep") or std.mem.endsWith(u8, ent.name, ".small"))
                try stale.append(a, try std.fs.path.join(a, &.{ layers_dir, ent.name }));
        }
        for (stale.items) |s| cache.removeTree(io, s) catch {};
    }

    var built: Built = .{ .all = undefined, .stack = &.{}, .env = &.{} };
    // Whether any layer was built, so `env` is made again.
    var rebuilt = false;
    var lowers: std.ArrayList([]const u8) = .empty;

    // The runtime layer: shared between apps in $cache/runtimes.
    const rkey = try runtimeKey(a, e.arch, in.builder.path, in.plan.shared_key, e.cfg.ruby_compile);
    var key = try chain(a, rkey, in.plan.keys.runtime);
    const rdir = try e.path(.runtimes, rkey);
    if (exists(io, rdir)) {
        ctx.events.emit(.{ .layer = .{ .layer = .runtime, .state = .shared, .key = rkey } });
        cache.touch(io, rdir);
    } else {
        // A name of its own, since another build may be making the same one.
        var nonce: [4]u8 = undefined;
        io.random(&nonce);
        const t = try e.path(.runtimes, try std.fmt.allocPrint(a, ".{s}.tmp-{x}", .{ rkey, nonce }));
        cache.removeTree(io, t) catch {};
        try cwd.createDirPath(io, t);
        errdefer cache.removeTree(io, t) catch {};
        rebuilt = true;
        if (hasSteps(in.plan, .runtime)) {
            ctx.events.emit(.{ .layer = .{ .layer = .runtime, .state = .building, .key = rkey } });
            try runBuild(in, .runtime, lowers.items, t);
        }
        cache.removeTree(io, try std.fs.path.join(a, &.{ t, "app" })) catch {};
        // Another build may have made it meanwhile; either is the same.
        if (exists(io, rdir)) {
            cache.removeTree(io, t) catch {};
        } else {
            try Dir.rename(cwd, t, cwd, rdir, io);
        }
        ctx.events.emit(.{ .layer = .{ .layer = .runtime, .state = .done, .key = rkey } });
    }
    const rlink = try std.fs.path.join(a, &.{ layers_dir, "runtime" });
    cache.removeTree(io, rlink) catch {};
    cwd.deleteFile(io, try std.fs.path.join(a, &.{ layers_dir, "runtime.key" })) catch {};
    try cwd.symLink(io, rdir, rlink, .{ .is_directory = true });
    built.all[0] = .{ .name = .runtime, .key = rkey, .path = rdir };
    try lowers.append(a, rdir);

    // deps and app, in the output directory.
    for ([_]LayerName{ .deps, .app }, 1..) |l, i| {
        key = try chain(a, key, if (l == .deps) in.plan.keys.deps else in.plan.keys.app);
        const d = try std.fs.path.join(a, &.{ layers_dir, @tagName(l) });
        const kf = try std.fmt.allocPrint(a, "{s}.key", .{d});
        const kept = cwd.readFileAlloc(io, kf, a, .limited(256)) catch "";
        if (exists(io, d) and std.mem.eql(u8, std.mem.trimEnd(u8, kept, "\n"), key)) {
            ctx.events.emit(.{ .layer = .{ .layer = l, .state = .cached, .key = key } });
        } else {
            rebuilt = true;
            cache.removeTree(io, d) catch {};
            cwd.deleteFile(io, kf) catch {};
            const t = try std.fmt.allocPrint(a, "{s}.tmp", .{d});
            try cwd.createDirPath(io, t);
            errdefer cache.removeTree(io, t) catch {};
            if (hasSteps(in.plan, l) or (l == .deps and in.plan.runtime_copies)) {
                ctx.events.emit(.{ .layer = .{ .layer = l, .state = .building, .key = key } });
                try runBuild(in, l, lowers.items, t);
            }
            try Dir.rename(cwd, t, cwd, d, io);
            try cwd.writeFile(io, .{ .sub_path = kf, .data = try std.fmt.allocPrint(a, "{s}\n", .{key}) });
            ctx.events.emit(.{ .layer = .{ .layer = l, .state = .done, .key = key } });
        }
        built.all[i] = .{ .name = l, .key = key, .path = d };
        try lowers.append(a, d);
    }

    // The run environment, from every layer's steps, made again when a
    // layer was. The runtime layer's key is in the chain, so a new shared
    // runtime is a rebuilt deps layer.
    const env_path = try std.fs.path.join(a, &.{ in.out, "env" });
    if (rebuilt or !exists(io, env_path)) {
        cwd.deleteFile(io, env_path) catch {};
        try runBuild(in, null, lowers.items, null);
    }
    const env_text = cwd.readFileAlloc(io, env_path, a, .limited(1 << 20)) catch {
        ctx.events.log("build.sh env wrote no env", .{});
        return error.StepFailed;
    };
    var env: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, env_text, '\n');
    while (lines.next()) |ln| if (ln.len > 0) try env.append(a, ln);
    built.env = env.items;

    built.stack = try prune(a, io, in.out, in.plan.deploy);
    var lt: Io.Writer.Allocating = .init(a);
    for (built.stack) |l| try lt.writer.print("{t}\n", .{l});
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ in.out, "layers.txt" }), .data = lt.written() });
    return built;
}

fn hasSteps(p: types.Plan, l: LayerName) bool {
    for (p.steps) |s| if (s.layer == l) return true;
    return false;
}

/// Runs `build.sh LAYER` (or `build.sh env` for null) in a build machine:
/// the builder root, the tools, the guest scripts, the source, the
/// `lowers` read-only over the root, and `up` as the up layer.
fn runBuild(in: Input, layer: ?LayerName, lowers: []const []const u8, up: ?[]const u8) !void {
    const e = in.env;
    const ctx = e.ctx;
    const a = ctx.arena;
    const src_dst = try std.fmt.allocPrint(a, "/h9x/src/{s}", .{in.source.name});
    var mounts: std.ArrayList(types.Mount) = .empty;
    try mounts.appendSlice(a, &.{
        .{ .kind = .dir, .src = in.builder.path, .dst = "#L", .access = .ro },
        .{ .kind = .dir, .src = in.tools, .dst = "/h9x/tools", .access = .ro },
        .{ .kind = .dir, .src = in.guest_dir, .dst = "/h9x/guest", .access = .ro },
        .{ .kind = .dir, .src = in.source.path, .dst = src_dst, .access = .ro },
    });
    if (in.hide) |h| try mounts.append(a, .{ .kind = .tmp, .dst = h });
    for (lowers) |l| try mounts.append(a, .{ .kind = .dir, .src = l, .dst = "#L", .access = .ro });
    if (up) |u| try mounts.append(a, .{ .kind = .dir, .src = u, .dst = "#L", .access = .up });
    try mounts.append(a, .{ .kind = .tmp, .dst = "/tmp" });

    var env: std.ArrayList(types.EnvVar) = .empty;
    try env.appendSlice(a, &.{
        .{ .name = "HOME", .value = "/root" },
        .{ .name = "H9X_SRC", .value = src_dst },
        .{ .name = "H9X_RUBY_COMPILE", .value = if (e.cfg.ruby_compile) "1" else "" },
    });
    try env.appendSlice(a, try e.passEnv());

    const p = try e.policyFor(.{
        .phase = .build,
        .trust = e.trust,
        .providers = if (in.plan.provider.len > 0) try a.dupe([]const u8, &.{in.plan.provider}) else &.{},
        .machine = .{ .mounts = mounts.items, .env = env.items, .netallow_add = try e.proxyAllow() },
        .secrets = ctx.common.secrets,
    });

    var steps: Steps = .{ .ctx = ctx, .layer = layer orelse .app };
    var obuf: [4096]u8 = undefined;
    var ebuf: [4096]u8 = undefined;
    steps.out = ctx.events.output(layer, null, .stdout, &obuf);
    steps.err = ctx.events.output(layer, null, .stderr, &ebuf);
    steps.interface = .{ .buffer = &.{}, .vtable = &.{ .drain = Steps.drain, .flush = Steps.flush } };
    steps.track = layer != null;
    const arg = if (layer) |l| @tagName(l) else "env";
    const code = roots.guest(e, p, in.out, &.{ "/bin/sh", "/h9x/guest/build.sh", arg }, .{ .out = &steps.out.interface, .err = &steps.interface }) catch |err| {
        steps.finish(null);
        if (layer) |l| ctx.events.emit(.{ .layer = .{ .layer = l, .state = .failed, .key = "" } });
        return err;
    };
    steps.interface.flush() catch {};
    steps.finish(code);
    if (code != 0) {
        if (layer) |l| {
            ctx.events.emit(.{ .layer = .{ .layer = l, .state = .failed, .key = "" } });
        } else ctx.events.log("build.sh env exited {d}", .{code});
        return error.StepFailed;
    }
}

/// build.sh's stderr, as `step` events: its `h9x: step NAME` lines start
/// a step, and the output between them is that step's.
const Steps = struct {
    ctx: *@import("cli.zig").Context,
    layer: LayerName,
    track: bool = true,
    out: events.Output = undefined,
    err: events.Output = undefined,
    interface: Io.Writer = undefined,
    line: [4096]u8 = undefined,
    len: usize = 0,
    step: ?[]const u8 = null,
    started: ?Io.Timestamp = null,

    const marker = "h9x: step ";

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const s: *Steps = @alignCast(@fieldParentPtr("interface", w));
        var n: usize = 0;
        for (data, 0..) |d, i| {
            const times = if (i == data.len - 1) splat else 1;
            for (0..times) |_| {
                for (d) |c| s.byte(c);
                n += d.len;
            }
        }
        return n;
    }

    fn flush(w: *Io.Writer) Io.Writer.Error!void {
        const s: *Steps = @alignCast(@fieldParentPtr("interface", w));
        s.emitLine();
        s.err.interface.flush() catch {};
    }

    fn byte(s: *Steps, c: u8) void {
        s.line[s.len] = c;
        s.len += 1;
        if (c == '\n' or s.len == s.line.len) s.emitLine();
    }

    fn emitLine(s: *Steps) void {
        if (s.len == 0) return;
        const l = s.line[0..s.len];
        s.len = 0;
        if (s.track and std.mem.startsWith(u8, l, marker)) {
            const name = std.mem.trimEnd(u8, l[marker.len..], "\r\n");
            s.finish(0);
            const owned = s.ctx.arena.dupe(u8, name) catch return;
            s.step = owned;
            s.started = Io.Timestamp.now(s.ctx.io, .awake);
            s.out.step = owned;
            s.err.step = owned;
            s.ctx.events.emit(.{ .step = .{ .layer = s.layer, .step = owned, .state = .start } });
            return;
        }
        s.err.interface.writeAll(l) catch {};
    }

    /// Ends the current step with `status`, or as failed for null.
    fn finish(s: *Steps, status: ?u8) void {
        s.out.interface.flush() catch {};
        s.err.interface.flush() catch {};
        const name = s.step orelse return;
        const ms: u64 = if (s.started) |t| @intCast(@max(t.untilNow(s.ctx.io, .awake).toMilliseconds(), 0)) else 0;
        if (status) |st| {
            s.ctx.events.emit(.{ .step = .{ .layer = s.layer, .step = name, .state = .exit, .status = st, .ms = ms } });
        } else {
            s.ctx.events.emit(.{ .step = .{ .layer = s.layer, .step = name, .state = .failed, .ms = ms } });
        }
        s.step = null;
    }
};

// ---------------------------------------------------------------- pruning

/// A deps deploy smaller than this is copied into the app layer, so the
/// run needn't stack deps for it.
pub const small_deps = 1 << 20;

/// Prunes the app layer to what the plan deploys from it, copies a small
/// deps deploy into it, gives it the runtime's /usr/lib when the runtime
/// isn't run, and returns the layers the run stacks.
pub fn prune(a: std.mem.Allocator, io: Io, out: []const u8, deploy: []const types.Deploy) ![]const LayerName {
    const cwd = Dir.cwd();
    const app = try std.fs.path.join(a, &.{ out, "layers", "app" });
    const keep = try std.fmt.allocPrint(a, "{s}.keep", .{app});
    cache.removeTree(io, keep) catch {};
    try cwd.createDirPath(io, keep);

    // The paths the plan deploys from the app layer.
    var paths: std.ArrayList([]const u8) = .empty;
    var excl: std.ArrayList([]const u8) = .empty;
    for (deploy) |d| if (d.layer == .app) {
        try paths.append(a, d.path);
        try excl.appendSlice(a, d.exclude);
    };
    for (uniqueSorted(paths.items)) |p| {
        const from = try join(a, app, p);
        if (!exists(io, from)) continue;
        const to = try join(a, keep, p);
        try cwd.createDirPath(io, std.fs.path.dirname(to).?);
        try Dir.rename(cwd, from, cwd, to, io);
    }
    // Less their excludes. An exclude that another input takes is kept,
    // and one that a layer below holds is whited out, so it doesn't show
    // through.
    outer: for (uniqueSorted(excl.items)) |x| {
        for (deploy) |d| if (d.layer != .runtime and (std.mem.eql(u8, d.path, x) or under(d.path, x))) continue :outer;
        cache.removeTree(io, try join(a, keep, x)) catch {};
        for ([_][]const u8{ "deps", "runtime" }) |l| {
            if (!exists(io, try join(a, try std.fs.path.join(a, &.{ out, "layers", l }), x))) continue;
            const parent = try join(a, keep, std.fs.path.dirname(x) orelse "/");
            try cwd.createDirPath(io, parent);
            const wh = try std.fmt.allocPrint(a, "{s}/.wh.{s}", .{ parent, std.fs.path.basename(x) });
            try cwd.writeFile(io, .{ .sub_path = wh, .data = "" });
            break;
        }
    }
    cache.removeTree(io, app) catch {};
    try Dir.rename(cwd, keep, cwd, app, io);

    // What the build deploys from the deps layer, when it's small (Rust's
    // Cargo.lock, beside a target the plan excludes), is copied into the
    // app layer. A node_modules or a venv is left in deps, which the run
    // stacks.
    const deps = try std.fs.path.join(a, &.{ out, "layers", "deps" });
    var small = false;
    if (exists(io, deps)) {
        const x = try std.fmt.allocPrint(a, "{s}.small", .{deps});
        cache.removeTree(io, x) catch {};
        try cwd.createDirPath(io, x);
        defer cache.removeTree(io, x) catch {};
        for (deploy) |d| if (d.layer == .app) {
            const from = try join(a, deps, d.path);
            if (!exists(io, from)) continue;
            try copyTree(a, io, from, try join(a, x, d.path), .{ .exclude = d.exclude, .guest_path = d.path, .skip_whiteouts = true });
        };
        if (try treeSize(a, io, x) < small_deps) {
            try copyTree(a, io, x, app, .{ .no_clobber = true });
            small = true;
        }
    }

    const runtime = try holds(a, io, out, .runtime, &.{.runtime}, deploy);
    const app_used = !(try isEmpty(io, app));
    // Libraries a packages step put in the system's /usr/lib for a
    // runtime (Ubuntu's libcrypto, for Hex's Erlang) go with the app when
    // the runtime layer doesn't: a Mix release carries Erlang out of it.
    const rlib = try std.fs.path.join(a, &.{ out, "layers", "runtime", "usr", "lib" });
    if (!runtime and app_used and exists(io, rlib)) {
        try copyTree(a, io, rlib, try std.fs.path.join(a, &.{ app, "usr", "lib" }), .{});
    }

    var stack: std.ArrayList(LayerName) = .empty;
    if (runtime) try stack.append(a, .runtime);
    const from: []const LayerName = if (small) &.{.deps} else &.{ .deps, .app };
    if (try holds(a, io, out, .deps, from, deploy)) try stack.append(a, .deps);
    if (app_used) try stack.append(a, .app);
    return stack.items;
}

/// Whether `layer` holds a path the plan deploys from the `which` layers.
/// A link counts, though it may not resolve from the host (dotnet's
/// 6.0 -> ./6.0.428 -> /mise/dotnet-root).
fn holds(a: std.mem.Allocator, io: Io, out: []const u8, layer: LayerName, which: []const LayerName, deploy: []const types.Deploy) !bool {
    const dir = try std.fs.path.join(a, &.{ out, "layers", @tagName(layer) });
    for (deploy) |d| {
        if (std.mem.indexOfScalar(LayerName, which, d.layer) == null) continue;
        if (exists(io, try join(a, dir, d.path))) return true;
    }
    return false;
}

fn uniqueSorted(items: [][]const u8) []const []const u8 {
    std.mem.sort([]const u8, items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    var n: usize = 0;
    for (items) |x| {
        if (n > 0 and std.mem.eql(u8, items[n - 1], x)) continue;
        items[n] = x;
        n += 1;
    }
    return items[0..n];
}

/// Whether guest path `p` is below `dir`.
fn under(p: []const u8, dir: []const u8) bool {
    return p.len > dir.len and std.mem.startsWith(u8, p, dir) and p[dir.len] == '/';
}

/// A guest path under a host directory.
fn join(a: std.mem.Allocator, dir: []const u8, guest_path: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ dir, std.mem.trimStart(u8, guest_path, "/") });
}

/// Whether `p` is there, a dangling link included.
pub fn exists(io: Io, p: []const u8) bool {
    _ = Dir.cwd().statFile(io, p, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn isEmpty(io: Io, p: []const u8) !bool {
    var d = Dir.cwd().openDir(io, p, .{ .iterate = true }) catch return true;
    defer d.close(io);
    var it = d.iterate();
    return (try it.next(io)) == null;
}

/// The bytes of the files under `p`.
fn treeSize(a: std.mem.Allocator, io: Io, p: []const u8) !u64 {
    var d = try Dir.cwd().openDir(io, p, .{ .iterate = true });
    defer d.close(io);
    var w = try d.walk(a);
    defer w.deinit();
    var n: u64 = 0;
    while (try w.next(io)) |ent| {
        if (ent.kind != .file) continue;
        const st = try ent.dir.statFile(io, ent.basename, .{ .follow_symlinks = false });
        n += st.size;
    }
    return n;
}

const CopyOptions = struct {
    /// Leave a file that's already at the destination.
    no_clobber: bool = false,
    /// Leave out `.wh.*` entries.
    skip_whiteouts: bool = false,
    /// Guest paths to leave out, with `guest_path` the source's.
    exclude: []const []const u8 = &.{},
    guest_path: []const u8 = "/",
};

/// Copies a file, link, or tree, keeping modes and links.
fn copyTree(a: std.mem.Allocator, io: Io, from: []const u8, to: []const u8, o: CopyOptions) !void {
    const cwd = Dir.cwd();
    const st = try cwd.statFile(io, from, .{ .follow_symlinks = false });
    if (st.kind != .directory) {
        try cwd.createDirPath(io, std.fs.path.dirname(to).?);
        return copyOne(a, io, cwd, from, st.kind, to, o.no_clobber);
    }
    try cwd.createDirPath(io, to);
    var d = try cwd.openDir(io, from, .{ .iterate = true });
    defer d.close(io);
    var w = try d.walk(a);
    defer w.deinit();
    while (try w.next(io)) |ent| {
        if (o.skip_whiteouts and std.mem.startsWith(u8, ent.basename, ".wh.")) continue;
        if (o.exclude.len > 0) {
            const gp = try std.fs.path.join(a, &.{ o.guest_path, ent.path });
            var skip = false;
            for (o.exclude) |x| if (std.mem.eql(u8, gp, x) or under(gp, x)) {
                skip = true;
            };
            if (skip) continue;
        }
        const dst = try std.fs.path.join(a, &.{ to, ent.path });
        switch (ent.kind) {
            .directory => try cwd.createDirPath(io, dst),
            else => try copyOne(a, io, ent.dir, ent.basename, ent.kind, dst, o.no_clobber),
        }
    }
}

fn copyOne(a: std.mem.Allocator, io: Io, dir: Dir, name: []const u8, kind: std.Io.File.Kind, to: []const u8, no_clobber: bool) !void {
    const cwd = Dir.cwd();
    if (exists(io, to)) {
        if (no_clobber) return;
        cwd.deleteFile(io, to) catch {};
    }
    switch (kind) {
        .sym_link => {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const n = try dir.readLink(io, name, &buf);
            try cwd.symLink(io, buf[0..n], to, .{});
        },
        .file => try Dir.copyFile(dir, name, cwd, to, io, .{}),
        else => {},
    }
    _ = a;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn mk(io: Io, dir: Dir, p: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(p)) |d| try dir.createDirPath(io, d);
    try dir.writeFile(io, .{ .sub_path = p, .data = data });
}

test "chain keys change with what's below" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r1 = try runtimeKey(a, .amd64, "/c/roots/builder-1", "s", false);
    const r2 = try runtimeKey(a, .amd64, "/c/roots/builder-2", "s", false);
    try testing.expect(!std.mem.eql(u8, r1, r2));
    try testing.expect(!std.mem.eql(u8, try chain(a, r1, "d"), try chain(a, r2, "d")));
    try testing.expectEqualStrings(try chain(a, r1, "d"), try chain(a, r1, "d"));
}

test "prune keeps the deploy, whites out excludes below, and copies small deps" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    // A Rust-shaped build: the app layer has the binary and a target that
    // the plan excludes, which deps holds too, and Cargo.lock is in deps.
    try mk(io, tmp.dir, "layers/app/app/bin/server", "elf");
    try mk(io, tmp.dir, "layers/app/app/target/big", "x");
    try mk(io, tmp.dir, "layers/app/root/.cargo/junk", "x");
    try mk(io, tmp.dir, "layers/deps/app/target/dep", "x");
    try mk(io, tmp.dir, "layers/deps/app/Cargo.lock", "lock");
    try tmp.dir.createDirPath(io, "layers/runtime/mise");
    const deploy = [_]types.Deploy{
        .{ .layer = .app, .path = "/app", .exclude = &.{"/app/target"} },
        .{ .layer = .runtime, .path = "/mise/shims" },
    };
    const stack = try prune(a, io, root, &deploy);
    try testing.expect(exists(io, try std.fs.path.join(a, &.{ root, "layers/app/app/bin/server" })));
    try testing.expect(!exists(io, try std.fs.path.join(a, &.{ root, "layers/app/root" })));
    try testing.expect(!exists(io, try std.fs.path.join(a, &.{ root, "layers/app/app/target" })));
    try testing.expect(exists(io, try std.fs.path.join(a, &.{ root, "layers/app/app/.wh.target" })));
    try testing.expect(exists(io, try std.fs.path.join(a, &.{ root, "layers/app/app/Cargo.lock" })));
    try testing.expectEqualSlices(LayerName, &.{.app}, stack);
}

test "prune stacks deps that hold a deployed path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    try mk(io, tmp.dir, "layers/app/app/server.js", "js");
    try mk(io, tmp.dir, "layers/deps/app/node_modules/big/index.js", "x");
    var big: [small_deps + 1]u8 = undefined;
    @memset(&big, 'x');
    try mk(io, tmp.dir, "layers/deps/app/node_modules/big/blob", &big);
    try mk(io, tmp.dir, "layers/runtime/mise/installs/node/22/bin/node", "elf");
    const deploy = [_]types.Deploy{
        .{ .layer = .app, .path = "/app" },
        .{ .layer = .runtime, .path = "/mise/installs" },
    };
    const stack = try prune(a, io, root, &deploy);
    try testing.expectEqualSlices(LayerName, &.{ .runtime, .deps, .app }, stack);
}
