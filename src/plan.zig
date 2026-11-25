//! Plans (design/prototype.md, "The build engine"): running Railpack in a
//! machine on the builder root, reading `plan.json` into a `Plan` with
//! plan.sh's rules, keeping it under the plan key, and `h9x plan`'s
//! summary.
//!
//! Owned by W2. This is guest/plan.sh's jq and awk, on the host:
//!
//! - **Steps.** Each step builds in a layer by its name: the runtime layer
//!   for `packages:*` (mise's runtimes), deps for `install*`, and app for
//!   the rest. A step never builds below an earlier step's layer, so a plan
//!   that goes back to a packages step after its build (Gleam's
//!   `packages:mise:runtime`) builds it in the app layer. Apt steps are left
//!   out: their packages go into the roots.
//! - **Keys.** Each layer's key hashes its steps as `jq -c` prints them, and
//!   the files they copy from the source as `sha256sum` lines, and for the
//!   app layer, the deploy. The bytes are plan.sh's, so a key here is the
//!   key plan.sh gave.
//! - **The shared key.** The runtime layer's steps and the files they copy,
//!   less the idiomatic version files, whose versions the plan has already
//!   resolved; and whether those steps copy anything at all.
//! - **Deploy.** Each deploy input's paths, made absolute under /app, with
//!   their excludes, by the layer of the step they come from. A packages
//!   step above the runtime layer deploys from the runtime layer too.
//! - **Apt.** The Debian packages each apt step's `install -y` names.
//!
//! Two of plan.sh's shell accidents aren't kept: a copy's glob is expanded
//! in the source only (plan.sh's unquoted loop first expanded it in its
//! output directory), and a path that leaves the source (absolute, or with
//! `..`) is never read.
//!
//! The fixtures in testdata/plans are plan.sh's output for Railpack's
//! examples, captured by testdata/plans/capture.sh.

const std = @import("std");
const types = @import("types.zig");
const machine = @import("machine.zig");
const wolfi = @import("wolfi.zig");

const Value = std.json.Value;
const Mount = std.meta.Elem(@FieldType(machine.Options, "mounts"));
const EnvVar = std.meta.Elem(@FieldType(machine.Options, "env"));
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const ReadError = error{
    /// plan.json isn't JSON, or isn't an object.
    BadPlan,
    /// Railpack made no build steps; `logs` says why.
    NoSteps,
    OutOfMemory,
} || HashError;

pub const HashError = std.Io.Dir.OpenError || std.Io.Dir.StatFileError || std.Io.File.OpenError ||
    std.Io.Reader.Error || std.Io.Dir.Iterator.Error || error{ OutOfMemory, NameTooLong };

/// What `read` reads.
pub const Input = struct {
    /// plan.json as Railpack wrote it.
    plan_json: []const u8,
    /// `railpack info --format json`, for the provider and versions; null
    /// leaves them empty.
    info_json: ?[]const u8 = null,
    /// The source, which the keys hash the files of.
    src: std.Io.Dir,
    /// The plan's key (`key`), kept in the `Plan`.
    key: []const u8 = "",
    /// Paths in the source that no key hashes, as the plan's excludes are
    /// matched: the build's output directory, when it's in the source.
    /// plan.sh hashed it, layers and all.
    ignore: []const []const u8 = &.{},
};

/// Reads a kept `plan.json` into a `Plan`, as plan.sh would. Slices in the
/// result are `arena`'s, and `plan_json` and `info_json`'s.
pub fn read(arena: std.mem.Allocator, io: std.Io, in: Input) ReadError!types.Plan {
    const root = std.json.parseFromSliceLeaky(Value, arena, in.plan_json, json_options) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadPlan,
    };
    if (root != .object) return error.BadPlan;
    const steps_v = array(root.object.get("steps"));
    if (steps_v.len == 0) return error.NoSteps;

    // steps.txt: each step that isn't an apt step, and its layer.
    var steps: std.ArrayList(types.Step) = .empty;
    var top: u2 = 0;
    for (steps_v, 0..) |s, i| {
        const n = string(field(s, "name")) orelse return error.BadPlan;
        if (std.mem.startsWith(u8, n, "packages:apt:")) continue;
        top = @max(top, rank(n));
        try steps.append(arena, .{ .index = @intCast(i), .name = n, .layer = @enumFromInt(top) });
    }

    var p: types.Plan = .{
        .provider = "",
        .steps = steps.items,
        .keys = undefined,
        .shared_key = undefined,
        .runtime_copies = false,
        .deploy = try deploys(arena, root, steps.items),
        .apt_build = try apt(arena, steps_v, "packages:apt:build"),
        .apt_runtime = try apt(arena, steps_v, "packages:apt:runtime"),
        .start = string(field(root.object.get("deploy") orelse .null, "startCommand")),
        .key = in.key,
        .json = in.plan_json,
    };

    // keys.txt and shared.txt.
    var excl: std.ArrayList([]const u8) = .empty;
    for (array(root.object.get("exclude"))) |e| if (string(e)) |s| {
        var words = std.mem.tokenizeAny(u8, s, whitespace);
        while (words.next()) |w| try excl.append(arena, w);
    };
    try excl.appendSlice(arena, in.ignore);
    var h: Hasher = .{ .arena = arena, .io = io, .src = in.src, .exclude = excl.items };
    inline for (comptime std.enums.values(types.LayerName)) |l| {
        h.reset();
        for (steps.items) |s| if (s.layer == l) try h.step(steps_v[s.index], .all);
        if (l == .app) try h.line(root.object.get("deploy") orelse .null);
        @field(p.keys, @tagName(l)) = try h.key();
    }
    h.reset();
    for (steps.items) |s| if (s.layer == .runtime) {
        try h.step(steps_v[s.index], .shared);
        if (copies(steps_v[s.index])) p.runtime_copies = true;
    };
    p.shared_key = try h.key();

    if (in.info_json) |info| {
        const i = try readInfo(arena, info);
        p.provider = i.provider;
        p.versions = i.versions;
    }
    return p;
}

