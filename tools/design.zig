//! The design tool: lists and checks the proposals under design/
//! (design/README.md, design/design-process.md). Run as
//! `zig build design -- <command>` from the repository root.
//!
//! A proposal's frontmatter is a strict subset of YAML: one `key: value`
//! per line, values are scalars or flow lists (`[a, b]`), with no blank
//! lines, comments, nesting, quoting, or multi-line values.

const std = @import("std");
const builtin = @import("builtin");

const usage =
    \\usage: zig build design -- <command> [args]
    \\
    \\  list [--status S] [--area A]    proposals, their status, and ready, in progress, stalled, or what they need
    \\  ready                           accepted proposals with no branch whose dependencies are all implemented
    \\  graph                           the dependency graph, as Mermaid
    \\  new <slug> [--title T] [--author LOGIN]
    \\                                  start a draft from design/TEMPLATE.md
    \\  log <slug>                      its status and branch changes, from git
    \\  check                           validate the proposals and the links to design/
    \\
;

/// Days without a commit before a branch's work counts as stalled.
const stalled_days = 7;

pub const Status = enum {
    draft,
    proposed,
    accepted,
    declined,
    hold,
    implemented,
    superseded,

    /// Decided and closed: nothing is waiting on it.
    pub fn closed(s: Status) bool {
        return s == .implemented or s == .declined or s == .superseded;
    }
};

pub const Proposal = struct {
    /// Its file's name in design/.
    file: []const u8,
    /// The number of its GitHub issue, once it has one.
    issue: ?u32 = null,
    slug: []const u8 = "",
    title: []const u8 = "",
    status: Status = .draft,
    created: []const u8 = "",
    authors: []const []const u8 = &.{},
    /// Slugs, as written.
    depends: []const []const u8 = &.{},
    areas: []const []const u8 = &.{},
    /// The git branches where its work lives; `[main]` once implemented.
    branch: []const []const u8 = &.{},
    superseded_by: ?[]const u8 = null,
    /// Lines of `depends`, `branch`, and `superseded-by`, for messages.
    depends_line: u32 = 0,
    branch_line: u32 = 0,
    superseded_line: u32 = 0,
    /// Everything after the frontmatter, and the line of the file just
    /// before it, so body line n is file line `body_offset + n`.
    body: []const u8 = "",
    body_offset: u32 = 0,
    /// False when the frontmatter had errors; the fields may be partial.
    ok: bool = true,

    pub fn onMain(p: Proposal) bool {
        for (p.branch) |b| if (std.mem.eql(u8, b, "main")) return true;
        return false;
    }
};

/// Messages from parsing and checking, as `file:line: text`.
pub const Diags = struct {
    gpa: std.mem.Allocator,
    errors: std.ArrayList([]const u8) = .empty,
    warnings: std.ArrayList([]const u8) = .empty,

    pub fn err(d: *Diags, comptime fmt: []const u8, args: anytype) void {
        d.errors.append(d.gpa, std.fmt.allocPrint(d.gpa, fmt, args) catch return) catch {};
    }

    pub fn warn(d: *Diags, comptime fmt: []const u8, args: anytype) void {
        d.warnings.append(d.gpa, std.fmt.allocPrint(d.gpa, fmt, args) catch return) catch {};
    }
};

// ---- frontmatter ----

const keys = [_][]const u8{ "issue", "slug", "title", "status", "created", "authors", "depends", "areas", "branch", "superseded-by" };
const required = [_][]const u8{ "slug", "title", "status", "created", "authors", "depends" };
const lists = [_][]const u8{ "authors", "depends", "areas", "branch" };

