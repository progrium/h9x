//! Events (design/prototype.md, "Events"): as `h9x:` lines on stderr, or
//! one JSON object per line with `--json`. docs/events.md documents each
//! kind and its fields.
//!
//! Commands report through an `Emitter`: `emit` for an event, `log` for a
//! note, `output` for a writer to give a machine as its stdout or stderr,
//! and `fail` to log why a command failed and get its exit code. main.zig
//! emits the `result` that ends every command, and nothing is written after
//! it.
//!
//! The exit codes (design/prototype.md, "Exit codes") are `types.Exit`.
//! `exitFor` maps a command's error to one, by the error's name, so a
//! module only has to return an error from the right set below.

const std = @import("std");
const types = @import("types.zig");

pub const Event = types.Event;
pub const Exit = types.Exit;

// ---------------------------------------------------------------- exit codes

/// Errors that are exit 2: the person asked for something h9x won't do.
/// Log why with `Emitter.fail` before returning one.
pub const UsageError = error{
    /// A bad flag or argument (cli.zig).
    Usage,
    /// h9x.toml or a config value h9x can't read (config.zig, toml.zig).
    BadConfig,
    /// A policy line h9x can't read (policy.zig).
    BadPolicy,
    /// A flag or h9x.toml line that widens a phase's policy (policy.zig).
    PolicyWidens,
    /// h9 refused a policy as conflicting (h9.Machine.InitError).
    PolicyConflict,
    /// A SOURCE h9x can't parse (source.zig).
    BadSource,
    /// A `--target` h9x can't make, such as the other architecture's.
    BadTarget,
    /// An unknown `H9X_BACKEND` (machine.zig).
    BadBackend,
};

/// Errors that are exit 1: the app's build failed.
pub const FailedError = error{
    /// A build step exited with a status.
    StepFailed,
    /// Railpack made no build steps.
    NoSteps,
    /// A stubbed command (the skeleton). Goes away with the stubs.
    NotImplemented,
};

/// Errors that are exit 124, as h9's.
pub const TimeoutError = error{Timeout};

/// The exit code for a command that failed with `err`. Errors in the sets
/// above are theirs; anything else is setup failing (125): a download, a
/// root, a machine h9 couldn't start, or the host refusing a file.
pub fn exitFor(err: anyerror) Exit {
    if (inSet(UsageError, err)) return .usage;
    if (inSet(FailedError, err)) return .failed;
    if (inSet(TimeoutError, err)) return .timeout;
    return .setup;
}

fn inSet(comptime Set: type, err: anyerror) bool {
    inline for (@typeInfo(Set).error_set.?) |e| {
        if (err == @field(anyerror, e.name)) return true;
    }
    return false;
}

/// Whether argv (without the program's name) asks for `--json`, for
/// reporting a usage error before the arguments are parsed. Arguments after
/// `--` are the program's.
pub fn wantsJson(args: []const []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, "--")) return false;
        if (std.mem.eql(u8, a, "--json")) return true;
    }
    return false;
}

// ---------------------------------------------------------------- emitter