/// The plan's key: the architecture, the source's content hash, Railpack's
/// version, and h9x's, so a new Railpack or h9x plans again.
pub fn key(arena: std.mem.Allocator, arch: types.Arch, source_hash: []const u8, railpack_version: []const u8, h9x_version: []const u8) error{OutOfMemory}![]const u8 {
    var d: [Sha256.digest_length]u8 = undefined;
    const text = try std.fmt.allocPrint(arena, "plan {t} {s} {s} {s}\n", .{ arch, railpack_version, h9x_version, source_hash });
    Sha256.hash(text, &d, .{});
    return arena.dupe(u8, &std.fmt.bytesToHex(d[0..8], .lower));
}

// ---------------------------------------------------------------- plan.json

/// Duplicate keys keep their first place and their last value, as jq does,
/// and numbers stay as written, so `jq -c` can be matched.
const json_options: std.json.ParseOptions = .{
    .duplicate_field_behavior = .use_last,
    .parse_numbers = false,
    .max_value_len = std.math.maxInt(u32),
};

const whitespace = " \t\n";

fn field(v: Value, name: []const u8) Value {
    return if (v == .object) v.object.get(name) orelse .null else .null;
}

fn string(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn array(v: ?Value) []const Value {
    const x = v orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

/// Whether jq takes the value as true: anything but null and false.
fn truthy(v: Value) bool {
    return switch (v) {
        .null => false,
        .bool => |b| b,
        else => true,
    };
}

/// A step's layer by its name: 0 runtime, 1 deps, 2 app.
fn rank(name: []const u8) u2 {
    if (std.mem.startsWith(u8, name, "packages:")) return 0;
    if (std.mem.startsWith(u8, name, "install")) return 1;
    return 2;
}

/// The paths a step copies from the source: each command's `src`, then
/// each local input's includes. Each is a word list, as plan.sh's loop
/// splits it.
fn sources(arena: std.mem.Allocator, step: Value) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (array(field(step, "commands"))) |c| {
        const s = field(c, "src");
        if (truthy(s)) try out.append(arena, try scalarText(arena, s));
    }
    for (array(field(step, "inputs"))) |i| {
        const local = field(i, "local");
        if (!(local == .bool and local.bool)) continue;
        for (array(field(i, "include"))) |inc| try out.append(arena, try scalarText(arena, inc));
    }
    return out.items;
}

/// A value as `jq -r` prints it.
fn scalarText(arena: std.mem.Allocator, v: Value) error{OutOfMemory}![]const u8 {
    if (v == .string) return v.string;
    var w: std.Io.Writer.Allocating = .init(arena);
    jqCompact(&w.writer, v) catch return error.OutOfMemory;
    return w.written();
}

/// Whether a runtime step copies from the source, which the deps layer
/// then does instead: a command with a `src`, or a local input.
fn copies(step: Value) bool {
    for (array(field(step, "commands"))) |c| if (c == .object and c.object.contains("src")) return true;
    for (array(field(step, "inputs"))) |i| {
        const local = field(i, "local");
        if (local == .bool and local.bool) return true;
    }
    return false;
}

/// The Debian packages the steps named `prefix*` install: what follows the
/// first `install -y ` in each command, up to a quote, `;`, or `&`, sorted
/// and without duplicates.
fn apt(arena: std.mem.Allocator, steps: []const Value, prefix: []const u8) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (steps) |s| {
        const n = string(field(s, "name")) orelse continue;
        if (!std.mem.startsWith(u8, n, prefix)) continue;
        for (array(field(s, "commands"))) |c| {
            const cmd = string(field(c, "cmd")) orelse continue;
            const at = std.mem.indexOf(u8, cmd, "install -y ") orelse continue;
            const rest = cmd[at + "install -y ".len ..];
            const end = std.mem.indexOfAny(u8, rest, "';&") orelse rest.len;
            var words = std.mem.splitScalar(u8, rest[0..end], ' ');
            while (words.next()) |w| if (w.len > 0) try out.append(arena, w);
        }
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    // unique
    var n: usize = 0;
    for (out.items) |x| {
        if (n > 0 and std.mem.eql(u8, out.items[n - 1], x)) continue;
        out.items[n] = x;
        n += 1;
    }
    return out.items[0..n];
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// deploy.txt: what the run takes from each layer.
fn deploys(arena: std.mem.Allocator, root: Value, steps: []const types.Step) error{OutOfMemory}![]const types.Deploy {
    var out: std.ArrayList(types.Deploy) = .empty;
    for (array(field(root.object.get("deploy") orelse .null, "inputs"))) |i| {
        const step = field(i, "step");
        if (!truthy(step) or step != .string) continue;
        // The last step of that name, as plan.sh's map has it.
        var layer: ?types.LayerName = null;
        for (steps) |s| if (std.mem.eql(u8, s.name, step.string)) {
            layer = s.layer;
        };
        const l = layer orelse continue;
        var excl: std.ArrayList([]const u8) = .empty;
        for (array(field(i, "exclude"))) |e| try excl.append(arena, try absolute(arena, try scalarText(arena, e)));
        const also_runtime = std.mem.startsWith(u8, step.string, "packages:") and l != .runtime;
        const layers: []const types.LayerName = if (also_runtime) &.{ l, .runtime } else &.{l};
        for (layers) |dl| for (array(field(i, "include"))) |inc| {
            try out.append(arena, .{
                .layer = dl,
                .path = try absolute(arena, try scalarText(arena, inc)),
                .exclude = excl.items,
            });
        };
    }
    return out.items;
}

/// A deploy path made absolute: relative ones are under /app.
fn absolute(arena: std.mem.Allocator, p: []const u8) error{OutOfMemory}![]const u8 {
    if (std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, "./") or std.mem.eql(u8, p, "/app")) return "/app";
    const t = rtrim(rtrim(p, "/."), "/");
    if (std.mem.startsWith(u8, p, "/")) return t;
    return std.fmt.allocPrint(arena, "/app/{s}", .{t});
}

/// jq's rtrimstr: `s` without one `suffix`.
fn rtrim(s: []const u8, suffix: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, s, suffix)) s[0 .. s.len - suffix.len] else s;
}