fn member(set: []const []const u8, s: []const u8) bool {
    for (set) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// A slug: lowercase words of letters and digits joined by dashes. It
/// can't be all digits, which would read as an issue number.
pub fn validSlug(s: []const u8) bool {
    if (s.len == 0 or s[0] == '-' or isId(s)) return false;
    var prev_dash = false;
    for (s) |c| {
        if (c == '-') {
            if (prev_dash) return false;
            prev_dash = true;
        } else if (std.ascii.isLower(c) or std.ascii.isDigit(c)) {
            prev_dash = false;
        } else return false;
    }
    return !prev_dash;
}

/// All digits: an issue number rather than a slug.
pub fn isId(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn validDate(s: []const u8) bool {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return false;
    for (s, 0..) |c, i| if (i != 4 and i != 7 and !std.ascii.isDigit(c)) return false;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return false;
    return month >= 1 and month <= 12 and day >= 1 and day <= 31;
}

/// Parses one proposal. `file` is its name in design/, for messages and
/// the filename check. Problems go to `diags`, and the result has `ok`
/// false.
pub fn parse(arena: std.mem.Allocator, file: []const u8, text: []const u8, diags: *Diags) Proposal {
    var p: Proposal = .{ .file = file };
    var lines = std.mem.splitScalar(u8, text, '\n');
    if (!std.mem.eql(u8, std.mem.trimEnd(u8, lines.first(), "\r"), "---")) {
        diags.err("design/{s}:1: no frontmatter (the file must start with ---)", .{file});
        p.ok = false;
        return p;
    }
    var seen: std.ArrayList([]const u8) = .empty;
    // Keys with a bad value, so they aren't also reported as missing or empty.
    var bad: std.ArrayList([]const u8) = .empty;
    var lineno: u32 = 1;
    var closed = false;
    while (lines.next()) |raw| {
        lineno += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, line, "---")) {
            closed = true;
            break;
        }
        if (std.mem.trim(u8, line, " \t").len == 0) {
            diags.err("design/{s}:{d}: blank lines aren't allowed in the frontmatter", .{ file, lineno });
            p.ok = false;
            continue;
        }
        if (line[0] == '#') {
            diags.err("design/{s}:{d}: comments aren't allowed in the frontmatter", .{ file, lineno });
            p.ok = false;
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            diags.err("design/{s}:{d}: not a `key: value` line", .{ file, lineno });
            p.ok = false;
            continue;
        };
        const key = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (key.len == 0 or key[0] == ' ' or key[0] == '\t') {
            diags.err("design/{s}:{d}: nested or indented keys aren't supported", .{ file, lineno });
            p.ok = false;
            continue;
        }
        if (!member(&keys, key)) {
            diags.err("design/{s}:{d}: unknown key `{s}`", .{ file, lineno, key });
            p.ok = false;
            continue;
        }
        if (member(seen.items, key)) {
            diags.err("design/{s}:{d}: duplicate key `{s}`", .{ file, lineno, key });
            p.ok = false;
            continue;
        }
        seen.append(arena, key) catch {};
        if (value.len > 0 and (value[0] == '"' or value[0] == '\'' or value[0] == '|' or value[0] == '>' or value[0] == '{')) {
            diags.err("design/{s}:{d}: `{s}`: quoting, nesting, and multi-line values aren't supported", .{ file, lineno, key });
            p.ok = false;
            bad.append(arena, key) catch {};
            continue;
        }
        if (member(&lists, key)) {
            const items = parseList(arena, value) orelse {
                diags.err("design/{s}:{d}: `{s}` must be a list of plain words, such as [a, b]", .{ file, lineno, key });
                p.ok = false;
                bad.append(arena, key) catch {};
                continue;
            };
            if (std.mem.eql(u8, key, "authors")) p.authors = items;
            if (std.mem.eql(u8, key, "depends")) {
                p.depends = items;
                p.depends_line = lineno;
            }
            if (std.mem.eql(u8, key, "areas")) p.areas = items;
            if (std.mem.eql(u8, key, "branch")) {
                p.branch = items;
                p.branch_line = lineno;
            }
            continue;
        }
        if (plainScalarProblem(value)) |why| {
            diags.err("design/{s}:{d}: `{s}`: {s}, which YAML would read differently", .{ file, lineno, key, why });
            p.ok = false;
            bad.append(arena, key) catch {};
            continue;
        }
        if (std.mem.eql(u8, key, "issue")) {
            p.issue = std.fmt.parseInt(u32, value, 10) catch blk: {
                diags.err("design/{s}:{d}: `issue` must be an issue number, not `{s}`", .{ file, lineno, value });
                p.ok = false;
                break :blk null;
            };
            if (value.len > 0 and value[0] == '+') {
                diags.err("design/{s}:{d}: `issue` must be an issue number, not `{s}`", .{ file, lineno, value });
                p.ok = false;
            }
        } else if (std.mem.eql(u8, key, "slug")) {
            p.slug = value;
            if (!validSlug(value)) {
                diags.err("design/{s}:{d}: bad slug `{s}`: lowercase words of letters and digits joined by dashes, not all digits", .{ file, lineno, value });
                p.ok = false;
            }
        } else if (std.mem.eql(u8, key, "title")) {
            p.title = value;
        } else if (std.mem.eql(u8, key, "status")) {
            p.status = std.meta.stringToEnum(Status, value) orelse blk: {
                diags.err("design/{s}:{d}: unknown status `{s}`", .{ file, lineno, value });
                p.ok = false;
                break :blk .draft;
            };
        } else if (std.mem.eql(u8, key, "created")) {
            p.created = value;
            if (!validDate(value)) {
                diags.err("design/{s}:{d}: `created` must be YYYY-MM-DD, not `{s}`", .{ file, lineno, value });
                p.ok = false;
            }
        } else if (std.mem.eql(u8, key, "superseded-by")) {
            if (value.len > 0) p.superseded_by = value;
            p.superseded_line = lineno;
        }
    }
    if (!closed) {
        diags.err("design/{s}: the frontmatter has no closing ---", .{file});
        p.ok = false;
        return p;
    }
    for (required) |k| if (!member(seen.items, k)) {
        diags.err("design/{s}: missing `{s}`", .{ file, k });
        p.ok = false;
    };
    if (member(seen.items, "title") and !member(bad.items, "title") and p.title.len == 0) {
        diags.err("design/{s}: `title` is empty", .{file});
        p.ok = false;
    }
    if (member(seen.items, "authors") and !member(bad.items, "authors") and p.authors.len == 0) {
        diags.err("design/{s}: `authors` is empty", .{file});
        p.ok = false;
    }
    p.body = lines.rest();
    p.body_offset = lineno;
    return p;
}

/// Words YAML 1.1 or 1.2 reads as a boolean or null rather than a string.
const yaml_words = [_][]const u8{ "y", "n", "yes", "no", "on", "off", "true", "false", "null", "~" };

/// Why a scalar wouldn't read as the same plain string in YAML, or null.
/// Values are never quoted, so these are refused instead.
pub fn plainScalarProblem(v: []const u8) ?[]const u8 {
    if (v.len == 0) return null;
    if (std.mem.indexOfScalar(u8, "-?:,[]{}#&*!|>'\"%@`", v[0]) != null and !(v[0] == '-' and v.len > 1 and v[1] != ' '))
        return "it starts with a YAML indicator";
    if (std.mem.indexOf(u8, v, ": ") != null or v[v.len - 1] == ':') return "it has a colon followed by a space";
    if (std.mem.indexOf(u8, v, " #") != null) return "it has ` #`, which starts a comment";
    for (yaml_words) |w| if (std.ascii.eqlIgnoreCase(v, w)) return "it's a word YAML reads as a boolean or null";
    return null;
}

/// `[a, b]` to its items, or null if it isn't a flow list of plain words.
fn parseList(arena: std.mem.Allocator, value: []const u8) ?[]const []const u8 {
    if (value.len < 2 or value[0] != '[' or value[value.len - 1] != ']') return null;
    const inner = std.mem.trim(u8, value[1 .. value.len - 1], " \t");
    if (inner.len == 0) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |item| {
        const t = std.mem.trim(u8, item, " \t");
        if (t.len == 0) return null;
        // `/` for branch names such as `claude/x`.
        for (t) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '/')) return null;
        out.append(arena, t) catch return null;
    }
    return out.items;
}

/// Files in design/ that aren't proposals.
pub fn isProposalFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".md") and
        !std.mem.eql(u8, name, "README.md") and !std.mem.eql(u8, name, "TEMPLATE.md");
}

/// Reads and parses every proposal in `dir`, in the rough order they were
/// written: by `created`, then by `issue`, then by file name.
pub fn scan(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, diags: *Diags) ![]Proposal {
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !isProposalFile(e.name)) continue;
        try names.append(arena, try arena.dupe(u8, e.name));
    }
    const out = try arena.alloc(Proposal, names.items.len);
    for (names.items, out) |n, *p| {
        const text = try dir.readFileAlloc(io, n, arena, .limited(1 << 22));
        p.* = parse(arena, n, text, diags);
    }
    std.mem.sort(Proposal, out, {}, before);
    return out;
}

