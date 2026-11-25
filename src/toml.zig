//! The subset of TOML `h9x.toml` needs: tables, strings, integers,
//! booleans, arrays of strings, and multi-line basic strings. Anything else
//! is a config error with its line (exit 2).
//!
//! Owned by W1.
//!
//! What's read: `[table]` headers with a bare name, `key = value` with a
//! bare key, `#` comments, basic strings (`"..."`, with TOML's escapes),
//! literal strings (`'...'`), multi-line basic and literal strings
//! (`"""` and `'''`), decimal integers with `_` separators, `true` and
//! `false`, and arrays of strings, which may span lines and end with a
//! comma. Dotted keys and tables, quoted keys, inline tables, arrays of
//! tables, floats, dates, and arrays of anything but strings are errors,
//! and so is a key or table given twice.

const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
    strings: []const []const u8,

    pub fn kind(v: Value) []const u8 {
        return switch (v) {
            .string => "a string",
            .integer => "an integer",
            .boolean => "a boolean",
            .strings => "an array of strings",
        };
    }
};

pub const Entry = struct {
    key: []const u8,
    value: Value,
    /// Where the key is, 1-based.
    line: usize,
};

pub const Table = struct {
    /// Empty for the keys before the first header.
    name: []const u8,
    line: usize,
    entries: []const Entry,

    pub fn get(t: Table, key: []const u8) ?Entry {
        for (t.entries) |e| if (std.mem.eql(u8, e.key, key)) return e;
        return null;
    }
};

pub const Document = struct {
    /// In file order; the first is the top level, with no name.
    tables: []const Table,

    pub fn table(d: Document, name: []const u8) ?Table {
        for (d.tables) |t| if (std.mem.eql(u8, t.name, name)) return t;
        return null;
    }
};

/// Where a parse failed, and why.
pub const Diag = struct {
    line: usize = 0,
    msg: []const u8 = "",
};

pub const Error = error{ Syntax, OutOfMemory };

pub fn parse(arena: std.mem.Allocator, text: []const u8, diag: *Diag) Error!Document {
    var p: Parser = .{ .arena = arena, .s = text, .diag = diag };
    return p.document();
}