/// A value as `jq -c` prints it: keys in the order given, and strings
/// escaped as jq escapes them, which isn't how Railpack (Go) did.
pub fn jqCompact(w: *std.Io.Writer, v: Value) std.Io.Writer.Error!void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |n| try w.print("{d}", .{n}),
        .float => |f| try w.print("{d}", .{f}),
        .number_string => |s| try w.writeAll(s),
        .string => |s| try jqString(w, s),
        .array => |a| {
            try w.writeByte('[');
            for (a.items, 0..) |x, i| {
                if (i > 0) try w.writeByte(',');
                try jqCompact(w, x);
            }
            try w.writeByte(']');
        },
        .object => |o| {
            try w.writeByte('{');
            var it = o.iterator();
            var first = true;
            while (it.next()) |e| {
                if (!first) try w.writeByte(',');
                first = false;
                try jqString(w, e.key_ptr.*);
                try w.writeByte(':');
                try jqCompact(w, e.value_ptr.*);
            }
            try w.writeByte('}');
        },
    }
}

fn jqString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        0...0x07, 0x0b, 0x0e...0x1f, 0x7f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

// ---------------------------------------------------------------- keys

/// The idiomatic version files: the plan has resolved the versions they
/// name, and the rest of a Gemfile or package.json doesn't change what
/// mise installs, so they're left out of the shared key.
const idiomatic = std.StaticStringMap(void).initComptime(.{
    .{".nvmrc"},        .{".node-version"}, .{".python-version"}, .{".python-versions"},
    .{".ruby-version"}, .{"Gemfile"},       .{".go-version"},     .{".java-version"},
    .{".sdkmanrc"},     .{".bun-version"},  .{"package.json"},
});

/// What plan.sh piped to `sha256sum` for a key.
const Hasher = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    src: std.Io.Dir,
    exclude: []const []const u8,
    sha: Sha256 = .init(.{}),

    const Which = enum {
        all,
        /// For the shared key: without the idiomatic version files.
        shared,
    };

    fn reset(h: *Hasher) void {
        h.sha = .init(.{});
    }

    /// The value as `jq -c` prints it, and a newline.
    fn line(h: *Hasher, v: Value) error{OutOfMemory}!void {
        var w: std.Io.Writer.Allocating = .init(h.arena);
        jqCompact(&w.writer, v) catch return error.OutOfMemory;
        w.writer.writeByte('\n') catch return error.OutOfMemory;
        h.sha.update(w.written());
    }

    /// A step, then the files it copies.
    fn step(h: *Hasher, s: Value, which: Which) HashError!void {
        try h.line(s);
        for (try sources(h.arena, s)) |text| {
            var words = std.mem.tokenizeAny(u8, text, whitespace);
            while (words.next()) |word| {
                if (which == .shared and idiomatic.has(basename(word))) continue;
                try h.files(word);
            }
        }
    }

    /// plan.sh's `hashfiles`: a `sha256sum` line for each file under each
    /// path the word globs to, less the plan's excludes, sorted by path.
    fn files(h: *Hasher, word: []const u8) HashError!void {
        var lines: std.ArrayList(Line) = .empty;
        for (try glob(h.arena, h.io, h.src, word)) |f| {
            if (!inside(f)) continue;
            const st = h.src.statFile(h.io, f, .{ .follow_symlinks = false }) catch |e| switch (e) {
                error.FileNotFound, error.NotDir => continue,
                else => |x| return x,
            };
            switch (st.kind) {
                .file => try h.add(&lines, f, f),
                .directory => {
                    var d = try h.src.openDir(h.io, f, .{ .iterate = true });
                    defer d.close(h.io);
                    var walk = try d.walk(h.arena);
                    defer walk.deinit();
                    const prefix = std.mem.trimEnd(u8, f, "/");
                    while (try walk.next(h.io)) |e| {
                        if (e.kind != .file) continue;
                        const path = try std.fmt.allocPrint(h.arena, "{s}/{s}", .{ if (prefix.len == 0) f else prefix, e.path });
                        const sub = try std.fmt.allocPrint(h.arena, "{s}/{s}", .{ f, e.path });
                        try h.add(&lines, path, sub);
                    }
                },
                else => {},
            }
        }
        std.mem.sort(Line, lines.items, {}, Line.lessThan);
        for (lines.items) |l| h.sha.update(l.text);
    }

    const Line = struct {
        path: []const u8,
        text: []const u8,

        /// `sort -k2`: by path, then by the whole line.
        fn lessThan(_: void, a: Line, b: Line) bool {
            return switch (std.mem.order(u8, a.path, b.path)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.order(u8, a.text, b.text) == .lt,
            };
        }
    };

    /// The line for the file at `sub` in the source, printed as `path`,
    /// unless an exclude takes it.
    fn add(h: *Hasher, lines: *std.ArrayList(Line), path: []const u8, sub: []const u8) HashError!void {
        // awk's $2, without a leading ./
        var p = path[0 .. std.mem.indexOfAny(u8, path, " \t") orelse path.len];
        if (std.mem.startsWith(u8, p, "./")) p = p[2..];
        for (h.exclude) |e| {
            if (std.mem.eql(u8, p, e)) return;
            if (std.mem.startsWith(u8, p, e) and p.len > e.len and p[e.len] == '/') return;
        }
        const digest = try fileHash(h.io, h.src, sub);
        const text = try std.fmt.allocPrint(h.arena, "{s}  {s}\n", .{ &std.fmt.bytesToHex(digest, .lower), path });
        try lines.append(h.arena, .{ .path = path, .text = text });
    }

    /// The first 16 hex digits of the hash, as `sha256sum | cut -c1-16`.
    fn key(h: *Hasher) error{OutOfMemory}![]const u8 {
        var d: [Sha256.digest_length]u8 = undefined;
        h.sha.final(&d);
        return h.arena.dupe(u8, &std.fmt.bytesToHex(d[0..8], .lower));
    }
};