pub const Emitter = struct {
    w: *std.Io.Writer,
    json: bool = false,
    /// For the lock, when more than one thread emits, such as a machine's
    /// stdout and stderr. Without it events aren't locked.
    io: ?std.Io = null,
    mutex: std.Io.Mutex = .init,
    /// Set once `result` is written; later events are dropped, so `result`
    /// is always the last line.
    ended: bool = false,

    pub fn emit(e: *Emitter, ev: Event) void {
        e.lock();
        defer e.unlock();
        e.emitLocked(ev);
    }

    fn emitLocked(e: *Emitter, ev: Event) void {
        if (e.ended) return;
        if (ev == .result) e.ended = true;
        e.write(ev) catch {};
        e.w.flush() catch {};
    }

    /// A free-form note, as a `log` event. Text longer than 1 KiB is cut,
    /// ending in `...`.
    pub fn log(e: *Emitter, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        e.emit(.{ .log = .{ .text = format(&buf, fmt, args) } });
    }

    /// Logs why a command failed and returns its exit code, for
    /// `return ctx.events.fail(error.PolicyWidens, "--net enable widens the build policy", .{})`.
    pub fn fail(e: *Emitter, err: anyerror, comptime fmt: []const u8, args: anytype) u8 {
        e.log(fmt, args);
        return exitFor(err).code();
    }

    /// The `result` that ends a command.
    pub fn result(e: *Emitter, command: []const u8, status: u8, out: ?[]const u8, ms: u64) void {
        e.emit(.{ .result = .{ .command = command, .status = status, .out = out, .ms = ms } });
    }

    /// A writer that turns what's written to it into `output` events for
    /// `layer` and `step`, to give a machine as `Stdio.out` or `Stdio.err`.
    /// With `--json`, a write becomes one event when `buf` fills or on
    /// `flush`, and a UTF-8 sequence cut at the end is held for the next
    /// write. Without it, bytes pass through as they are. Flush it when the
    /// machine ends.
    pub fn output(
        e: *Emitter,
        layer: ?types.LayerName,
        step: ?[]const u8,
        stream: Event.Stream,
        buf: []u8,
    ) Output {
        std.debug.assert(buf.len >= 4);
        return .{
            .emitter = e,
            .layer = layer,
            .step = step,
            .stream = stream,
            .interface = .{ .buffer = buf, .vtable = &.{ .drain = Output.drain, .flush = Output.flush } },
        };
    }

    fn write(e: *Emitter, ev: Event) std.Io.Writer.Error!void {
        if (e.json) return writeJson(e.w, ev);
        try writeText(e.w, ev);
    }

    fn lock(e: *Emitter) void {
        if (e.io) |io| e.mutex.lockUncancelable(io);
    }

    fn unlock(e: *Emitter) void {
        if (e.io) |io| e.mutex.unlock(io);
    }
};

pub const Output = struct {
    emitter: *Emitter,
    layer: ?types.LayerName,
    step: ?[]const u8,
    stream: Event.Stream,
    interface: std.Io.Writer,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const o: *Output = @alignCast(@fieldParentPtr("interface", w));
        const e = o.emitter;
        e.lock();
        defer e.unlock();
        // In JSON, `buffer` is one event, less a cut UTF-8 sequence at its
        // end, which moves to the front for the next.
        const held = if (e.json) cutSequence(w.buffered()) else 0;
        o.send(w.buffer[0 .. w.end - held]);
        std.mem.copyForwards(u8, w.buffer[0..held], w.buffer[w.end - held .. w.end]);
        w.end = held;

        // Then as much of `data` as fits. A slice the buffer can't hold is
        // sent whole when nothing is held, or else fills the buffer (a held
        // sequence is at most 3 bytes, so there's room).
        var n: usize = 0;
        for (data, 0..) |d, i| {
            const times = if (i == data.len - 1) splat else 1;
            for (0..times) |_| {
                const room = w.buffer.len - w.end;
                if (d.len > room) {
                    if (n > 0) return n;
                    if (w.end > 0) {
                        @memcpy(w.buffer[w.end..], d[0..room]);
                        w.end += room;
                        return room;
                    }
                    const keep = if (e.json) cutSequence(d) else 0;
                    o.send(d[0 .. d.len - keep]);
                    @memcpy(w.buffer[0..keep], d[d.len - keep ..]);
                    w.end = keep;
                    return d.len;
                }
                @memcpy(w.buffer[w.end..][0..d.len], d);
                w.end += d.len;
                n += d.len;
            }
        }
        return n;
    }

    /// Sends everything buffered, a cut sequence too (as U+FFFD).
    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const o: *Output = @alignCast(@fieldParentPtr("interface", w));
        o.emitter.lock();
        defer o.emitter.unlock();
        o.send(w.buffered());
        w.end = 0;
    }

    /// Called locked.
    fn send(o: *Output, text: []const u8) void {
        if (text.len == 0) return;
        o.emitter.emitLocked(.{ .output = .{ .layer = o.layer, .step = o.step, .stream = o.stream, .text = text } });
    }
};

/// How many bytes at the end of `s` are the start of a UTF-8 sequence that
/// the next write may finish.
fn cutSequence(s: []const u8) usize {
    var i: usize = 0;
    // A sequence is at most 4 bytes, so its start is in the last 3.
    while (i < @min(3, s.len)) : (i += 1) {
        const b = s[s.len - 1 - i];
        if (b & 0xc0 == 0x80) continue; // a continuation byte
        const want = std.unicode.utf8ByteSequenceLength(b) catch return 0;
        return if (want > i + 1) i + 1 else 0;
    }
    return 0;
}