fn before(_: void, a: Proposal, b: Proposal) bool {
    switch (std.mem.order(u8, a.created, b.created)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    const ai = a.issue orelse std.math.maxInt(u32);
    const bi = b.issue orelse std.math.maxInt(u32);
    if (ai != bi) return ai < bi;
    return std.mem.order(u8, a.file, b.file) == .lt;
}

/// Looks a reference up by slug, or by issue number (digits), which the
/// command line accepts but `check` refuses in a file.
pub fn resolveRef(ps: []const Proposal, ref: []const u8) ?usize {
    if (isId(ref)) {
        const id = std.fmt.parseInt(u32, ref, 10) catch return null;
        for (ps, 0..) |p, i| if (p.issue == id) return i;
        return null;
    }
    for (ps, 0..) |p, i| if (std.mem.eql(u8, p.slug, ref)) return i;
    return null;
}

/// One item of a Done criteria checklist.
pub const Item = struct {
    /// Line within the body, from 1.
    line: u32,
    mark: enum { open, done, waived, none },
};

/// The top-level list items of the `## Done criteria` section, or null if
/// there is no such section. Indented items and prose are skipped, as are
/// fenced code blocks.
pub fn doneCriteria(arena: std.mem.Allocator, body: []const u8) !?[]const Item {
    var out: std.ArrayList(Item) = .empty;
    var lines = std.mem.splitScalar(u8, body, '\n');
    var lineno: u32 = 0;
    var in = false;
    var found = false;
    var fence = false;
    while (lines.next()) |raw| {
        lineno += 1;
        const line = std.mem.trimEnd(u8, raw, " \r");
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```")) fence = !fence;
        if (fence) continue;
        if (std.mem.startsWith(u8, line, "## ")) {
            in = std.mem.eql(u8, line[3..], "Done criteria");
            found = found or in;
            continue;
        }
        if (!in) continue;
        if (!(std.mem.startsWith(u8, line, "- ") or std.mem.startsWith(u8, line, "* "))) continue;
        const rest = line[2..];
        const mark: @FieldType(Item, "mark") = if (std.mem.startsWith(u8, rest, "[ ] ")) .open else if (std.mem.startsWith(u8, rest, "[x] ")) .done else if (std.mem.startsWith(u8, rest, "[~] ")) .waived else .none;
        try out.append(arena, .{ .line = lineno, .mark = mark });
    }
    return if (found) out.items else null;
}

/// Whether the body has a `## <name>` heading.
fn hasSection(body: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const l = std.mem.trimEnd(u8, line, " \r");
        if (std.mem.startsWith(u8, l, "## ") and std.mem.eql(u8, l[3..], name)) return true;
    }
    return false;
}

// ---- the repository ----

/// The repository as the tool sees it.
const Repo = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    ps: []Proposal,
    /// Files to check links in, relative to the root.
    files: []const []const u8,
    /// Seconds since each branch's last commit, by name, or null when
    /// branches weren't read (no git).
    branches: ?std.StringHashMapUnmanaged(i64),

    const Source = enum {
        /// The files git tracks, and its branches.
        git,
        /// Every file under the root, and branch ages from a `.branches`
        /// file (`name days` per line), for the check fixtures.
        walk,
    };

    fn load(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, root: std.Io.Dir, diags: *Diags, source: Source) !Repo {
        var r: Repo = .{ .arena = arena, .io = io, .root = root, .ps = &.{}, .files = &.{}, .branches = null };
        switch (source) {
            .git => {
                r.files = gitFiles(gpa, io, arena) catch &.{};
                r.branches = gitBranches(gpa, io, arena) catch null;
            },
            .walk => {
                r.files = try walkFiles(arena, gpa, io, root);
                r.branches = try fixtureBranches(arena, io, root);
            },
        }
        var design = root.openDir(io, "design", .{ .iterate = true }) catch |err| {
            diags.err("design/: {t}", .{err});
            return r;
        };
        defer design.close(io);
        r.ps = try scan(arena, io, design, diags);
        return r;
    }

    fn resolve(r: Repo, ref: []const u8) ?usize {
        return resolveRef(r.ps, ref);
    }
};

fn gitFiles(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator) ![]const []const u8 {
    const out = try run(gpa, io, arena, &.{ "git", "ls-files" });
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, out, '\n');
    while (it.next()) |f| try list.append(arena, f);
    return list.items;
}

/// Local branches and origin's, by name, with the age of their last commit.
fn gitBranches(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator) !std.StringHashMapUnmanaged(i64) {
    const out = try run(gpa, io, arena, &.{ "git", "for-each-ref", "--format=%(refname) %(committerdate:unix)", "refs/heads", "refs/remotes/origin" });
    const now = std.Io.Clock.real.now(io).toSeconds();
    var map: std.StringHashMapUnmanaged(i64) = .empty;
    var it = std.mem.tokenizeScalar(u8, out, '\n');
    while (it.next()) |line| {
        const sp = std.mem.lastIndexOfScalar(u8, line, ' ') orelse continue;
        const ref = line[0..sp];
        const name = if (std.mem.startsWith(u8, ref, "refs/heads/")) ref["refs/heads/".len..] else if (std.mem.startsWith(u8, ref, "refs/remotes/origin/")) ref["refs/remotes/origin/".len..] else continue;
        if (std.mem.eql(u8, name, "HEAD")) continue;
        const when = std.fmt.parseInt(i64, line[sp + 1 ..], 10) catch continue;
        const age = now - when;
        const e = try map.getOrPut(arena, name);
        if (!e.found_existing or age < e.value_ptr.*) e.value_ptr.* = age;
    }
    return map;
}

fn fixtureBranches(arena: std.mem.Allocator, io: std.Io, root: std.Io.Dir) !?std.StringHashMapUnmanaged(i64) {
    const text = root.readFileAlloc(io, ".branches", arena, .limited(1 << 16)) catch return null;
    var map: std.StringHashMapUnmanaged(i64) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const name = parts.next() orelse continue;
        const days = std.fmt.parseInt(i64, parts.next() orelse continue, 10) catch continue;
        try map.put(arena, name, days * std.time.s_per_day);
    }
    return map;
}

fn walkFiles(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, root: std.Io.Dir) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var top = try root.openDir(io, ".", .{ .iterate = true });
    defer top.close(io);
    var w = try top.walk(gpa);
    defer w.deinit();
    while (try w.next(io)) |e| {
        if (e.kind != .file) continue;
        // Repo paths use slashes, as git and the links in the docs do; the
        // walk gives backslashes on Windows.
        const p = try arena.dupe(u8, e.path);
        if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, p, '\\', '/');
        try list.append(arena, p);
    }
    return list.items;
}