fn fileHash(io: std.Io, dir: std.Io.Dir, sub: []const u8) HashError![Sha256.digest_length]u8 {
    var f = try dir.openFile(io, sub, .{});
    defer f.close(io);
    var buf: [64 << 10]u8 = undefined;
    var r = f.readerStreaming(io, &buf);
    var sha: Sha256 = .init(.{});
    while (true) {
        const chunk = r.interface.peekGreedy(1) catch |e| switch (e) {
            error.EndOfStream => break,
            error.ReadFailed => return error.ReadFailed,
        };
        sha.update(chunk);
        r.interface.toss(chunk.len);
    }
    var d: [Sha256.digest_length]u8 = undefined;
    sha.final(&d);
    return d;
}

/// Whether a path stays in the source: relative, with no `..`.
fn inside(p: []const u8) bool {
    if (p.len == 0 or p[0] == '/') return false;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |s| if (std.mem.eql(u8, s, "..")) return false;
    return true;
}

/// `basename`: the last name in a path, trailing slashes aside.
fn basename(p: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, p, "/");
    if (t.len == 0) return if (p.len > 0) "/" else "";
    return t[if (std.mem.lastIndexOfScalar(u8, t, '/')) |i| i + 1 else 0..];
}

// ---------------------------------------------------------------- globs

/// The paths in `dir` a shell word globs to, or the word itself when it
/// has no pattern or matches nothing, as sh leaves it.
fn glob(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, word: []const u8) HashError![]const []const u8 {
    if (std.mem.indexOfAny(u8, word, "*?[") == null or !inside(word)) return arena.dupe([]const u8, &.{word});
    var paths: std.ArrayList([]const u8) = .empty;
    try paths.append(arena, "");
    var segs = std.mem.splitScalar(u8, word, '/');
    while (segs.next()) |seg| {
        const last = segs.peek() == null;
        var next: std.ArrayList([]const u8) = .empty;
        for (paths.items) |p| {
            if (std.mem.indexOfAny(u8, seg, "*?[") == null) {
                try next.append(arena, try join(arena, p, seg));
                continue;
            }
            var d = dir.openDir(io, if (p.len == 0) "." else p, .{ .iterate = true }) catch continue;
            defer d.close(io);
            var it = d.iterate();
            while (it.next(io) catch null) |e| {
                if (!match(seg, e.name)) continue;
                const path = try join(arena, p, e.name);
                if (!last) {
                    // A pattern before a / matches directories only.
                    const st = dir.statFile(io, path, .{}) catch continue;
                    if (st.kind != .directory) continue;
                }
                try next.append(arena, path);
            }
        }
        paths = next;
    }
    // A literal name after a pattern must be there.
    var out: std.ArrayList([]const u8) = .empty;
    for (paths.items) |p| {
        _ = dir.statFile(io, p, .{ .follow_symlinks = false }) catch continue;
        try out.append(arena, p);
    }
    if (out.items.len == 0) try out.append(arena, word);
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.items;
}

fn join(arena: std.mem.Allocator, a: []const u8, b: []const u8) error{OutOfMemory}![]const u8 {
    if (a.len == 0) return arena.dupe(u8, b);
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ a, b });
}

/// Whether a name matches one segment of a shell pattern: `*`, `?`,
/// `[...]`, and `\`. A leading dot is matched only by a dot.
fn match(pat: []const u8, name: []const u8) bool {
    if (name.len > 0 and name[0] == '.' and (pat.len == 0 or pat[0] != '.')) return false;
    return matchAt(pat, name);
}