fn format(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch {
        @memcpy(buf[buf.len - 3 ..], "...");
        return buf;
    };
}

// ---------------------------------------------------------------- json

/// `{"event":KIND, ...fields}` and a newline. Fields are in the order
/// `types.Event` declares them, a null field is left out, an enum is its
/// name, and a string that isn't UTF-8 has U+FFFD for each bad byte.
pub fn writeJson(w: *std.Io.Writer, ev: Event) std.Io.Writer.Error!void {
    try w.writeAll("{\"event\":");
    try writeString(w, @tagName(ev));
    switch (ev) {
        inline else => |payload| {
            inline for (std.meta.fields(@TypeOf(payload))) |f| {
                try writeField(w, f.name, @field(payload, f.name));
            }
        },
    }
    try w.writeAll("}\n");
}

fn writeField(w: *std.Io.Writer, comptime name: []const u8, v: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .optional => if (v) |x| try writeField(w, name, x),
        .@"enum" => {
            try w.writeAll(",\"" ++ name ++ "\":");
            try writeString(w, @tagName(v));
        },
        .int => try w.print(",\"" ++ name ++ "\":{d}", .{v}),
        .pointer => {
            comptime std.debug.assert(T == []const u8);
            try w.writeAll(",\"" ++ name ++ "\":");
            try writeString(w, v);
        },
        else => @compileError("events: no JSON for a field of type " ++ @typeName(T)),
    }
}

/// A JSON string. Bytes that aren't UTF-8 become U+FFFD, one each.
pub fn writeString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            switch (b) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                0...8, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => try w.print("\\u{x:0>4}", .{b}),
                else => try w.writeByte(b),
            }
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(b) catch 0;
        if (n > 0 and i + n <= s.len) {
            if (std.unicode.utf8Decode(s[i..][0..n])) |_| {
                try w.writeAll(s[i..][0..n]);
                i += n;
                continue;
            } else |_| {}
        }
        try w.writeAll("\u{fffd}");
        i += 1;
    }
    try w.writeByte('"');
}

// ---------------------------------------------------------------- text