const Parser = struct {
    arena: std.mem.Allocator,
    s: []const u8,
    i: usize = 0,
    line: usize = 1,
    diag: *Diag,

    fn fail(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        p.diag.* = .{ .line = p.line, .msg = try std.fmt.allocPrint(p.arena, fmt, args) };
        return error.Syntax;
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.i < p.s.len) p.s[p.i] else null;
    }

    fn startsWith(p: *Parser, lit: []const u8) bool {
        return std.mem.startsWith(u8, p.s[p.i..], lit);
    }

    /// Spaces and tabs.
    fn blanks(p: *Parser) void {
        while (p.peek()) |c| {
            if (c != ' ' and c != '\t') break;
            p.i += 1;
        }
    }

    /// A comment, if there is one, then the end of the line or the file.
    fn endLine(p: *Parser) Error!void {
        p.blanks();
        if (p.peek() == '#') while (p.peek()) |c| {
            if (c == '\n') break;
            p.i += 1;
        };
        if (p.startsWith("\r\n")) p.i += 1;
        const c = p.peek() orelse return;
        if (c != '\n') return p.fail("unexpected {f} after the value", .{fmtChar(c)});
        p.i += 1;
        p.line += 1;
    }

    /// Blanks, newlines, and comments, as between an array's items.
    fn space(p: *Parser) void {
        while (p.peek()) |c| switch (c) {
            ' ', '\t', '\r' => p.i += 1,
            '\n' => {
                p.i += 1;
                p.line += 1;
            },
            '#' => while (p.peek()) |d| {
                if (d == '\n') break;
                p.i += 1;
            },
            else => return,
        };
    }

    fn document(p: *Parser) Error!Document {
        var tables: std.ArrayList(Table) = .empty;
        var name: []const u8 = "";
        var name_line: usize = 1;
        var entries: std.ArrayList(Entry) = .empty;
        while (true) {
            p.blanks();
            const c = p.peek() orelse break;
            switch (c) {
                '\n', '\r', '#' => try p.endLine(),
                '[' => {
                    try tables.append(p.arena, .{ .name = name, .line = name_line, .entries = entries.items });
                    entries = .empty;
                    name_line = p.line;
                    name = try p.header();
                    for (tables.items) |t| if (std.mem.eql(u8, t.name, name))
                        return p.fail("table [{s}] is given twice", .{name});
                },
                else => {
                    const e = try p.keyValue();
                    for (entries.items) |have| if (std.mem.eql(u8, have.key, e.key))
                        return p.fail("{s} is given twice", .{e.key});
                    try entries.append(p.arena, e);
                },
            }
        }
        try tables.append(p.arena, .{ .name = name, .line = name_line, .entries = entries.items });
        return .{ .tables = tables.items };
    }

    fn header(p: *Parser) Error![]const u8 {
        p.i += 1;
        if (p.peek() == '[') return p.fail("arrays of tables aren't supported", .{});
        p.blanks();
        const name = try p.bareKey("a table name");
        p.blanks();
        if (p.peek() == '.') return p.fail("dotted table names aren't supported", .{});
        if (p.peek() != ']') return p.fail("want ] after [{s}", .{name});
        p.i += 1;
        try p.endLine();
        return name;
    }

    fn bareKey(p: *Parser, what: []const u8) Error![]const u8 {
        const start = p.i;
        while (p.peek()) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') break;
            p.i += 1;
        }
        if (p.i == start) {
            const c = p.peek() orelse return p.fail("want {s}", .{what});
            if (c == '"' or c == '\'') return p.fail("quoted keys aren't supported", .{});
            return p.fail("want {s}, not {f}", .{ what, fmtChar(c) });
        }
        return p.s[start..p.i];
    }

    fn keyValue(p: *Parser) Error!Entry {
        const line = p.line;
        const key = try p.bareKey("a key");
        p.blanks();
        if (p.peek() == '.') return p.fail("dotted keys aren't supported", .{});
        if (p.peek() != '=') return p.fail("want = after {s}", .{key});
        p.i += 1;
        p.blanks();
        const v = try p.value(key);
        try p.endLine();
        return .{ .key = key, .value = v, .line = line };
    }

    fn value(p: *Parser, key: []const u8) Error!Value {
        const c = p.peek() orelse return p.fail("{s} has no value", .{key});
        switch (c) {
            '"', '\'' => return .{ .string = try p.string() },
            '[' => return .{ .strings = try p.array(key) },
            '{' => return p.fail("{s}: inline tables aren't supported", .{key}),
            't', 'f' => {
                if (p.word("true")) return .{ .boolean = true };
                if (p.word("false")) return .{ .boolean = false };
            },
            '+', '-', '0'...'9' => return .{ .integer = try p.integer(key) },
            '\n', '\r', '#' => return p.fail("{s} has no value", .{key}),
            else => {},
        }
        return p.fail("{s}: not a string, integer, boolean, or array of strings", .{key});
    }

    fn word(p: *Parser, w: []const u8) bool {
        if (!p.startsWith(w)) return false;
        const after = p.i + w.len;
        if (after < p.s.len and (std.ascii.isAlphanumeric(p.s[after]) or p.s[after] == '_')) return false;
        p.i = after;
        return true;
    }

    fn integer(p: *Parser, key: []const u8) Error!i64 {
        const start = p.i;
        if (p.peek() == '+' or p.peek() == '-') p.i += 1;
        while (p.peek()) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.' and c != ':') break;
            p.i += 1;
        }
        const raw = p.s[start..p.i];
        var digits: std.ArrayList(u8) = .empty;
        var prev_digit = false;
        for (raw, 0..) |c, n| {
            if (c == '_') {
                if (!prev_digit or n + 1 == raw.len or !std.ascii.isDigit(raw[n + 1])) return p.badInt(key, raw);
                prev_digit = false;
                continue;
            }
            if (!std.ascii.isDigit(c) and !(n == 0 and (c == '+' or c == '-'))) return p.badInt(key, raw);
            prev_digit = std.ascii.isDigit(c);
            try digits.append(p.arena, c);
        }
        const d = digits.items;
        const body = if (d.len > 0 and (d[0] == '+' or d[0] == '-')) d[1..] else d;
        if (body.len == 0 or (body.len > 1 and body[0] == '0')) return p.badInt(key, raw);
        return std.fmt.parseInt(i64, d, 10) catch p.fail("{s}: {s} is out of range", .{ key, raw });
    }

    fn badInt(p: *Parser, key: []const u8, raw: []const u8) Error {
        return p.fail("{s}: {s} isn't a decimal integer (floats, dates, and other bases aren't supported)", .{ key, raw });
    }

    fn array(p: *Parser, key: []const u8) Error![]const []const u8 {
        p.i += 1;
        var items: std.ArrayList([]const u8) = .empty;
        while (true) {
            p.space();
            const c = p.peek() orelse return p.fail("{s}: the array isn't closed", .{key});
            if (c == ']') {
                p.i += 1;
                return items.items;
            }
            if (c != '"' and c != '\'') return p.fail("{s}: only arrays of strings are supported", .{key});
            try items.append(p.arena, try p.string());
            p.space();
            const d = p.peek() orelse return p.fail("{s}: the array isn't closed", .{key});
            if (d == ',') {
                p.i += 1;
            } else if (d != ']') {
                return p.fail("{s}: want , or ] in the array", .{key});
            }
        }
    }

    fn string(p: *Parser) Error![]const u8 {
        if (p.startsWith("\"\"\"")) return p.multiline(true);
        if (p.startsWith("'''")) return p.multiline(false);
        const q = p.s[p.i];
        p.i += 1;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = p.peek() orelse return p.fail("the string isn't closed", .{});
            if (c == '\n') return p.fail("the string isn't closed on its line", .{});
            p.i += 1;
            if (c == q) return out.items;
            if (q == '"' and c == '\\') {
                try p.escape(&out);
                continue;
            }
            if (isControl(c)) return p.fail("{f} in a string", .{fmtChar(c)});
            try out.append(p.arena, c);
        }
    }

    /// A multi-line string, after its opening quotes: a newline right
    /// after them is dropped, and in a basic string a `\` at the end of a
    /// line drops it and the whitespace after.
    fn multiline(p: *Parser, basic: bool) Error![]const u8 {
        const q: u8 = if (basic) '"' else '\'';
        const close: []const u8 = if (basic) "\"\"\"" else "'''";
        const start = p.line;
        p.i += 3;
        if (p.startsWith("\r\n")) p.i += 1;
        if (p.peek() == '\n') {
            p.i += 1;
            p.line += 1;
        }
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (p.startsWith(close)) {
                p.i += 3;
                // Up to two more quotes belong to the string.
                var extra: usize = 0;
                while (extra < 2 and p.peek() == q) : (extra += 1) {
                    try out.append(p.arena, q);
                    p.i += 1;
                }
                return out.items;
            }
            const c = p.peek() orelse {
                p.line = start;
                return p.fail("the multi-line string isn't closed", .{});
            };
            p.i += 1;
            if (c == '\n') p.line += 1;
            if (basic and c == '\\') {
                // A line-ending backslash.
                var j = p.i;
                while (j < p.s.len and (p.s[j] == ' ' or p.s[j] == '\t' or p.s[j] == '\r')) j += 1;
                if (j < p.s.len and p.s[j] == '\n') {
                    p.i = j;
                    while (p.peek()) |d| switch (d) {
                        ' ', '\t', '\r' => p.i += 1,
                        '\n' => {
                            p.i += 1;
                            p.line += 1;
                        },
                        else => break,
                    };
                    continue;
                }
                try p.escape(&out);
                continue;
            }
            if (c != '\n' and c != '\t' and c != '\r' and isControl(c)) return p.fail("{f} in a string", .{fmtChar(c)});
            try out.append(p.arena, c);
        }
    }

    /// The escape after a `\`.
    fn escape(p: *Parser, out: *std.ArrayList(u8)) Error!void {
        const c = p.peek() orelse return p.fail("the string isn't closed", .{});
        p.i += 1;
        const b: u8 = switch (c) {
            'b' => 0x08,
            't' => '\t',
            'n' => '\n',
            'f' => 0x0c,
            'r' => '\r',
            'e' => 0x1b,
            '"' => '"',
            '\\' => '\\',
            'u', 'U' => {
                const n: usize = if (c == 'u') 4 else 8;
                if (p.i + n > p.s.len) return p.fail("\\{c} wants {d} hex digits", .{ c, n });
                const cp = std.fmt.parseInt(u21, p.s[p.i .. p.i + n], 16) catch
                    return p.fail("\\{c} wants {d} hex digits", .{ c, n });
                p.i += n;
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &buf) catch return p.fail("\\{c}{s} isn't a Unicode scalar value", .{ c, p.s[p.i - n .. p.i] });
                try out.appendSlice(p.arena, buf[0..len]);
                return;
            },
            else => return p.fail("\\{f} isn't an escape", .{fmtChar(c)}),
        };
        try out.append(p.arena, b);
    }
};