fn matchAt(pat: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    // Where to go back to after the last *.
    var star_p: ?usize = null;
    var star_n: usize = 0;
    while (n < name.len) {
        if (p < pat.len) switch (pat[p]) {
            '*' => {
                star_p = p;
                star_n = n;
                p += 1;
                continue;
            },
            '?' => {
                p += 1;
                n += 1;
                continue;
            },
            '[' => if (bracket(pat[p..], name[n])) |r| {
                if (r.ok) {
                    p += r.len;
                    n += 1;
                    continue;
                }
            } else if (name[n] == '[') {
                p += 1;
                n += 1;
                continue;
            },
            '\\' => if (p + 1 < pat.len and pat[p + 1] == name[n]) {
                p += 2;
                n += 1;
                continue;
            },
            else => |c| if (c == name[n]) {
                p += 1;
                n += 1;
                continue;
            },
        };
        const sp = star_p orelse return false;
        p = sp + 1;
        star_n += 1;
        n = star_n;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

/// A bracket expression at the start of `pat`, against `c`: whether it
/// matched, and its length; null if it isn't closed.
fn bracket(pat: []const u8, c: u8) ?struct { ok: bool, len: usize } {
    var i: usize = 1;
    const negate = i < pat.len and (pat[i] == '!' or pat[i] == '^');
    if (negate) i += 1;
    var ok = false;
    var first = true;
    while (i < pat.len) : (first = false) {
        if (pat[i] == ']' and !first) return .{ .ok = ok != negate, .len = i + 1 };
        const lo = pat[i];
        if (i + 2 < pat.len and pat[i + 1] == '-' and pat[i + 2] != ']') {
            if (lo <= c and c <= pat[i + 2]) ok = true;
            i += 3;
        } else {
            if (lo == c) ok = true;
            i += 1;
        }
    }
    return null;
}

// ---------------------------------------------------------------- info.json

const Info = struct {
    provider: []const u8 = "",
    versions: []const types.Version = &.{},
};

/// The providers Railpack detected and the versions it resolved, from
/// `railpack info --format json`. Anything unreadable is left out.
fn readInfo(arena: std.mem.Allocator, info_json: []const u8) error{OutOfMemory}!Info {
    const root = std.json.parseFromSliceLeaky(Value, arena, info_json, json_options) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{},
    };
    var out: Info = .{};
    var providers: std.ArrayList(u8) = .empty;
    for (array(field(root, "detectedProviders"))) |p| if (string(p)) |s| {
        if (providers.items.len > 0) try providers.appendSlice(arena, ", ");
        try providers.appendSlice(arena, s);
    };
    out.provider = providers.items;
    const pkgs = field(root, "resolvedPackages");
    if (pkgs == .object) {
        var versions: std.ArrayList(types.Version) = .empty;
        var it = pkgs.object.iterator();
        while (it.next()) |e| {
            const v = string(field(e.value_ptr.*, "resolvedVersion")) orelse
                string(field(e.value_ptr.*, "requestedVersion")) orelse continue;
            try versions.append(arena, .{ .name = string(field(e.value_ptr.*, "name")) orelse e.key_ptr.*, .version = v });
        }
        out.versions = versions.items;
    }
    return out;
}

/// Railpack's own account of a plan with no steps: its logs, a line each,
/// as `  LEVEL: MESSAGE`.
pub fn logs(arena: std.mem.Allocator, info_json: []const u8) error{OutOfMemory}![]const []const u8 {
    const root = std.json.parseFromSliceLeaky(Value, arena, info_json, json_options) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (array(field(root, "logs"))) |l| {
        const msg = string(field(l, "Msg")) orelse continue;
        try out.append(arena, try std.fmt.allocPrint(arena, "  {s}: {s}", .{ string(field(l, "Level")) orelse "", msg }));
    }
    return out.items;
}

// ---------------------------------------------------------------- plan.sh's files

/// The files plan.sh wrote, which build.sh and the POC's host side read.
pub const Text = enum {
    steps,
    keys,
    shared,
    deploy,
    @"apt-build",
    @"apt-runtime",

    pub fn file(t: Text) []const u8 {
        return switch (t) {
            inline else => |x| @tagName(x) ++ ".txt",
        };
    }
};

/// One of plan.sh's files, as it wrote it.
pub fn writeText(w: *std.Io.Writer, p: types.Plan, t: Text) std.Io.Writer.Error!void {
    switch (t) {
        .steps => for (p.steps) |s| try w.print("{d} {t} {s}\n", .{ s.index, s.layer, s.name }),
        .keys => inline for (comptime std.enums.values(types.LayerName)) |l|
            try w.print("{t} {s}\n", .{ l, @field(p.keys, @tagName(l)) }),
        .shared => try w.print("{s} {s}\n", .{ p.shared_key, if (p.runtime_copies) "copies" else "none" }),
        .deploy => for (p.deploy) |d| {
            try w.print("{t} {s} ", .{ d.layer, d.path });
            for (d.exclude, 0..) |e, i| try w.print("{s}{s}", .{ if (i > 0) " " else "", e });
            try w.writeByte('\n');
        },
        .@"apt-build" => for (p.apt_build) |a| try w.print("{s}\n", .{a}),
        .@"apt-runtime" => for (p.apt_runtime) |a| try w.print("{s}\n", .{a}),
    }
}

/// Writes plan.sh's files into `dir`, for build.sh, which reads
/// steps.txt from its cwd.
pub fn writeFiles(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, p: types.Plan) !void {
    for (std.enums.values(Text)) |t| {
        var w: std.Io.Writer.Allocating = .init(arena);
        try writeText(&w.writer, p, t);
        try dir.writeFile(io, .{ .sub_path = t.file(), .data = w.written() });
    }
}

// ---------------------------------------------------------------- the summary

/// `h9x plan`'s summary: the provider, the resolved versions, each step
/// and its layer, the deploy paths, the apt packages and their Wolfi
/// names, and the start command.
pub fn writeSummary(arena: std.mem.Allocator, w: *std.Io.Writer, p: types.Plan) !void {
    try w.print("provider  {s}\n", .{if (p.provider.len > 0) p.provider else "unknown"});
    if (p.versions.len > 0) {
        try w.writeAll("versions ");
        for (p.versions) |v| try w.print(" {s} {s}", .{ v.name, v.version });
        try w.writeByte('\n');
    }
    try w.writeAll("steps\n");
    for (p.steps) |s| try w.print("  {t: <8} {s}\n", .{ s.layer, s.name });
    if (p.deploy.len > 0) {
        try w.writeAll("deploy\n");
        for (p.deploy) |d| {
            try w.print("  {t: <8} {s}", .{ d.layer, d.path });
            if (d.exclude.len > 0) {
                try w.writeAll(" (except");
                for (d.exclude) |e| try w.print(" {s}", .{e});
                try w.writeByte(')');
            }
            try w.writeByte('\n');
        }
    }
    for ([_]struct { []const u8, []const []const u8 }{ .{ "build", p.apt_build }, .{ "runtime", p.apt_runtime } }) |a| {
        if (a[1].len == 0) continue;
        try w.print("apt ({s})\n", .{a[0]});
        for (a[1], try wolfi.names(arena, a[1])) |deb, wn| try w.print("  {s: <24} wolfi {s}\n", .{ deb, wn });
    }
    try w.print("start     {s}\n", .{p.start orelse "none"});
}

// ---------------------------------------------------------------- the plan cache

/// The files a plan is kept as, in the build's output directory: Railpack's
/// two, and the key they were made under.
pub const kept_files = [_][]const u8{ "plan.json", "info.json", "plan.key" };

/// The plan kept in `dir` under `plan_key`, read again; null when there's
/// none, or it was made under another key.
pub fn load(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, src: std.Io.Dir, ignore: []const []const u8, plan_key: []const u8) ReadError!?types.Plan {
    const kept = dir.readFileAlloc(io, "plan.key", arena, .limited(256)) catch return null;
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, kept, "\n"), plan_key)) return null;
    const pj = dir.readFileAlloc(io, "plan.json", arena, .limited(64 << 20)) catch return null;
    const info = dir.readFileAlloc(io, "info.json", arena, .limited(64 << 20)) catch null;
    return try read(arena, io, .{ .plan_json = pj, .info_json = info, .src = src, .key = plan_key, .ignore = ignore });
}