// ---- check ----

/// Validates everything `check` covers. Errors and warnings go to `diags`.
fn check(r: Repo, diags: *Diags) !void {
    const ps = r.ps;
    var buf: [256]u8 = undefined;

    for (ps, 0..) |p, i| {
        if (validSlug(p.slug)) {
            const want = std.fmt.bufPrint(&buf, "{s}.md", .{p.slug}) catch "";
            if (!std.mem.eql(u8, want, p.file)) diags.err("design/{s}: should be named design/{s}", .{ p.file, want });
        }
        for (ps[0..i]) |q| {
            if (p.slug.len > 0 and std.mem.eql(u8, p.slug, q.slug)) diags.err("design/{s}: slug `{s}` is also used by design/{s}", .{ p.file, p.slug, q.file });
            if (p.issue != null and p.issue == q.issue) diags.err("design/{s}: issue #{d} is also design/{s}'s", .{ p.file, p.issue.?, q.file });
        }
        if (p.status == .proposed and p.issue == null) diags.err("design/{s}: proposed, but it has no `issue`; file one and set it", .{p.file});
        if (p.issue == null and p.slug.len > 0 and std.ascii.isDigit(p.slug[0])) diags.err("design/{s}: slug `{s}` starts with a digit; start it with a letter", .{ p.file, p.slug });
        if (p.status == .superseded and p.superseded_by == null) diags.err("design/{s}: superseded, but `superseded-by` isn't set", .{p.file});
        if (p.status != .superseded and p.superseded_by != null) diags.err("design/{s}:{d}: `superseded-by` is set, but the status is `{t}`", .{ p.file, p.superseded_line, p.status });
        if (p.status == .declined and !hasSection(p.body, "Declined")) diags.err("design/{s}: declined, but it has no `## Declined` section giving the reason", .{p.file});

        // Branches.
        if (p.status == .implemented and !(p.branch.len == 1 and p.onMain()))
            diags.err("design/{s}: implemented, so `branch` must be [main]", .{p.file});
        if (p.status != .implemented and p.onMain())
            diags.err("design/{s}:{d}: `branch` has main, but the status is `{t}`; main is only for implemented proposals", .{ p.file, p.branch_line, p.status });
        if (r.branches) |bs| for (p.branch) |b| {
            if (std.mem.eql(u8, b, "main")) continue;
            if (!bs.contains(b)) diags.warn("design/{s}:{d}: branch `{s}` wasn't found; fetch it, or take it out of `branch` if it's gone", .{ p.file, p.branch_line, b });
        };

        // Done criteria.
        if (try doneCriteria(r.arena, p.body)) |items| {
            var settled: usize = 0;
            for (items) |item| switch (item.mark) {
                .none => diags.err("design/{s}:{d}: a Done criteria item must be a checkbox: `- [ ]`, `- [x]`, or `- [~] Waived: why`", .{ p.file, p.body_offset + item.line }),
                .open => if (p.status == .implemented) diags.err("design/{s}:{d}: implemented, but this Done criteria item isn't checked; check it, or waive it with `- [~] Waived: why`", .{ p.file, p.body_offset + item.line }),
                .done, .waived => settled += 1,
            };
            if ((p.status == .proposed or p.status == .accepted) and items.len > 0 and settled == items.len)
                diags.warn("design/{s}: every Done criteria item is checked or waived, but it's `{t}`; is it implemented?", .{ p.file, p.status });
        }

        // References.
        for (p.depends) |ref| {
            if (isId(ref)) {
                diags.err("design/{s}:{d}: depends on `{s}`; refer to proposals by slug{s}", .{ p.file, p.depends_line, ref, try bySlug(r, ref) });
                continue;
            }
            const j = r.resolve(ref) orelse {
                diags.err("design/{s}:{d}: depends on `{s}`, which isn't a proposal", .{ p.file, p.depends_line, ref });
                continue;
            };
            const q = ps[j];
            if (j == i) diags.err("design/{s}:{d}: depends on itself", .{ p.file, p.depends_line });
            if (p.status == .implemented and q.status != .implemented) diags.err("design/{s}: implemented, but its dependency {s} is `{t}`", .{ p.file, q.slug, q.status });
            if (p.status == .accepted and q.status == .declined) diags.err("design/{s}: accepted, but it depends on {s}, which was declined", .{ p.file, q.slug });
        }
        if (p.superseded_by) |ref| {
            if (isId(ref)) {
                diags.err("design/{s}:{d}: superseded by `{s}`; refer to proposals by slug{s}", .{ p.file, p.superseded_line, ref, try bySlug(r, ref) });
            } else if (r.resolve(ref) == null) diags.err("design/{s}:{d}: superseded by `{s}`, which isn't a proposal", .{ p.file, p.superseded_line, ref });
        }
    }

    try checkCycles(r, diags);
    try checkLinks(r, diags);
}

/// ` (#N is `slug`)` for a number that's some proposal's issue, for messages.
fn bySlug(r: Repo, ref: []const u8) ![]const u8 {
    const j = r.resolve(ref) orelse return "";
    return std.fmt.allocPrint(r.arena, " (#{s} is `{s}`)", .{ ref, r.ps[j].slug });
}

/// Reports each dependency cycle once, as a path.
fn checkCycles(r: Repo, diags: *Diags) !void {
    const n = r.ps.len;
    const color = try r.arena.alloc(u8, n); // 0 unvisited, 1 on the path, 2 done
    @memset(color, 0);
    const path = try r.arena.alloc(usize, n);
    for (0..n) |i| if (color[i] == 0) try visit(r, diags, color, path, 0, i);
}

fn visit(r: Repo, diags: *Diags, color: []u8, path: []usize, depth: usize, i: usize) !void {
    color[i] = 1;
    path[depth] = i;
    for (r.ps[i].depends) |ref| {
        const j = r.resolve(ref) orelse continue;
        if (j == i) continue; // reported as "depends on itself"
        if (color[j] == 1) {
            var s: std.ArrayList(u8) = .empty;
            const start = std.mem.indexOfScalar(usize, path[0 .. depth + 1], j).?;
            for (path[start .. depth + 1]) |k| try s.print(r.arena, "{s} -> ", .{r.ps[k].slug});
            try s.appendSlice(r.arena, r.ps[j].slug);
            diags.err("dependency cycle: {s}", .{s.items});
        } else if (color[j] == 0) try visit(r, diags, color, path, depth + 1, j);
    }
    color[i] = 2;
}

// ---- links ----