fn isControl(c: u8) bool {
    return c < 0x20 or c == 0x7f;
}

const Char = struct {
    c: u8,
    pub fn format(ch: Char, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (std.ascii.isPrint(ch.c)) return w.print("'{c}'", .{ch.c});
        return w.print("byte 0x{x:0>2}", .{ch.c});
    }
};

fn fmtChar(c: u8) Char {
    return .{ .c = c };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "the subset h9x.toml uses" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    var diag: Diag = .{};
    const doc = try parse(a.allocator(),
        \\# h9x.toml
        \\top = 1
        \\
        \\[roots]
        \\base  = ["libjemalloc"]          # more Wolfi packages at run time
        \\build = [
        \\  "protobuf-dev",  # a comment
        \\  'cmake',
        \\]
        \\
        \\[build]
        \\memory = "4G"
        \\pids = 1_000
        \\neg = -3
        \\on = true
        \\off = false
        \\esc = "tab\there \"q\" \u00e9"
        \\lit = 'C:\no\escapes'
        \\empty = []
        \\
        \\[run]
        \\policy = """
        \\net disable
        \\write overlay \
        \\    memory 1G
        \\"""
        \\raw = '''
        \\one 'two' ''three'''
        \\
    , &diag);
    try testing.expectEqual(@as(usize, 4), doc.tables.len);
    try testing.expectEqual(@as(i64, 1), doc.tables[0].get("top").?.value.integer);
    const roots = doc.table("roots").?;
    try testing.expectEqualStrings("libjemalloc", roots.get("base").?.value.strings[0]);
    const build = roots.get("build").?;
    try testing.expectEqual(@as(usize, 6), build.line);
    try testing.expectEqualStrings("cmake", build.value.strings[1]);
    const b = doc.table("build").?;
    try testing.expectEqualStrings("4G", b.get("memory").?.value.string);
    try testing.expectEqual(@as(i64, 1000), b.get("pids").?.value.integer);
    try testing.expectEqual(@as(i64, -3), b.get("neg").?.value.integer);
    try testing.expect(b.get("on").?.value.boolean);
    try testing.expect(!b.get("off").?.value.boolean);
    try testing.expectEqualStrings("tab\there \"q\" \u{e9}", b.get("esc").?.value.string);
    try testing.expectEqualStrings("C:\\no\\escapes", b.get("lit").?.value.string);
    try testing.expectEqual(@as(usize, 0), b.get("empty").?.value.strings.len);
    const r = doc.table("run").?;
    try testing.expectEqualStrings("net disable\nwrite overlay memory 1G\n", r.get("policy").?.value.string);
    try testing.expectEqualStrings("one 'two' ''three", r.get("raw").?.value.string);
    try testing.expectEqual(@as(usize, 27), r.get("raw").?.line);
}