/// Keeps `plan.json` and `info.json`, already in `dir`, under `plan_key`,
/// with plan.sh's files beside them. The key is written last, so an
/// interrupted store isn't loaded.
pub fn store(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, p: types.Plan) !void {
    try writeFiles(arena, io, dir, p);
    try dir.writeFile(io, .{ .sub_path = "plan.key", .data = try std.fmt.allocPrint(arena, "{s}\n", .{p.key}) });
}

/// Removes a kept plan, before planning again.
pub fn forget(io: std.Io, dir: std.Io.Dir) void {
    for (kept_files) |f| dir.deleteFile(io, f) catch {};
    for (std.enums.values(Text)) |t| dir.deleteFile(io, t.file()) catch {};
}

// ---------------------------------------------------------------- Railpack

/// What a planning machine runs on.
pub const Machine = struct {
    /// The builder root, absolute.
    builder: []const u8,
    /// h9x's tools (`$cache/tools`), where mise's binaries are kept
    /// between runs, read-only to the guest.
    tools: []const u8,
    /// Railpack's binary, absolute.
    railpack: []const u8,
    source: types.Source,
    /// The machine's cwd, where Railpack writes plan.json and info.json:
    /// the build's output directory.
    work: []const u8,
};

/// The guest's script: Railpack's plan, then its info, which is quick once
/// the plan has resolved the versions. Railpack resolves versions with the
/// mise it pins, which it keeps in /tmp/railpack/mise and downloads if it
/// isn't there, so the tools' copy is put back first, and a new one saved
/// into the cwd's `mise-bin` after, for `run` to move into the tools.
const script =
    \\set -eu
    \\mkdir -p /tmp/railpack/mise
    \\for m in /h9x/tools/mise-*; do if [ -e "$m" ]; then cp "$m" /tmp/railpack/mise/; fi; done
    \\rm -f plan.json info.json
    \\"$H9X_RAILPACK" plan --out plan.json "$H9X_SRC"
    \\"$H9X_RAILPACK" info --format json --out info.json "$H9X_SRC" >/dev/null 2>&1 || rm -f info.json
    \\mkdir -p mise-bin
    \\for m in /tmp/railpack/mise/mise-*; do
    \\  if [ -e "$m" ] && [ ! -e "/h9x/tools/${m##*/}" ]; then cp "$m" mise-bin/; fi
    \\done
;

/// `base` with a planning machine's mounts, cwd, and environment added.
/// `base` is the plan phase's policy, compiled (policy.zig), with stdio.
pub fn options(arena: std.mem.Allocator, base: machine.Options, m: Machine) error{OutOfMemory}!machine.Options {
    var o = base;
    const railpack_dir = std.fs.path.dirname(m.railpack) orelse "/";
    const src_dst = try std.fmt.allocPrint(arena, "#L/h9x/src/{s}", .{m.source.name});
    var mounts: std.ArrayList(Mount) = .empty;
    try mounts.appendSlice(arena, &.{
        .{ .kind = .dir, .src = m.builder, .dst = "#L" },
        .{ .kind = .dir, .src = m.tools, .dst = "#L/h9x/tools", .access = .ro },
        .{ .kind = .dir, .src = railpack_dir, .dst = "#L/h9x/railpack", .access = .ro },
        .{ .kind = .dir, .src = m.source.path, .dst = src_dst, .access = .ro },
        .{ .kind = .tmp, .dst = "#L/tmp" },
    });
    try mounts.appendSlice(arena, base.mounts);
    o.mounts = mounts.items;

    var env: std.ArrayList(EnvVar) = .empty;
    try env.appendSlice(arena, &.{
        .{ .name = "HOME", .value = "/root" },
        .{ .name = "H9X_SRC", .value = src_dst[2..] },
        .{ .name = "H9X_RAILPACK", .value = try std.fmt.allocPrint(arena, "/h9x/railpack/{s}", .{std.fs.path.basename(m.railpack)}) },
    });
    try env.appendSlice(arena, base.env);
    o.env = env.items;
    o.cwd = m.work;
    if (o.policy.cwd_writable == null) o.policy.cwd_writable = true;
    return o;
}