/// Whether a Markdown file's links are checked: not in a testdata
/// directory, where fixtures hold broken links on purpose.
fn linkChecked(path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".md")) return false;
    return !(std.mem.startsWith(u8, path, "testdata/") or std.mem.indexOf(u8, path, "/testdata/") != null);
}

fn pathChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '/' or c == '-';
}

/// Fails on a link from a Markdown file to a file under design/ that
/// doesn't exist: a literal `design/<path>.md` that isn't part of a longer
/// path or a URL, and a relative Markdown link whose target is under
/// design/.
fn checkLinks(r: Repo, diags: *Diags) !void {
    var exists: std.StringHashMapUnmanaged(void) = .empty;
    for (r.files) |f| try exists.put(r.arena, f, {});
    for (r.files) |path| {
        if (!linkChecked(path)) continue;
        const text = r.root.readFileAlloc(r.io, path, r.arena, .limited(1 << 22)) catch continue;
        if (std.mem.indexOfScalar(u8, text[0..@min(text.len, 8000)], 0) != null) continue; // binary
        const dir = std.fs.path.dirnamePosix(path) orelse "";
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        var lineno: u32 = 0;
        while (lines.next()) |line| {
            lineno += 1;
            seen.clearRetainingCapacity();
            // Literal paths into design/.
            var pos: usize = 0;
            while (std.mem.indexOfPos(u8, line, pos, "design/")) |at| {
                pos = at + "design/".len;
                if (at > 0 and pathChar(line[at - 1])) continue;
                var end = pos;
                while (end < line.len and pathChar(line[end])) end += 1;
                // Trailing dots end a sentence, not the path.
                while (end > pos and line[end - 1] == '.') end -= 1;
                const target = line[at..end];
                if (!std.mem.endsWith(u8, target, ".md") or target.len == "design/.md".len) continue;
                try expectFile(r, diags, &exists, &seen, path, lineno, try normalize(r.arena, target));
            }
            // Relative Markdown links.
            pos = 0;
            while (std.mem.indexOfPos(u8, line, pos, "](")) |at| {
                pos = at + 2;
                var end = pos;
                while (end < line.len and line[end] != ')' and line[end] != '#' and line[end] != ' ' and line[end] != '\t') end += 1;
                if (end >= line.len or (line[end] != ')' and line[end] != '#')) continue;
                const target = line[pos..end];
                if (target.len == 0 or target[0] == '/' or target[0] == '<') continue;
                if (std.mem.indexOf(u8, target, "://") != null or std.mem.startsWith(u8, target, "mailto:")) continue;
                const joined = try normalize(r.arena, try std.fmt.allocPrint(r.arena, "{s}{s}{s}", .{ dir, if (dir.len > 0) "/" else "", target }));
                if (!std.mem.startsWith(u8, joined, "design/")) continue;
                try expectFile(r, diags, &exists, &seen, path, lineno, joined);
            }
        }
    }
}

fn expectFile(r: Repo, diags: *Diags, exists: *std.StringHashMapUnmanaged(void), seen: *std.StringHashMapUnmanaged(void), path: []const u8, lineno: u32, target: []const u8) !void {
    if (seen.contains(target)) return;
    try seen.put(r.arena, target, {});
    if (exists.contains(target) or isDir(r.files, target)) return;
    diags.err("{s}:{d}: links to {s}, which doesn't exist", .{ path, lineno, target });
}

/// Whether `target` is a directory holding some of `files`.
fn isDir(files: []const []const u8, target: []const u8) bool {
    const t = std.mem.trimEnd(u8, target, "/");
    for (files) |f| if (f.len > t.len and std.mem.startsWith(u8, f, t) and f[t.len] == '/') return true;
    return false;
}

/// A slash path with `.` and `..` resolved, and no trailing slash. A
/// path that climbs above the root keeps its `..`.
fn normalize(arena: std.mem.Allocator, p: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, p, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..") and parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
            _ = parts.pop();
            continue;
        }
        try parts.append(arena, part);
    }
    return std.mem.join(arena, "/", parts.items);
}

// ---- list, ready, graph ----

/// What a proposal is doing or waiting for: in progress or stalled on its
/// branch, ready for an accepted proposal with no branch and everything it
/// depends on implemented, or the unimplemented dependencies.
fn state(r: Repo, p: Proposal, out: *std.ArrayList(u8)) !void {
    if (p.status.closed()) return;
    for (p.branch) |b| {
        if (out.items.len > 0) try out.appendSlice(r.arena, "; ");
        const age = if (r.branches) |bs| bs.get(b) else null;
        if (age) |a| {
            const days = @divFloor(a, std.time.s_per_day);
            if (days > stalled_days) {
                try out.print(r.arena, "stalled on {s} ({d} days)", .{ b, days });
            } else try out.print(r.arena, "in progress on {s}", .{b});
        } else if (r.branches != null) {
            try out.print(r.arena, "stalled: {s} not found", .{b});
        } else try out.print(r.arena, "on {s}", .{b});
    }
    var first = true;
    for (p.depends) |ref| {
        const j = r.resolve(ref) orelse continue;
        const q = r.ps[j];
        if (q.status == .implemented) continue;
        if (first and out.items.len > 0) try out.appendSlice(r.arena, "; ");
        try out.appendSlice(r.arena, if (first) "needs " else ", ");
        try out.appendSlice(r.arena, q.slug);
        first = false;
    }
    if (first and p.status == .accepted and p.branch.len == 0) try out.appendSlice(r.arena, "ready");
}

fn isReady(r: Repo, p: Proposal) bool {
    if (p.status != .accepted or p.branch.len > 0) return false;
    for (p.depends) |ref| {
        const j = r.resolve(ref) orelse return false;
        if (r.ps[j].status != .implemented) return false;
    }
    return true;
}

fn hasArea(p: Proposal, area: []const u8) bool {
    for (p.areas) |a| if (std.mem.eql(u8, a, area)) return true;
    return false;
}