/// The POC's `h9x:` lines. Most kinds print only when there's something to
/// see: a start, a layer that's kept or shared, or a failure. `output` is
/// the program's bytes as they are, and `policy` is its plan text under a
/// `# PHASE` line, as `--print` shows it.
pub fn writeText(w: *std.Io.Writer, ev: Event) std.Io.Writer.Error!void {
    switch (ev) {
        .output => |o| return w.writeAll(o.text),
        .log => |l| return w.print("h9x: {s}\n", .{l.text}),
        .phase => |p| switch (p.state) {
            .start => try w.print("h9x: {t}", .{p.phase}),
            .cached => try w.print("h9x: {t}: unchanged", .{p.phase}),
            .done => return,
            else => try w.print("h9x: {t}: {t}", .{ p.phase, p.state }),
        },
        .fetch => |f| switch (f.state) {
            .start => try w.print("h9x: fetching {s}", .{f.url}),
            .cached => try w.print("h9x: fetch {s}: unchanged", .{f.url}),
            .done => return,
            else => try w.print("h9x: fetch {s}: {t}", .{ f.url, f.state }),
        },
        .root => |r| switch (r.state) {
            .start, .building => try w.print("h9x: making the {t} root", .{r.root}),
            .cached, .done => return,
            else => try w.print("h9x: root {t}: {t}", .{ r.root, r.state }),
        },
        .layer => |l| switch (l.state) {
            .start, .building => try w.print("h9x: layer {t}", .{l.layer}),
            .cached => try w.print("h9x: layer {t}: unchanged", .{l.layer}),
            .shared => try w.print("h9x: layer {t}: shared, {s}", .{ l.layer, l.key }),
            .done => return,
            else => try w.print("h9x: layer {t}: {t}", .{ l.layer, l.state }),
        },
        .step => |s| switch (s.state) {
            .start => try w.print("h9x: layer {t}: step {s}", .{ s.layer, s.step }),
            .done => return,
            .exit => {
                const st = s.status orelse 0;
                if (st == 0) return;
                try w.print("h9x: layer {t}: step {s}: exit {d}", .{ s.layer, s.step, st });
            },
            else => try w.print("h9x: layer {t}: step {s}: {t}", .{ s.layer, s.step, s.state }),
        },
        .policy => |p| {
            try w.print("# {t}\n{s}", .{ p.phase, p.text });
            if (p.text.len > 0 and p.text[p.text.len - 1] == '\n') return;
        },
        .result => |r| {
            if (r.status != 0) {
                try w.print("h9x: {s}: exit {d}", .{ r.command, r.status });
            } else if (r.out) |out| {
                try w.print("h9x: done: {s}", .{out});
            } else return;
        },
    }
    try w.writeByte('\n');
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// One of each kind, as a build would send them.
const every_kind = [_]Event{
    .{ .fetch = .{ .url = "https://example.com/app.tar.gz", .state = .start } },
    .{ .fetch = .{ .url = "https://example.com/app.tar.gz", .state = .done, .bytes = 1234 } },
    .{ .root = .{ .root = .builder, .key = "r1", .state = .building } },
    .{ .phase = .{ .phase = .plan, .state = .start } },
    .{ .policy = .{ .phase = .build, .text = "net none\nmemory 2G\n" } },
    .{ .layer = .{ .layer = .runtime, .state = .shared, .key = "k0" } },
    .{ .layer = .{ .layer = .deps, .state = .cached, .key = "k1" } },
    .{ .layer = .{ .layer = .app, .state = .building, .key = "k2" } },
    .{ .step = .{ .layer = .app, .step = "build", .state = .start } },
    .{ .output = .{ .layer = .app, .step = "build", .stream = .stderr, .text = "line \"one\"\n\ttwo\x00\xff\n" } },
    .{ .step = .{ .layer = .app, .step = "build", .state = .exit, .status = 0, .ms = 4120 } },
    .{ .log = .{ .text = "warning: something" } },
    .{ .result = .{ .command = "build", .status = 0, .out = "/home/me/app.h9", .ms = 5302 } },
};

test "--json emits one event per line, ending in result" {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var e: Emitter = .{ .w = &w, .json = true };
    for (every_kind) |ev| e.emit(ev);
    // Nothing follows result.
    e.log("late", .{});
    e.result("build", 1, null, 1);

    var lines = std.mem.splitScalar(u8, w.buffered(), '\n');
    var n: usize = 0;
    var last_is_result = false;
    while (lines.next()) |line| {
        if (line.len == 0) {
            try testing.expect(lines.next() == null);
            break;
        }
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expectEqualStrings(@tagName(every_kind[n]), obj.get("event").?.string);
        last_is_result = std.mem.eql(u8, obj.get("event").?.string, "result");
        n += 1;
    }
    try testing.expectEqual(every_kind.len, n);
    try testing.expect(last_is_result);
}

test "json fields" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeJson(&w, .{ .layer = .{ .layer = .deps, .state = .cached, .key = "abc" } });
    try writeJson(&w, .{ .result = .{ .command = "build", .status = 0, .ms = 5 } });
    try writeJson(&w, .{ .step = .{ .layer = .app, .step = "build", .state = .exit, .status = 2, .ms = 7 } });
    try writeJson(&w, .{ .output = .{ .stream = .stdout, .text = "a\"b\\c\n\x01\xc3\xa9\xe2\x82" } });
    try testing.expectEqualStrings(
        \\{"event":"layer","layer":"deps","state":"cached","key":"abc"}
        \\{"event":"result","command":"build","status":0,"ms":5}
        \\{"event":"step","layer":"app","step":"build","state":"exit","status":2,"ms":7}
        \\{"event":"output","stream":"stdout","text":"a\"b\\c\n\u0001é��"}
        \\
    , w.buffered());
}