pub const RunError = machine.RunError || std.Io.Dir.OpenError || error{ Failed, NoPlan };

/// Runs Railpack in a machine on the builder root, which writes plan.json
/// and info.json into `m.work`, and keeps a new mise in the tools. A
/// failed run is `error.Failed`, with the guest's status in `status`; a
/// setup failure says why in `why`, for exit 125.
pub fn run(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    host: machine.Host,
    base: machine.Options,
    m: Machine,
    status: *machine.Status,
    why: *[]const u8,
) RunError!void {
    const o = try options(arena, base, m);
    status.* = try machine.run(gpa, arena, io, host, o, &.{ "/bin/sh", "-c", script }, why);
    if (machine.exitCode(status.*) != 0) return error.Failed;
    var work = try std.Io.Dir.cwd().openDir(io, m.work, .{ .iterate = true });
    defer work.close(io);
    work.access(io, "plan.json", .{}) catch return error.NoPlan;
    keepMise(io, work, m.tools);
}

/// Moves the mise binaries Railpack downloaded into the tools.
fn keepMise(io: std.Io, work: std.Io.Dir, tools: []const u8) void {
    var bin = work.openDir(io, "mise-bin", .{ .iterate = true }) catch return;
    defer {
        bin.close(io);
        work.deleteTree(io, "mise-bin") catch {};
    }
    var t = std.Io.Dir.cwd().openDir(io, tools, .{}) catch return;
    defer t.close(io);
    var it = bin.iterate();
    while (it.next(io) catch null) |e| {
        if (!std.mem.startsWith(u8, e.name, "mise-")) continue;
        std.Io.Dir.rename(bin, e.name, t, e.name, io) catch {};
    }
}

// ---------------------------------------------------------------- tests

const examples = blk: {
    @setEvalBranchQuota(10000);
    var list: []const []const u8 = &.{};
    var it = std.mem.tokenizeScalar(u8, @embedFile("testdata/plans/examples.txt"), '\n');
    while (it.next()) |n| list = list ++ .{n};
    break :blk list;
};

fn fixture(comptime name: []const u8, comptime file: []const u8) []const u8 {
    return @embedFile("testdata/plans/" ++ name ++ "/" ++ file);
}

test "plan.zig reads each example's plan.json as plan.sh did [prototype]" {
    const io = std.testing.io;
    inline for (examples) |name| {
        var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer a.deinit();
        const arena = a.allocator();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var tar: std.Io.Reader = .fixed(fixture(name, "src.tar"));
        try std.tar.extract(io, tmp.dir, &tar, .{});

        const p = try read(arena, io, .{
            .plan_json = fixture(name, "plan.json"),
            .info_json = fixture(name, "info.json"),
            .src = tmp.dir,
        });
        inline for (comptime std.enums.values(Text)) |t| {
            var w: std.Io.Writer.Allocating = .init(arena);
            try writeText(&w.writer, p, t);
            std.testing.expectEqualStrings(fixture(name, t.file()), w.written()) catch |e| {
                std.debug.print("{s}: {s}\n", .{ name, t.file() });
                return e;
            };
        }
        try std.testing.expect(p.provider.len > 0);
        try std.testing.expect(p.versions.len > 0);
    }
}

test "a plan with no steps" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectError(error.NoSteps, read(a.allocator(), std.testing.io, .{
        .plan_json = "{\"steps\":[]}",
        .src = std.Io.Dir.cwd(),
    }));
    try std.testing.expectError(error.BadPlan, read(a.allocator(), std.testing.io, .{ .plan_json = "[", .src = std.Io.Dir.cwd() }));
    const l = try logs(a.allocator(),
        \\{"logs":[{"Level":"error","Msg":"no version of node matches 99"}]}
    );
    try std.testing.expectEqualStrings("  error: no version of node matches 99", l[0]);
}

test "a step goes back to a layer below" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const p = try read(a.allocator(), std.testing.io, .{
        .plan_json =
        \\{"steps":[{"name":"packages:mise"},{"name":"packages:apt:build"},{"name":"build"},{"name":"install"},{"name":"packages:mise:runtime"}],
        \\ "deploy":{"inputs":[{"step":"packages:mise:runtime","include":["/mise/installs/"]},{"step":"build","include":["./dist/."],"exclude":["x/"]},{"step":"nope","include":["/y"]}]}}
        ,
        .src = std.Io.Dir.cwd(),
    });
    try std.testing.expectEqual(@as(usize, 4), p.steps.len);
    try std.testing.expectEqual(@as(u32, 2), p.steps[1].index);
    try std.testing.expectEqual(types.LayerName.app, p.steps[2].layer);
    try std.testing.expectEqual(types.LayerName.app, p.steps[3].layer);
    try std.testing.expectEqual(@as(usize, 3), p.deploy.len);
    try std.testing.expectEqual(types.LayerName.runtime, p.deploy[1].layer);
    try std.testing.expectEqualStrings("/mise/installs", p.deploy[1].path);
    // jq's rtrimstr, not a path's cleaning.
    try std.testing.expectEqualStrings("/app/./dist", p.deploy[2].path);
    try std.testing.expectEqualStrings("/app/x", p.deploy[2].exclude[0]);
    try std.testing.expectEqual(@as(?[]const u8, null), p.start);
}