fn listCmd(r: Repo, w: *std.Io.Writer, status: ?Status, area: ?[]const u8, ready_only: bool) !void {
    const Row = struct { slug: []const u8, id: []const u8, status: []const u8, state: []const u8, title: []const u8 };
    var rows: std.ArrayList(Row) = .empty;
    try rows.append(r.arena, .{ .slug = "SLUG", .id = "ISSUE", .status = "STATUS", .state = "STATE", .title = "TITLE" });
    for (r.ps) |p| {
        if (status) |s| if (p.status != s) continue;
        if (area) |a| if (!hasArea(p, a)) continue;
        if (ready_only and !isReady(r, p)) continue;
        var st: std.ArrayList(u8) = .empty;
        try state(r, p, &st);
        try rows.append(r.arena, .{
            .slug = p.slug,
            .id = if (p.issue) |id| try std.fmt.allocPrint(r.arena, "#{d}", .{id}) else "-",
            .status = @tagName(p.status),
            .state = if (st.items.len > 0) st.items else "-",
            .title = p.title,
        });
    }
    var widths = @as([4]usize, @splat(0));
    for (rows.items) |row| {
        for ([_][]const u8{ row.slug, row.id, row.status, row.state }, 0..) |cell, k| widths[k] = @max(widths[k], cell.len);
    }
    for (rows.items) |row| {
        for ([_][]const u8{ row.slug, row.id, row.status, row.state }, 0..) |cell, k| {
            try w.writeAll(cell);
            try w.splatByteAll(' ', widths[k] - cell.len + 2);
        }
        try w.print("{s}\n", .{row.title});
    }
}

fn nodeId(arena: std.mem.Allocator, slug: []const u8) ![]const u8 {
    const out = try std.fmt.allocPrint(arena, "p_{s}", .{slug});
    std.mem.replaceScalar(u8, out, '-', '_');
    return out;
}

/// The dependency graph, as a Mermaid flowchart.
fn graph(r: Repo, w: *std.Io.Writer) !void {
    try w.writeAll("flowchart LR\n");
    try w.writeAll(
        \\  classDef draft stroke-dasharray: 4 3
        \\  classDef accepted stroke-width: 2px
        \\  classDef implemented fill:#dfd,stroke:#393
        \\  classDef closed fill:#eee,stroke:#999,color:#777
        \\
    );
    for (r.ps) |p| {
        if (p.slug.len == 0) continue;
        const class = switch (p.status) {
            .draft, .proposed, .hold => "draft",
            .accepted => "accepted",
            .implemented => "implemented",
            .declined, .superseded => "closed",
        };
        try w.print("  {s}[\"{s}<br/>{t}\"]:::{s}\n", .{ try nodeId(r.arena, p.slug), p.slug, p.status, class });
    }
    for (r.ps) |p| for (p.depends) |ref| {
        const j = r.resolve(ref) orelse continue;
        try w.print("  {s} --> {s}\n", .{ try nodeId(r.arena, r.ps[j].slug), try nodeId(r.arena, p.slug) });
    };
}

// ---- new ----

/// Today's date in UTC.
fn today(io: std.Io) [10]u8 {
    const secs: u64 = @intCast(@max(0, std.Io.Clock.real.now(io).toSeconds()));
    const day = (std.time.epoch.EpochSeconds{ .secs = secs }).getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    var out: [10]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), @as(u8, md.day_index) + 1 }) catch unreachable;
    return out;
}

/// The local date where `date` exists, else UTC.
fn localToday(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator) ![]const u8 {
    const local = run(gpa, io, arena, &.{ "date", "+%Y-%m-%d" }) catch "";
    const t = std.mem.trim(u8, local, " \n");
    if (t.len == 10) return t;
    return arena.dupe(u8, &today(io));
}

/// The template with its frontmatter replaced and its title filled in.
fn fromTemplate(arena: std.mem.Allocator, template: []const u8, slug: []const u8, title: []const u8, author: []const u8, date: []const u8) ![]const u8 {
    var body = template;
    if (std.mem.startsWith(u8, body, "---\n")) {
        if (std.mem.indexOf(u8, body[4..], "\n---\n")) |end| body = body[4 + end + 5 ..];
    }
    const filled = try std.mem.replaceOwned(u8, arena, body, "[Title]", title);
    return std.fmt.allocPrint(arena,
        \\---
        \\slug: {s}
        \\title: {s}
        \\status: draft
        \\created: {s}
        \\authors: [{s}]
        \\depends: []
        \\areas: []
        \\branch: []
        \\---
        \\{s}
    , .{ slug, title, date, author, filled });
}

fn newCmd(r: Repo, gpa: std.mem.Allocator, args: []const []const u8) !void {
    var slug: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var author: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--title") and i + 1 < args.len) {
            i += 1;
            title = args[i];
        } else if (std.mem.eql(u8, args[i], "--author") and i + 1 < args.len) {
            i += 1;
            author = args[i];
        } else if (slug == null and args[i].len > 0 and args[i][0] != '-') {
            slug = args[i];
        } else fail("new: unexpected `{s}`\n{s}", .{ args[i], usage });
    }
    const s = slug orelse fail("new: which slug?\n{s}", .{usage});
    if (!validSlug(s)) fail("new: bad slug `{s}`: lowercase words of letters and digits joined by dashes, not all digits", .{s});
    if (std.ascii.isDigit(s[0])) fail("new: bad slug `{s}`: start it with a letter", .{s});
    if (r.resolve(s) != null) fail("new: `{s}` is already a proposal", .{s});
    const t = title orelse try titleFromSlug(r.arena, s);
    if (plainScalarProblem(t)) |why| fail("new: the title can't be used as is: {s}, which YAML would read differently", .{why});
    const a = author orelse (run(gpa, r.io, r.arena, &.{ "gh", "api", "user", "--jq", ".login" }) catch
        fail("new: couldn't get your GitHub login from gh; pass --author LOGIN", .{}));
    const template = r.root.readFileAlloc(r.io, "design/TEMPLATE.md", r.arena, .limited(1 << 20)) catch |err|
        fail("new: design/TEMPLATE.md: {t}", .{err});
    const text = try fromTemplate(r.arena, template, s, t, std.mem.trim(u8, a, " \n"), try localToday(gpa, r.io, r.arena));
    const path = try std.fmt.allocPrint(r.arena, "design/{s}.md", .{s});
    try r.root.writeFile(r.io, .{ .sub_path = path, .data = text, .flags = .{ .exclusive = true } });
    std.debug.print("{s}\n", .{path});
}

fn titleFromSlug(arena: std.mem.Allocator, slug: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, slug);
    std.mem.replaceScalar(u8, out, '-', ' ');
    out[0] = std.ascii.toUpper(out[0]);
    return out;
}

// ---- log ----

