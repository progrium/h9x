//! Events (design/prototype.md, "Events"): as `h9x:` lines on stderr, or
//! one JSON object per line with `--json`.
//!
//! Owned by W6. The skeleton's version writes every kind, so commands can
//! report from the start; W6 settles the text forms, the exit-code mapping,
//! and docs/events.md.

const std = @import("std");
const types = @import("types.zig");

pub const Event = types.Event;

pub const Emitter = struct {
    w: *std.Io.Writer,
    json: bool = false,

    pub fn emit(e: *Emitter, ev: Event) void {
        e.write(ev) catch {};
        e.w.flush() catch {};
    }

    /// A free-form note, as a `log` event.
    pub fn log(e: *Emitter, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
            @memcpy(buf[buf.len - 3 ..], "...");
            break :blk &buf;
        };
        e.emit(.{ .log = .{ .text = text } });
    }

    fn write(e: *Emitter, ev: Event) std.Io.Writer.Error!void {
        if (e.json) return writeJson(e.w, ev);
        try writeText(e.w, ev);
    }
};

/// `{"event":KIND, ...fields}` and a newline.
pub fn writeJson(w: *std.Io.Writer, ev: Event) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("event");
    try s.write(@tagName(ev));
    switch (ev) {
        inline else => |payload| {
            inline for (std.meta.fields(@TypeOf(payload))) |f| {
                const v = @field(payload, f.name);
                if (@typeInfo(f.type) == .optional and v == null) {} else {
                    try s.objectField(f.name);
                    try s.write(v);
                }
            }
        },
    }
    try s.endObject();
    try w.writeByte('\n');
}

/// The POC's `h9x:` lines.
pub fn writeText(w: *std.Io.Writer, ev: Event) std.Io.Writer.Error!void {
    switch (ev) {
        .output => |o| return w.writeAll(o.text),
        .log => |l| return w.print("h9x: {s}\n", .{l.text}),
        .phase => |p| try w.print("h9x: {t}: {t}", .{ p.phase, p.state }),
        .fetch => |f| try w.print("h9x: fetch {s}: {t}", .{ f.url, f.state }),
        .root => |r| try w.print("h9x: root {t}: {t}", .{ r.root, r.state }),
        .layer => |l| try w.print("h9x: layer {t}: {t}", .{ l.layer, l.state }),
        .step => |s| {
            try w.print("h9x: {t}: {s}: {t}", .{ s.layer, s.step, s.state });
            if (s.status) |st| try w.print(" {d}", .{st});
        },
        .policy => |p| return w.print("# {t}\n{s}", .{ p.phase, p.text }),
        .result => |r| {
            if (r.status == 0) return;
            try w.print("h9x: {s}: exit {d}", .{ r.command, r.status });
        },
    }
    try w.writeByte('\n');
}

test "json lines" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeJson(&w, .{ .layer = .{ .layer = .deps, .state = .cached, .key = "abc" } });
    try writeJson(&w, .{ .result = .{ .command = "build", .status = 0, .ms = 5 } });
    try std.testing.expectEqualStrings(
        \\{"event":"layer","layer":"deps","state":"cached","key":"abc"}
        \\{"event":"result","command":"build","status":0,"ms":5}
        \\
    , w.buffered());
}
