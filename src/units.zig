//! Values that flags, `h9x.toml`, and environment variables share:
//! durations, sizes, and network modes.

const std = @import("std");
const types = @import("types.zig");

/// `30s`, `10m`, `2h`, or `30d`, as nanoseconds. A bare number is seconds.
pub fn parseDuration(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    const unit: u64, const digits = switch (s[s.len - 1]) {
        's' => .{ std.time.ns_per_s, s[0 .. s.len - 1] },
        'm' => .{ std.time.ns_per_min, s[0 .. s.len - 1] },
        'h' => .{ std.time.ns_per_hour, s[0 .. s.len - 1] },
        'd' => .{ std.time.ns_per_day, s[0 .. s.len - 1] },
        else => .{ std.time.ns_per_s, s },
    };
    const n = std.fmt.parseInt(u64, digits, 10) catch return null;
    return std.math.mul(u64, n, unit) catch null;
}

/// `512M`, `4G`, `1024K`, or bytes, as h9's `--memory` takes them.
pub fn parseSize(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    const unit: u64, const digits = switch (std.ascii.toUpper(s[s.len - 1])) {
        'K' => .{ 1 << 10, s[0 .. s.len - 1] },
        'M' => .{ 1 << 20, s[0 .. s.len - 1] },
        'G' => .{ 1 << 30, s[0 .. s.len - 1] },
        else => .{ 1, s },
    };
    const n = std.fmt.parseInt(u64, digits, 10) catch return null;
    return std.math.mul(u64, n, unit) catch null;
}

/// A `net` mode by name; `none` is `disable`, as `build.net` spells it.
pub fn parseNet(s: []const u8) ?types.Net {
    if (std.mem.eql(u8, s, "none")) return .disable;
    return std.meta.stringToEnum(types.Net, s);
}

test parseDuration {
    try std.testing.expectEqual(@as(?u64, 30 * std.time.ns_per_day), parseDuration("30d"));
    try std.testing.expectEqual(@as(?u64, 2 * std.time.ns_per_min), parseDuration("2m"));
    try std.testing.expectEqual(@as(?u64, 5 * std.time.ns_per_s), parseDuration("5"));
    try std.testing.expectEqual(@as(?u64, null), parseDuration("m"));
    try std.testing.expectEqual(@as(?u64, null), parseDuration("1w"));
}

test parseSize {
    try std.testing.expectEqual(@as(?u64, 4 << 30), parseSize("4G"));
    try std.testing.expectEqual(@as(?u64, 512 << 20), parseSize("512m"));
    try std.testing.expectEqual(@as(?u64, null), parseSize("lots"));
}

test parseNet {
    try std.testing.expectEqual(@as(?types.Net, .disable), parseNet("none"));
    try std.testing.expectEqual(@as(?types.Net, .outbound), parseNet("outbound"));
}