/// Prints each commit that changed the proposal's status, branch, or
/// issue, oldest first.
fn logCmd(r: Repo, gpa: std.mem.Allocator, w: *std.Io.Writer, args: []const []const u8) !void {
    if (args.len != 1) fail("log: which slug?\n{s}", .{usage});
    const i = r.resolve(args[0]) orelse fail("log: `{s}` isn't a proposal", .{args[0]});
    const path = try std.fmt.allocPrint(r.arena, "design/{s}", .{r.ps[i].file});
    // git can't combine --follow with --reverse, so the commits come
    // newest first and are printed the other way round.
    const out = run(gpa, r.io, r.arena, &.{ "git", "log", "--follow", "--date=short", "--format=@@commit %h %ad %s", "-p", "--", path }) catch
        fail("log: git log failed", .{});
    const text = try formatLog(r.arena, out);
    var rows: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |row| try rows.append(r.arena, row);
    std.mem.reverse([]const u8, rows.items);
    for (rows.items) |row| try w.print("{s}\n", .{row});
}

fn formatLog(arena: std.mem.Allocator, gitlog: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var head: []const u8 = "";
    var changes: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, gitlog, '\n');
    while (true) {
        const next = lines.next();
        if (next == null or std.mem.startsWith(u8, next.?, "@@commit ")) {
            if (head.len > 0 and changes.items.len > 0) {
                // `%h %ad %s` as `date hash  changes  (subject)`.
                var parts = std.mem.splitScalar(u8, head, ' ');
                const hash = parts.next() orelse "";
                const date = parts.next() orelse "";
                try out.print(arena, "{s} {s}  {s}  ({s})\n", .{ date, hash, changes.items, parts.rest() });
            }
            const line = next orelse break;
            head = line["@@commit ".len..];
            changes = .empty;
            continue;
        }
        const line = next.?;
        for ([_][]const u8{ "+status: ", "+branch: ", "+issue: " }) |key| {
            if (!std.mem.startsWith(u8, line, key)) continue;
            if (changes.items.len > 0) try changes.appendSlice(arena, ", ");
            try changes.appendSlice(arena, line[1..]);
        }
    }
    return out.items;
}

// ---- main ----

/// Runs a command and returns its stdout; fails unless it exits 0.
fn run(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    const res = try std.process.run(gpa, io, .{ .argv = argv });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("{s}", .{res.stderr});
            return error.CommandFailed;
        },
        else => return error.CommandFailed,
    }
    return arena.dupe(u8, res.stdout);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("design: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);
    const args = argv[1..];
    if (args.len == 0 or std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "help")) {
        std.debug.print("{s}", .{usage});
        return if (args.len == 0) 2 else 0;
    }
    const cmd = args[0];
    const rest = args[1..];

    var diags: Diags = .{ .gpa = arena };
    const r = try Repo.load(arena, init.gpa, io, std.Io.Dir.cwd(), &diags, .git);

    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    const w = &out.interface;
    defer w.flush() catch {};

    if (std.mem.eql(u8, cmd, "check")) {
        if (rest.len > 0) fail("check: unexpected `{s}`\n{s}", .{ rest[0], usage });
        try check(r, &diags);
        for (diags.errors.items) |m| std.debug.print("error: {s}\n", .{m});
        for (diags.warnings.items) |m| std.debug.print("warning: {s}\n", .{m});
        if (diags.errors.items.len > 0) return 1;
        try w.print("ok: {d} proposals\n", .{r.ps.len});
        return 0;
    }
    // Other commands work on what parsed, but say what didn't.
    for (diags.errors.items) |m| std.debug.print("error: {s}\n", .{m});
    if (std.mem.eql(u8, cmd, "list")) {
        var status: ?Status = null;
        var area: ?[]const u8 = null;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            if (std.mem.eql(u8, rest[i], "--status") and i + 1 < rest.len) {
                i += 1;
                status = std.meta.stringToEnum(Status, rest[i]) orelse fail("list: unknown status `{s}`", .{rest[i]});
            } else if (std.mem.eql(u8, rest[i], "--area") and i + 1 < rest.len) {
                i += 1;
                area = rest[i];
            } else fail("list: unexpected `{s}`\n{s}", .{ rest[i], usage });
        }
        try listCmd(r, w, status, area, false);
    } else if (std.mem.eql(u8, cmd, "ready")) {
        try listCmd(r, w, null, null, true);
    } else if (std.mem.eql(u8, cmd, "graph")) {
        try graph(r, w);
    } else if (std.mem.eql(u8, cmd, "new")) {
        try newCmd(r, init.gpa, rest);
    } else if (std.mem.eql(u8, cmd, "log")) {
        try logCmd(r, init.gpa, w, rest);
    } else {
        std.debug.print("design: unknown command `{s}`\n{s}", .{ cmd, usage });
        return 2;
    }
    return 0;
}

// ---- tests ----

// Runs check over each fixture in tools/testdata/check. A fixture is a
// txtar-style file: comment lines first, each `error: text` or
// `warning: text` that check must report (as a substring), then files as
// `-- path --` followed by their contents. The fixture must produce
// exactly the listed messages. A `.branches` file gives branch ages in
// days (`name days` per line); without one, branches aren't checked.
test "check fixtures" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "tools/testdata/check", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(io)) |e| {
        if (!std.mem.endsWith(u8, e.name, ".txtar")) continue;
        count += 1;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const text = try dir.readFileAlloc(io, e.name, arena, .limited(1 << 20));

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var want_err: std.ArrayList([]const u8) = .empty;
        var want_warn: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        var cur: ?[]const u8 = null;
        var content: std.ArrayList(u8) = .empty;
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "-- ") and std.mem.endsWith(u8, line, " --")) {
                if (cur) |path| try writeFixture(io, tmp.dir, path, content.items);
                cur = line[3 .. line.len - 3];
                content = .empty;
            } else if (cur != null) {
                try content.appendSlice(arena, line);
                try content.append(arena, '\n');
            } else if (std.mem.startsWith(u8, line, "error: ")) {
                try want_err.append(arena, line["error: ".len..]);
            } else if (std.mem.startsWith(u8, line, "warning: ")) {
                try want_warn.append(arena, line["warning: ".len..]);
            }
        }
        if (cur) |path| try writeFixture(io, tmp.dir, path, content.items);

        var diags: Diags = .{ .gpa = arena };
        const r = try Repo.load(arena, gpa, io, tmp.dir, &diags, .walk);
        try check(r, &diags);
        try expectMessages(e.name, "error", want_err.items, diags.errors.items);
        try expectMessages(e.name, "warning", want_warn.items, diags.warnings.items);
    }
    try std.testing.expect(count > 0);
}