test "anything else is an error with its line" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const cases = [_]struct { []const u8, usize }{
        .{ "x = 1.5", 1 },
        .{ "\n\nx = 1979-05-27", 3 },
        .{ "[a.b]", 1 },
        .{ "[[a]]", 1 },
        .{ "a.b = 1", 1 },
        .{ "\"a\" = 1", 1 },
        .{ "x = {a = 1}", 1 },
        .{ "x = [1, 2]", 1 },
        .{ "x = \"open", 1 },
        .{ "x = 1\nx = 2", 2 },
        .{ "[a]\n[a]", 2 },
        .{ "x = 1 2", 1 },
        .{ "x =", 1 },
        .{ "x = 0x10", 1 },
        .{ "x = 01", 1 },
        .{ "x = \"\\q\"", 1 },
        .{ "x = \"\"\"\nnever closed", 1 },
        .{ "x = [\"a\"\n\"b\"]", 2 },
        .{ "x = nope", 1 },
    };
    for (cases) |c| {
        var diag: Diag = .{};
        try testing.expectError(error.Syntax, parse(a.allocator(), c[0], &diag));
        testing.expectEqual(c[1], diag.line) catch |e| {
            std.debug.print("{s}: line {d}: {s}\n", .{ c[0], diag.line, diag.msg });
            return e;
        };
        try testing.expect(diag.msg.len > 0);
    }
}