test jqCompact {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const v = try std.json.parseFromSliceLeaky(Value, a.allocator(),
        \\{"b":"x && y\n\u007f\u0001","a":[1.50,true,null],"b":"last"}
    , json_options);
    var w: std.Io.Writer.Allocating = .init(a.allocator());
    try jqCompact(&w.writer, v);
    try std.testing.expectEqualStrings(
        \\{"b":"last","a":[1.50,true,null]}
    , w.written());
    w.clearRetainingCapacity();
    try jqString(&w.writer, "x && y\n\x7f\x01\"\\");
    try std.testing.expectEqualStrings(
        \\"x && y\n\u007f\u0001\"\\"
    , w.written());
}

test match {
    try std.testing.expect(match("*.csproj", "app.csproj"));
    try std.testing.expect(!match("*.csproj", ".hidden.csproj"));
    try std.testing.expect(match("global.json*", "global.json"));
    try std.testing.expect(match("lib*", "lib"));
    try std.testing.expect(!match("lib*", "xlib"));
    try std.testing.expect(match("a?c", "abc"));
    try std.testing.expect(match("[a-c]x", "bx"));
    try std.testing.expect(!match("[!a-c]x", "bx"));
    try std.testing.expect(match("*a*b", "xaxxb"));
    try std.testing.expect(!match("*a*b", "xaxxbc"));
    try std.testing.expect(match(".*", ".env"));
}

test glob {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "config");
    for ([_][]const u8{ "b.csproj", "a.csproj", "config/prod.exs", ".x.csproj" }) |f|
        try tmp.dir.writeFile(io, .{ .sub_path = f, .data = "" });
    const g = try glob(arena, io, tmp.dir, "*.csproj");
    try std.testing.expectEqual(@as(usize, 2), g.len);
    try std.testing.expectEqualStrings("a.csproj", g[0]);
    try std.testing.expectEqualStrings("config/prod.exs", (try glob(arena, io, tmp.dir, "c*/prod.exs*"))[0]);
    try std.testing.expectEqualStrings("rel*", (try glob(arena, io, tmp.dir, "rel*"))[0]);
}

test "load and store" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The output directory in the source, as `h9x build .` makes it.
    try tmp.dir.createDirPath(io, "app.h9");
    var out = try tmp.dir.openDir(io, "app.h9", .{});
    defer out.close(io);
    const ignore: []const []const u8 = &.{"app.h9"};
    const k = try key(arena, .amd64, "abc", "0.43.0", "0.0.0");
    try std.testing.expectEqual(@as(usize, 16), k.len);
    try std.testing.expect(!std.mem.eql(u8, k, try key(arena, .arm64, "abc", "0.43.0", "0.0.0")));

    try std.testing.expectEqual(@as(?types.Plan, null), try load(arena, io, out, tmp.dir, ignore, k));
    try out.writeFile(io, .{ .sub_path = "plan.json", .data = fixture("go-mod", "plan.json") });
    const p = try read(arena, io, .{ .plan_json = fixture("go-mod", "plan.json"), .src = tmp.dir, .key = k, .ignore = ignore });
    try store(arena, io, out, p);
    try out.access(io, "steps.txt", .{});
    const l = (try load(arena, io, out, tmp.dir, ignore, k)).?;
    try std.testing.expectEqualStrings(p.keys.app, l.keys.app);
    // Without the ignore, the kept files change the app layer's key.
    const l2 = (try load(arena, io, out, tmp.dir, &.{}, k)).?;
    try std.testing.expect(!std.mem.eql(u8, p.keys.app, l2.keys.app));
    try std.testing.expectEqual(@as(?types.Plan, null), try load(arena, io, out, tmp.dir, ignore, "other"));
    forget(io, out);
    try std.testing.expectEqual(@as(?types.Plan, null), try load(arena, io, out, tmp.dir, ignore, k));
}

test writeSummary {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const p = try read(arena, io, .{
        .plan_json = fixture("node-npm", "plan.json"),
        .info_json = fixture("node-npm", "info.json"),
        .src = tmp.dir,
    });
    var w: std.Io.Writer.Allocating = .init(arena);
    try writeSummary(arena, &w.writer, p);
    try std.testing.expectEqualStrings(
        \\provider  node
        \\versions  node 23.5.0
        \\steps
        \\  runtime  packages:mise
        \\  deps     install
        \\  app      build
        \\deploy
        \\  runtime  /mise/shims
        \\  runtime  /mise/installs
        \\  runtime  /usr/local/bin/mise
        \\  runtime  /etc/mise/config.toml
        \\  runtime  /root/.local/state/mise
        \\  app      /app/node_modules
        \\  app      /root/.cache (except /app/node_modules /app/.yarn)
        \\  app      /app (except /app/node_modules /app/.yarn)
        \\apt (runtime)
        \\  libatomic1               wolfi libatomic
        \\start     npm run start
        \\
    , w.written());
}

test options {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const o = try options(a.allocator(), .{ .stdio = undefined }, .{
        .builder = "/c/roots/builder-1",
        .tools = "/c/tools",
        .railpack = "/c/tools/railpack",
        .source = .{ .kind = .dir, .spec = ".", .path = "/src/app", .name = "app", .hash = "" },
        .work = "/out",
    });
    try std.testing.expectEqualStrings("#L/h9x/src/app", o.mounts[3].dst);
    try std.testing.expectEqualStrings("/h9x/src/app", o.env[1].value);
    try std.testing.expectEqualStrings("/h9x/railpack/railpack", o.env[2].value);
    try std.testing.expectEqualStrings("/out", o.cwd.?);
}
