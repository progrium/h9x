//! `h9x run`: build, then run the start command, or the command after
//! `--`, on the run stage. A remote source runs under the untrusted profile
//! unless `--trust` is given.
//!
//! The run stage is the base root with the run layers stacked over it
//! read-only, writes going to an overlay that's thrown away at exit, under
//! the run phase's policy: the defaults for the source's trust, then the
//! config, then the flags, which only narrow. `--mount` adds host
//! directories (refused for an untrusted source), `--net` sets the network
//! mode, and `--listen` asks for `net enable`.

const std = @import("std");
const cli = @import("../cli.zig");
const types = @import("../types.zig");
const config = @import("../config.zig");
const cache = @import("../cache.zig");
const machine = @import("../machine.zig");
const session = @import("../session.zig");
const source = @import("../source.zig");
const input = @import("input.zig");
const print = @import("print.zig");

pub fn run(ctx: *cli.Context, opts: cli.RunOptions) !u8 {
    if (opts.listen.len > 0) if (opts.net) |n| if (n != .enable)
        return ctx.events.fail(error.Usage, "--listen needs net enable, and --net is {t}", .{n});
    if (ctx.common.print) return print.phases(ctx, .{ .source = opts.source, .command = .run, .run = opts });

    const in = try input.resolve(ctx, opts.source);
    ctx.result_out = in.dir;
    const trust = trustFor(ctx, in.cfg, opts.source, in.remote, opts.trust);
    const p = try policyFor(ctx, in.cfg, trust, try session.runDelta(ctx.arena, in.base, in.layers, in.art.env, in.art.cwd), opts, in.art.start);
    for (in.layers) |l| cache.touch(ctx.io, l.path);
    if (trust == .untrusted) ctx.events.log("running {s} untrusted: no host files, no network, and a 10m timeout unless flags say otherwise; h9's sandbox isn't audited", .{opts.source});

    const host = try hostFor(ctx);
    return session.interactive(ctx, host, p, null);
}

/// A run's trust: a remote source is untrusted unless `--trust` is given
/// or the user's config trusts it (`[run] trusted`).
pub fn trustFor(ctx: *cli.Context, cfg: config.Config, spec: []const u8, remote: bool, flag: bool) types.Trust {
    if (!remote or flag) return .trusted;
    const url: ?[]const u8 = switch (source.parse(ctx.arena, spec) catch return .untrusted) {
        .dir => null,
        .git => |g| g.url,
        .tarball => |t| t.url,
    };
    return if (config.trusts(cfg, spec, url)) .trusted else .untrusted;
}

/// The run phase's policy for `machine_delta` (the stage's mounts, env,
/// and cwd), with `opts`' mounts, network, timeout, and program.
pub fn policyFor(
    ctx: *cli.Context,
    cfg: config.Config,
    trust: types.Trust,
    machine_delta: @import("../policy.zig").Delta,
    opts: cli.RunOptions,
    start: ?[]const u8,
) !types.Policy {
    const a = ctx.arena;
    var m = machine_delta;
    m.run = try session.program(a, opts.argv, start);
    const net: ?types.Net = opts.net orelse if (opts.listen.len > 0) .enable else null;
    return config.policyFor(ctx, cfg, .{
        .phase = .run,
        .trust = trust,
        .machine = m,
        .host_mounts = try hostMounts(ctx, opts.mounts),
        .flags = .{ .timeout_ns = opts.timeout_ns },
        .net = net,
    }) catch |e| switch (e) {
        error.Widens => error.PolicyWidens,
        error.Config => error.BadConfig,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// `--mount`s with their host paths made absolute. A path that doesn't
/// exist is exit 2.
pub fn hostMounts(ctx: *cli.Context, mounts: []const types.Mount) ![]const types.Mount {
    const out = try ctx.arena.alloc(types.Mount, mounts.len);
    for (mounts, out) |m, *o| {
        o.* = m;
        o.src = std.Io.Dir.cwd().realPathFileAlloc(ctx.io, m.src, ctx.arena) catch
            return ctx.events.failErr(error.Usage, "--mount {s}:{s}: {s} doesn't exist", .{ m.src, m.dst, m.src });
    }
    return out;
}

/// The host's settings for a machine: the proxy, CA bundle, DNS, and
/// backend.
pub fn hostFor(ctx: *cli.Context) !machine.Host {
    const cache_dir = try cache.dir(ctx.arena, ctx.env);
    return machine.Host.init(ctx.arena, ctx.io, ctx.env, cache_dir) catch |e| switch (e) {
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
}