test "text lines" {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    for (every_kind) |ev| try writeText(&w, ev);
    try writeText(&w, .{ .phase = .{ .phase = .plan, .state = .cached } });
    try writeText(&w, .{ .step = .{ .layer = .deps, .step = "install", .state = .exit, .status = 3 } });
    try writeText(&w, .{ .result = .{ .command = "build", .status = 1, .ms = 9 } });
    try writeText(&w, .{ .result = .{ .command = "plan", .status = 0, .ms = 9 } });
    try testing.expectEqualStrings(
        "h9x: fetching https://example.com/app.tar.gz\n" ++
            "h9x: making the builder root\n" ++
            "h9x: plan\n" ++
            "# build\nnet none\nmemory 2G\n" ++
            "h9x: layer runtime: shared, k0\n" ++
            "h9x: layer deps: unchanged\n" ++
            "h9x: layer app\n" ++
            "h9x: layer app: step build\n" ++
            "line \"one\"\n\ttwo\x00\xff\n" ++
            "h9x: warning: something\n" ++
            "h9x: done: /home/me/app.h9\n" ++
            "h9x: plan: unchanged\n" ++
            "h9x: layer deps: step install: exit 3\n" ++
            "h9x: build: exit 1\n",
        w.buffered(),
    );
}

test "every kind and state has a text form" {
    var buf: [512]u8 = undefined;
    inline for (std.meta.fields(Event)) |f| {
        const P = f.type;
        if (@hasField(P, "state")) {
            for (std.enums.values(Event.State)) |st| {
                var w: std.Io.Writer = .fixed(&buf);
                var p: P = undefined;
                inline for (std.meta.fields(P)) |pf| {
                    @field(p, pf.name) = switch (@typeInfo(pf.type)) {
                        .optional => null,
                        .@"enum" => @enumFromInt(0),
                        else => "x",
                    };
                }
                p.state = st;
                try writeText(&w, @unionInit(Event, f.name, p));
                try writeJson(&w, @unionInit(Event, f.name, p));
            }
        }
    }
}

test "output events" {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var e: Emitter = .{ .w = &w, .json = true };
    var obuf: [8]u8 = undefined;
    var o = e.output(.deps, "install", .stdout, &obuf);
    // "é" (c3 a9) cut across the buffer's end, then a write longer than the
    // buffer.
    try o.interface.writeAll("abcdef\xc3");
    try o.interface.writeAll("\xa9g");
    try o.interface.writeAll("0123456789");
    try o.interface.flush();
    try testing.expectEqualStrings(
        \\{"event":"output","layer":"deps","step":"install","stream":"stdout","text":"abcdef"}
        \\{"event":"output","layer":"deps","step":"install","stream":"stdout","text":"ég"}
        \\{"event":"output","layer":"deps","step":"install","stream":"stdout","text":"0123456789"}
        \\
    , w.buffered());

    // Text passes through.
    w = .fixed(&buf);
    e = .{ .w = &w };
    o = e.output(null, null, .stderr, &obuf);
    try o.interface.writeAll("abcdef\xc3");
    try o.interface.writeAll("\xa9g0123456789\n");
    try o.interface.flush();
    try testing.expectEqualStrings("abcdef\xc3\xa9g0123456789\n", w.buffered());
}

test cutSequence {
    try testing.expectEqual(0, cutSequence("abc"));
    try testing.expectEqual(1, cutSequence("ab\xc3"));
    try testing.expectEqual(0, cutSequence("ab\xc3\xa9"));
    try testing.expectEqual(2, cutSequence("a\xe2\x82"));
    try testing.expectEqual(3, cutSequence("\xf0\x9f\x98"));
    try testing.expectEqual(0, cutSequence("\xf0\x9f\x98\x80"));
    try testing.expectEqual(0, cutSequence("\xff"));
}

test wantsJson {
    try testing.expect(wantsJson(&.{ "build", "--bogus", "--json" }));
    try testing.expect(!wantsJson(&.{ "run", "--", "app", "--json" }));
    try testing.expect(!wantsJson(&.{"build"}));
}

test exitFor {
    try testing.expectEqual(Exit.usage, exitFor(error.Usage));
    try testing.expectEqual(Exit.usage, exitFor(error.PolicyWidens));
    try testing.expectEqual(Exit.failed, exitFor(error.StepFailed));
    try testing.expectEqual(Exit.failed, exitFor(error.NoSteps));
    try testing.expectEqual(Exit.timeout, exitFor(error.Timeout));
    try testing.expectEqual(Exit.setup, exitFor(error.FileNotFound));
    try testing.expectEqual(Exit.setup, exitFor(error.OutOfMemory));

    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var e: Emitter = .{ .w = &w };
    try testing.expectEqual(2, e.fail(error.PolicyWidens, "--net {s} widens the build policy", .{"enable"}));
    try testing.expectEqualStrings("h9x: --net enable widens the build policy\n", w.buffered());
}