fn writeFixture(io: std.Io, dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.createDirPath(io, d);
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

fn expectMessages(fixture: []const u8, kind: []const u8, want: []const []const u8, got: []const []const u8) !void {
    var ok = want.len == got.len;
    for (want) |w| {
        var found = false;
        for (got) |g| found = found or std.mem.indexOf(u8, g, w) != null;
        ok = ok and found;
    }
    if (ok) return;
    std.debug.print("{s}: {s}s don't match\n  want:\n", .{ fixture, kind });
    for (want) |w| std.debug.print("    {s}\n", .{w});
    std.debug.print("  got:\n", .{});
    for (got) |g| std.debug.print("    {s}\n", .{g});
    return error.TestUnexpectedResult;
}

test "parse a proposal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var d: Diags = .{ .gpa = arena };
    const p = parse(arena, "oci-push.md",
        \\---
        \\issue: 42
        \\slug: oci-push
        \\title: Pushing images to a registry
        \\status: accepted
        \\created: 2026-11-03
        \\authors: [progrium]
        \\depends: [43, prototype]
        \\areas: []
        \\superseded-by:
        \\---
        \\
        \\# Proposal: Pushing images to a registry
        \\
    , &d);
    try std.testing.expectEqual(@as(usize, 0), d.errors.items.len);
    try std.testing.expect(p.ok);
    try std.testing.expectEqual(@as(?u32, 42), p.issue);
    try std.testing.expectEqual(@as(usize, 0), p.branch.len);
    try std.testing.expectEqual(Status.accepted, p.status);
    try std.testing.expectEqual(@as(usize, 2), p.depends.len);
    try std.testing.expectEqualStrings("prototype", p.depends[1]);
    try std.testing.expectEqual(@as(?[]const u8, null), p.superseded_by);
    try std.testing.expect(std.mem.startsWith(u8, p.body, "\n# Proposal"));
}

test "plain scalars" {
    try std.testing.expect(plainScalarProblem("Packs and executables") == null);
    try std.testing.expect(plainScalarProblem("Exports (--oci)") == null);
    try std.testing.expect(plainScalarProblem("-x is fine") == null);
    try std.testing.expect(plainScalarProblem("Prototype: h9x") != null);
    try std.testing.expect(plainScalarProblem("#1 thing") != null);
    try std.testing.expect(plainScalarProblem("a #b") != null);
    try std.testing.expect(plainScalarProblem("- item") != null);
    try std.testing.expect(plainScalarProblem("ends:") != null);
    try std.testing.expect(plainScalarProblem("Yes") != null);
    try std.testing.expect(plainScalarProblem("null") != null);
    try std.testing.expect(plainScalarProblem("Yes, this") == null);
}

test "done criteria" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(try doneCriteria(arena, "\n## Abstract\n\n- x\n") == null);
    const items = (try doneCriteria(arena, "\n## Done criteria\n\nProse.\n\n- [ ] a\n  - nested\n- [x] b\n- [~] Waived: c\n- d\n```\n- e\n```\n\n## Implementation\n\n- f\n")).?;
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expect(items[0].mark == .open and items[1].mark == .done and items[2].mark == .waived and items[3].mark == .none);
}

test "slugs" {
    try std.testing.expect(validSlug("oci-push"));
    try std.testing.expect(validSlug("h9-bump"));
    try std.testing.expect(validSlug("42") == false);
    try std.testing.expect(validSlug("a--b") == false);
    try std.testing.expect(validSlug("a-") == false);
    try std.testing.expect(validSlug("Big") == false);
}

test "normalize" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_][2][]const u8{
        .{ "design/./a.md", "design/a.md" },
        .{ "spec/../design/a.md", "design/a.md" },
        .{ "design/../../x.md", "../x.md" },
        .{ "design/", "design" },
    };
    for (cases) |c| {
        try std.testing.expectEqualStrings(c[1], try normalize(arena, c[0]));
    }
}

test "state: ready, in progress, and stalled" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var bs: std.StringHashMapUnmanaged(i64) = .empty;
    try bs.put(arena, "fresh", 2 * std.time.s_per_day);
    try bs.put(arena, "old", 12 * std.time.s_per_day);
    var ps = [_]Proposal{
        .{ .file = "a.md", .slug = "a", .status = .accepted },
        .{ .file = "b.md", .slug = "b", .status = .accepted, .branch = &.{"fresh"} },
        .{ .file = "c.md", .slug = "c", .status = .draft, .branch = &.{"old"} },
        .{ .file = "d.md", .slug = "d", .status = .accepted, .branch = &.{"gone"} },
        .{ .file = "e.md", .slug = "e", .status = .accepted, .depends = &.{"c"} },
    };
    const r: Repo = .{ .arena = arena, .io = std.testing.io, .root = std.Io.Dir.cwd(), .ps = &ps, .files = &.{}, .branches = bs };
    const want = [_][]const u8{ "ready", "in progress on fresh", "stalled on old (12 days)", "stalled: gone not found", "needs c" };
    for (ps, want) |p, w| {
        var st: std.ArrayList(u8) = .empty;
        try state(r, p, &st);
        try std.testing.expectEqualStrings(w, st.items);
    }
    try std.testing.expect(isReady(r, ps[0]) and !isReady(r, ps[1]));
}

test "new fills the template" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try fromTemplate(arena_state.allocator(), "---\nslug: x\n---\n\n# Proposal: [Title]\n", "oci-push", "Pushing images", "progrium", "2026-11-03");
    try std.testing.expectEqualStrings(
        \\---
        \\slug: oci-push
        \\title: Pushing images
        \\status: draft
        \\created: 2026-11-03
        \\authors: [progrium]
        \\depends: []
        \\areas: []
        \\branch: []
        \\---
        \\
        \\# Proposal: Pushing images
        \\
    , out);
}

test "log" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gitlog =
        \\@@commit 4be5ab3 2026-11-07 design: draft oci-push
        \\
        \\diff --git a/design/oci-push.md b/design/oci-push.md
        \\+status: draft
        \\+Some body text.
        \\@@commit 0b1c2d3 2026-11-08 design: tidy oci-push
        \\-old
        \\+new
        \\@@commit 196b924 2026-11-11 Push images to a registry
        \\-status: accepted
        \\+status: implemented
        \\+branch: [main]
        \\
    ;
    try std.testing.expectEqualStrings(
        "2026-11-07 4be5ab3  status: draft  (design: draft oci-push)\n2026-11-11 196b924  status: implemented, branch: [main]  (Push images to a registry)\n",
        try formatLog(arena_state.allocator(), gitlog),
    );
}
