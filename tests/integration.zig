//! The prototype's integration cases (design/prototype.md, "Done
//! criteria"), run by `zig build integration`: the h9x this build makes,
//! run as a program on Railpack's examples, building and running them on
//! h9 for real.
//!
//! They take a while (a cold build of every example is most of an hour)
//! and need the network, so `zig build test` doesn't run them. They read:
//!
//!   H9X_EXAMPLES       Railpack's examples directory. Without it, Railpack
//!                      is cloned at the pinned tag into the build's cache.
//!   H9X_EXAMPLES_ONLY  A comma-separated list of the examples the first
//!                      case builds, rather than all fourteen.
//!   H9X_CACHE, H9X_BACKEND, H9X_RAILPACK, HTTPS_PROXY, SSL_CERT_FILE,
//!   and mise's switches, passed to h9x as they are, so a warm cache is
//!   reused. Builds should run on a hypervisor or the native backend.

const std = @import("std");
const builtin = @import("builtin");
const opts = @import("integration_options");

const Io = std.Io;
const gpa = std.testing.allocator;

/// Railpack's tag the examples come from: the version h9x pins.
const railpack_tag = "v0.43.0";

// ---------------------------------------------------------------- helpers

const Result = struct {
    code: u8,
    stdout: []const u8,
    stderr: []const u8,

    fn ok(r: Result) !void {
        if (r.code == 0) return;
        std.debug.print("exit {d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ r.code, r.stdout, r.stderr });
        return error.Failed;
    }

    fn has(r: Result, text: []const u8) bool {
        return std.mem.indexOf(u8, r.stdout, text) != null;
    }
};

const Run = struct {
    cwd: ?[]const u8 = null,
    /// Variables set over the host's, or with `clean`, the only ones.
    env: []const [2][]const u8 = &.{},
    clean: bool = false,
};

/// The integration directory, absolute.
fn work() []const u8 {
    const S = struct {
        var dir: ?[]const u8 = null;
    };
    if (S.dir) |d| return d;
    Io.Dir.cwd().createDirPath(std.testing.io, opts.work) catch {};
    S.dir = Io.Dir.cwd().realPathFileAlloc(std.testing.io, opts.work, arena) catch opts.work;
    return S.dir.?;
}

var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
const arena = arena_state.allocator();

fn hostEnv() !std.process.Environ.Map {
    return std.testing.environ.createMap(arena);
}

/// Runs `argv`, the first of which may be "h9x", with stdin empty.
fn run(argv: []const []const u8, r: Run) !Result {
    const io = std.testing.io;
    var env: std.process.Environ.Map = if (r.clean) .init(arena) else try hostEnv();
    for (r.env) |kv| try env.put(kv[0], kv[1]);
    var full: std.ArrayList([]const u8) = .empty;
    // Absolute, so a case can run it from another directory.
    try full.append(arena, if (std.mem.eql(u8, argv[0], "h9x")) try Io.Dir.cwd().realPathFileAlloc(io, opts.h9x, arena) else argv[0]);
    try full.appendSlice(arena, argv[1..]);
    const res = try std.process.run(arena, io, .{
        .argv = full.items,
        .cwd = if (r.cwd) |c| .{ .path = c } else .inherit,
        .environ_map = &env,
    });
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .stdout = res.stdout, .stderr = res.stderr };
}

/// Railpack's examples directory.
fn examples() ![]const u8 {
    var env = try hostEnv();
    if (env.get("H9X_EXAMPLES")) |d| return d;
    const dir = try std.fs.path.join(arena, &.{ work(), "railpack-" ++ railpack_tag });
    const ex = try std.fs.path.join(arena, &.{ dir, "examples" });
    if (Io.Dir.cwd().access(std.testing.io, ex, .{})) |_| return ex else |_| {}
    try (try run(&.{ "git", "clone", "-q", "--depth", "1", "--branch", railpack_tag, "https://github.com/railwayapp/railpack", dir }, .{})).ok();
    return ex;
}

/// A fresh copy of an example, in a directory of its own under the work
/// directory: `WORK/TAG/NAME`.
fn copy(name: []const u8, tag: []const u8) ![]const u8 {
    const parent = try std.fs.path.join(arena, &.{ work(), "cases", tag });
    const dst = try std.fs.path.join(arena, &.{ parent, name });
    try (try run(&.{ "rm", "-rf", parent }, .{})).ok();
    try Io.Dir.cwd().createDirPath(std.testing.io, parent);
    try (try run(&.{ "cp", "-R", try std.fs.path.join(arena, &.{ try examples(), name }), dst }, .{})).ok();
    return dst;
}

/// The JSON events h9x wrote to stderr with --json, each line checked.
fn events(stderr: []const u8) ![]const std.json.Value {
    var out: std.ArrayList(std.json.Value) = .empty;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, stderr, "\n"), '\n');
    while (lines.next()) |l| {
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, l, .{}) catch {
            std.debug.print("not a JSON event: {s}\n", .{l});
            return error.NotJson;
        };
        if (v != .object or v.object.get("event") == null) return error.NotAnEvent;
        try out.append(arena, v);
    }
    return out.items;
}

fn str(v: std.json.Value, key: []const u8) []const u8 {
    const f = v.object.get(key) orelse return "";
    return if (f == .string) f.string else "";
}

fn layerStates(evs: []const std.json.Value, layer: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (evs) |e| if (std.mem.eql(u8, str(e, "event"), "layer") and std.mem.eql(u8, str(e, "layer"), layer))
        try out.append(arena, str(e, "state"));
    return out.items;
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn sha256File(path: []const u8) ![64]u8 {
    const data = try Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .limited(4 << 30));
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

// ---------------------------------------------------------------- the examples

/// How an example shows it runs: its output, or a page it serves.
const Check = union(enum) {
    output: []const []const u8,
    http: struct { port: u16, path: []const u8 = "/", expect: []const []const u8, env: []const u8 = "" },
};

/// Railpack's examples the proof of concept builds, with what each one's
/// test.json expects.
const examples_table = [_]struct { []const u8, Check }{
    .{ "go-mod", .{ .output = &.{"Hello from Go"} } },
    .{ "node-npm", .{ .output = &.{"hello from Node"} } },
    .{ "node-bun", .{ .output = &.{"hello from Bun"} } },
    .{ "node-lts-npm-native-deps", .{ .output = &.{ "Database test successful!", "Bcrypt compare result: true" } } },
    .{ "python-uv", .{ .http = .{ .port = 8000, .expect = &.{"Hello from Python Flask!"} } } },
    .{ "deno-2", .{ .output = &.{"Hello from Deno"} } },
    .{ "ruby-latest", .{ .output = &.{"Ruby version: 4."} } },
    .{ "cpp-cmake", .{ .output = &.{"Hello from C++"} } },
    .{ "gleam", .{ .output = &.{"Hello from app_gleam!"} } },
    .{ "elixir-latest", .{ .output = &.{"hello from elixir"} } },
    .{ "rust-rocket", .{ .http = .{ .port = 8000, .expect = &.{"Hello, from Rocket!"} } } },
    .{ "zig", .{ .output = &.{"Hello from Zig"} } },
    .{ "dotnet-cli", .{ .output = &.{"Hello from dotnet 6.0.36"} } },
    .{ "dotnet-api", .{ .http = .{ .port = 8080, .path = "/WeatherForecast", .expect = &.{"temperatureC"}, .env = "PORT=8080 " } } },
};

/// Runs a built example and checks what it prints or serves.
fn check(out: []const u8, c: Check) !Result {
    switch (c) {
        .output => |want| {
            const r = try run(&.{ "h9x", "run", out, "--timeout", "5m" }, .{});
            for (want) |w| if (!r.has(w)) return failed(r, w);
            return r;
        },
        .http => |h| {
            // The server in the background, and wget until it answers.
            const script = try std.fmt.allocPrint(arena,
                \\{s}sh -c "$H9X_START" >/tmp/server.log 2>&1 &
                \\i=0
                \\while [ $i -lt 120 ]; do
                \\  if wget -qO- http://127.0.0.1:{d}{s}; then exit 0; fi
                \\  sleep 1; i=$((i+1))
                \\done
                \\cat /tmp/server.log >&2
                \\exit 1
            , .{ h.env, h.port, h.path });
            const r = try run(&.{ "h9x", "run", out, "--listen", try std.fmt.allocPrint(arena, "{d}", .{h.port}), "--timeout", "5m", "--", "sh", "-c", script }, .{});
            for (h.expect) |w| if (!r.has(w)) return failed(r, w);
            return r;
        },
    }
}

fn failed(r: Result, want: []const u8) error{Failed} {
    std.debug.print("wanted {s} in the output\nexit {d}\nstdout:\n{s}\nstderr (last 4 KiB):\n{s}\n", .{ want, r.code, r.stdout, r.stderr[r.stderr.len -| 4096..] });
    return error.Failed;
}

fn wanted(name: []const u8) !bool {
    var env = try hostEnv();
    const only = env.get("H9X_EXAMPLES_ONLY") orelse return true;
    var it = std.mem.splitScalar(u8, only, ',');
    while (it.next()) |n| if (std.mem.eql(u8, std.mem.trim(u8, n, " "), name)) return true;
    return false;
}

/// A built copy of an example, made once per run of the tests.
fn built(name: []const u8) ![]const u8 {
    const src = try std.fs.path.join(arena, &.{ work(), "cases", "built", name });
    const out = try std.fmt.allocPrint(arena, "{s}.h9", .{src});
    if (Io.Dir.cwd().access(std.testing.io, try std.fs.path.join(arena, &.{ out, "artifact.json" }), .{})) |_| return out else |_| {}
    _ = try copy(name, "built");
    try (try run(&.{ "h9x", "build", src, "-o", out }, .{})).ok();
    return out;
}

// ---------------------------------------------------------------- cases

test "every example the proof of concept builds also builds and runs [prototype]" {
    var failures: std.ArrayList([]const u8) = .empty;
    for (examples_table) |ex| {
        if (!try wanted(ex[0])) continue;
        std.debug.print("example {s}\n", .{ex[0]});
        const out = built(ex[0]) catch {
            try failures.append(arena, try std.fmt.allocPrint(arena, "{s}: build", .{ex[0]}));
            continue;
        };
        _ = check(out, ex[1]) catch {
            try failures.append(arena, try std.fmt.allocPrint(arena, "{s}: run", .{ex[0]}));
            continue;
        };
    }
    if (failures.items.len > 0) {
        for (failures.items) |f| std.debug.print("failed: {s}\n", .{f});
        return error.Failed;
    }
}

test "a rebuild with nothing changed takes under a second and rebuilds no layer [prototype]" {
    for ([_][]const u8{ "node-npm", "python-uv" }) |name| {
        const out = try built(name);
        const src = out[0 .. out.len - 3];
        const r = try run(&.{ "h9x", "build", src, "-o", out, "--json" }, .{});
        try r.ok();
        const evs = try events(r.stderr);
        for ([_][]const u8{ "runtime", "deps", "app" }) |l| try std.testing.expect(!contains(try layerStates(evs, l), "building"));
        const last = evs[evs.len - 1];
        try std.testing.expectEqualStrings("result", str(last, "event"));
        const ms = last.object.get("ms").?.integer;
        std.debug.print("{s}: a rebuild with nothing changed took {d} ms\n", .{ name, ms });
        try std.testing.expect(ms < 1000);
    }
}

test "a second app on the same runtimes shares the runtime layer [prototype]" {
    _ = try built("node-npm");
    // Another app with the same runtime steps: the example under another
    // name, with a change to its code.
    const src = try copy("node-npm", "second-app");
    const renamed = try std.fs.path.join(arena, &.{ std.fs.path.dirname(src).?, "another-node-app" });
    try (try run(&.{ "mv", src, renamed }, .{})).ok();
    const idx = try std.fs.path.join(arena, &.{ renamed, "index.js" });
    try (try run(&.{ "sh", "-c", "echo '// another app' >> \"$0\"", idx }, .{})).ok();
    const r = try run(&.{ "h9x", "build", renamed, "--json" }, .{ .cwd = std.fs.path.dirname(renamed).? });
    try r.ok();
    const states = try layerStates(try events(r.stderr), "runtime");
    try std.testing.expect(contains(states, "shared"));
    try std.testing.expect(!contains(states, "building"));
}

test "h9x run on a git source prints the example's output, and a second run plans nothing [prototype]" {
    const spec = "github.com/railwayapp/railpack@" ++ railpack_tag ++ "//examples/node-npm";
    const first = try run(&.{ "h9x", "run", spec, "--timeout", "5m" }, .{});
    if (!first.has("hello from Node")) return failed(first, "hello from Node");
    const second = try run(&.{ "h9x", "run", spec, "--timeout", "5m", "--json" }, .{});
    if (!second.has("hello from Node")) return failed(second, "hello from Node");
    for (try events(second.stderr)) |e| if (std.mem.eql(u8, str(e, "event"), "phase") and std.mem.eql(u8, str(e, "phase"), "plan")) {
        try std.testing.expectEqualStrings("cached", str(e, "state"));
    };
}

test "a tarball source builds [prototype]" {
    const spec = "https://github.com/railwayapp/railpack/archive/refs/tags/" ++ railpack_tag ++ ".tar.gz//examples/go-mod";
    try (try run(&.{ "h9x", "build", spec }, .{ .cwd = work() })).ok();
    const ran = try run(&.{ "h9x", "run", spec, "--timeout", "5m" }, .{});
    if (!ran.has("Hello from Go")) return failed(ran, "Hello from Go");
}

test "h9x shell -- node -v runs in the build stage, and the source is writable [prototype]" {
    _ = try built("node-npm");
    const src = try std.fs.path.join(arena, &.{ work(), "cases", "built", "node-npm" });
    const marker = try std.fs.path.join(arena, &.{ src, "written-by-shell" });
    Io.Dir.cwd().deleteFile(std.testing.io, marker) catch {};
    const r = try run(&.{ "h9x", "shell", src, "--", "sh", "-c", "node -v && echo yes > /app/written-by-shell && test -d /app/node_modules" }, .{ .cwd = std.fs.path.dirname(src).? });
    try r.ok();
    try std.testing.expect(std.mem.startsWith(u8, r.stdout, "v"));
    const text = try Io.Dir.cwd().readFileAlloc(std.testing.io, marker, arena, .limited(64));
    try std.testing.expectEqualStrings("yes\n", text);
    try Io.Dir.cwd().deleteFile(std.testing.io, marker);
}

test "--print shows each phase's policy, and a widening flag or variable is exit 2 [prototype]" {
    const src = try copy("go-mod", "print");
    const r = try run(&.{ "h9x", "run", src, "--print" }, .{});
    try r.ok();
    for ([_][]const u8{ "# plan, trusted", "# build, trusted", "# run, trusted", "net outbound", "write overlay" }) |w|
        if (!r.has(w)) return failed(r, w);
    // Nothing was built or started.
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(std.testing.io, try std.fmt.allocPrint(arena, "{s}.h9", .{src}), .{}));

    // A remote source runs untrusted, with a 10m timeout a flag can't raise.
    const remote = try run(&.{ "h9x", "run", "gh:railwayapp/railpack@" ++ railpack_tag ++ "//examples/go-mod", "--print" }, .{});
    try remote.ok();
    for ([_][]const u8{ "# fetch, untrusted", "# run, untrusted", "net disable", "timeout 10m" }) |w|
        if (!remote.has(w)) return failed(remote, w);
    const wide = try run(&.{ "h9x", "run", "gh:railwayapp/railpack@" ++ railpack_tag ++ "//examples/go-mod", "--print", "--timeout", "1h" }, .{});
    try std.testing.expectEqual(@as(u8, 2), wide.code);
    try std.testing.expectEqualStrings("", wide.stdout);
    // A variable only narrows: more memory than the build's 4G widens it.
    const env_wide = try run(&.{ "h9x", "build", src, "--print" }, .{ .env = &.{.{ "H9X_MEMORY", "64G" }} });
    try std.testing.expectEqual(@as(u8, 2), env_wide.code);
    // A source's h9x.toml may set the run's policy; a widening line in an
    // untrusted source's is covered by config.zig's unit tests, since it
    // needs a remote source with its own h9x.toml.
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fs.path.join(arena, &.{ src, "h9x.toml" }), .data = "[run]\npolicy = \"net disable\"\n" });
    const narrowed = try run(&.{ "h9x", "run", src, "--print" }, .{});
    try narrowed.ok();
    if (!narrowed.has("net disable")) return failed(narrowed, "net disable");
}

test "a secret reaches the build step and no file h9x writes [prototype]" {
    const src = try copy("shell-script", "secret");
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fs.path.join(arena, &.{ src, "railpack.json" }), .data =
        \\{"steps": {"build": {"commands": ["test -z \"$H9X_TEST_SECRET\" || echo seen > secret-seen"]}}}
    });
    const value = "s3cr3t-h9x-value-4f1d";
    const out = try std.fmt.allocPrint(arena, "{s}.h9", .{src});
    const r = try run(&.{ "h9x", "build", src, "-o", out, "--secret", "H9X_TEST_SECRET" }, .{ .env = &.{.{ "H9X_TEST_SECRET", value }} });
    try r.ok();
    // The step saw it.
    const seen = try run(&.{ "h9x", "run", out, "--", "cat", "/app/secret-seen" }, .{});
    try seen.ok();
    try std.testing.expectEqualStrings("seen\n", seen.stdout);
    // No file in the output has it, and neither does --print.
    const grep = try run(&.{ "grep", "-rl", value, out }, .{});
    try std.testing.expectEqual(@as(u8, 1), grep.code);
    const printed = try run(&.{ "h9x", "build", src, "-o", out, "--secret", "H9X_TEST_SECRET", "--print" }, .{ .env = &.{.{ "H9X_TEST_SECRET", value }} });
    try printed.ok();
    try std.testing.expect(std.mem.indexOf(u8, printed.stdout, value) == null);
    if (!printed.has("env H9X_TEST_SECRET=")) return failed(printed, "env H9X_TEST_SECRET=");
}

test "--json emits one event per line, ending in result [prototype]" {
    const out = try built("go-mod");
    const r = try run(&.{ "h9x", "build", out[0 .. out.len - 3], "-o", out, "--json" }, .{});
    try r.ok();
    const evs = try events(r.stderr);
    try std.testing.expect(evs.len > 1);
    const last = evs[evs.len - 1];
    try std.testing.expectEqualStrings("result", str(last, "event"));
    try std.testing.expectEqualStrings("build", str(last, "command"));
    try std.testing.expectEqual(@as(i64, 0), last.object.get("status").?.integer);
    // A usage error is events too.
    const bad = try run(&.{ "h9x", "build", "--json", "--trust" }, .{});
    try std.testing.expectEqual(@as(u8, 2), bad.code);
    const bevs = try events(bad.stderr);
    try std.testing.expectEqualStrings("result", str(bevs[bevs.len - 1], "event"));
}

test "pack writes the same tar twice, and h9 --archive runs it [prototype]" {
    const out = try built("go-mod");
    const dir = std.fs.path.dirname(out).?;
    const a = try std.fs.path.join(arena, &.{ dir, "go-mod-a.tar" });
    const b = try std.fs.path.join(arena, &.{ dir, "go-mod-b.tar" });
    try (try run(&.{ "h9x", "pack", out, "-o", a }, .{})).ok();
    try (try run(&.{ "h9x", "pack", out, "-o", b }, .{})).ok();
    try std.testing.expectEqualStrings(&(try sha256File(a)), &(try sha256File(b)));
    var env = try hostEnv();
    const backend = env.get("H9X_BACKEND") orelse "auto";
    const r = try run(&.{ opts.h9, "--backend", backend, "--archive", try std.fmt.allocPrint(arena, "{s}:#L", .{a}), "sh", "/.h9x/run" }, .{});
    if (!r.has("Hello from Go")) return failed(r, "Hello from Go");
}

test "pack --exe runs the app on linux-amd64 with nothing else installed [prototype]" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var env = try hostEnv();
    for ([_]struct { []const u8, []const u8 }{ .{ "go-mod", "Hello from Go" }, .{ "node-npm", "hello from Node" } }) |ex| {
        const out = try built(ex[0]);
        const dir = std.fs.path.dirname(out).?;
        const app = try std.fs.path.join(arena, &.{ dir, try std.fmt.allocPrint(arena, "{s}-app", .{ex[0]}) });
        try (try run(&.{ "h9x", "pack", out, "--exe", "-o", app }, .{})).ok();
        // A clean home, and only the variables a machine needs from the
        // host to reach the network here.
        const home = try std.fs.path.join(arena, &.{ dir, try std.fmt.allocPrint(arena, "home-{s}", .{ex[0]}) });
        try (try run(&.{ "rm", "-rf", home }, .{})).ok();
        try Io.Dir.cwd().createDirPath(std.testing.io, home);
        var vars: std.ArrayList([2][]const u8) = .empty;
        try vars.append(arena, .{ "HOME", home });
        for ([_][]const u8{ "H9X_BACKEND", "HTTPS_PROXY", "SSL_CERT_FILE" }) |n| if (env.get(n)) |v| try vars.append(arena, .{ n, v });
        const r = try run(&.{app}, .{ .clean = true, .env = vars.items, .cwd = home });
        if (!r.has(ex[1])) return failed(r, ex[1]);
    }
}

test "pack --target writes each OS's container and the trailer, which --inspect reads [prototype]" {
    // The layers are the host's architecture, so the targets are this
    // architecture's: Linux and Windows on amd64, Linux and macOS on arm64.
    // The other OS's runner is a stand-in, given by --runner, as there's
    // no release yet; its container is what's checked.
    const out = try built("go-mod");
    const dist = try std.fs.path.join(arena, &.{ std.fs.path.dirname(out).?, "dist" });
    try (try run(&.{ "rm", "-rf", dist }, .{})).ok();
    const other, const runner, const container = switch (builtin.cpu.arch) {
        .x86_64 => .{ "windows-amd64", opts.runner_pe, "pe" },
        .aarch64 => .{ "macos-arm64", opts.runner_macho, "macho" },
        else => return error.SkipZigTest,
    };
    const host = if (builtin.cpu.arch == .x86_64) "linux-amd64" else "linux-arm64";
    const r = try run(&.{ "h9x", "pack", out, "--target", try std.fmt.allocPrint(arena, "{s},{s}", .{ host, other }), "--runner", try std.fmt.allocPrint(arena, "{s}={s}", .{ other, runner }), "-o", dist }, .{});
    try r.ok();
    const sums = try Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(arena, &.{ dist, "SHA256SUMS" }), arena, .limited(4096));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, sums, "\n"));
    for ([_]struct { []const u8, []const u8 }{ .{ host, "elf" }, .{ other, container } }) |t| {
        const ext = if (std.mem.startsWith(u8, t[0], "windows")) ".exe" else "";
        const f = try std.fs.path.join(arena, &.{ dist, try std.fmt.allocPrint(arena, "go-mod-{s}{s}", .{ t[0], ext }) });
        const ins = try run(&.{ "h9x", "pack", "--inspect", f, "--json" }, .{});
        try ins.ok();
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, ins.stdout, .{});
        try std.testing.expectEqualStrings(t[1], str(v, "container"));
    }
}

test "export --oci writes the same digest twice, and its layers match the run's [prototype]" {
    const out = try built("node-npm");
    const dir = std.fs.path.dirname(out).?;
    const a = try std.fs.path.join(arena, &.{ dir, "node-a.oci.tar" });
    const b = try std.fs.path.join(arena, &.{ dir, "node-b.oci.tar" });
    try (try run(&.{ "h9x", "export", out, "--oci", a }, .{})).ok();
    try (try run(&.{ "h9x", "export", out, "--oci", b }, .{})).ok();
    try std.testing.expectEqualStrings(&(try sha256File(a)), &(try sha256File(b)));
    // The manifest's layers: the base root, then each layer the run stacks.
    const art = try std.json.parseFromSliceLeaky(std.json.Value, arena, try Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(arena, &.{ out, "artifact.json" }), arena, .limited(1 << 20)), .{});
    const want = art.object.get("layers").?.array.items.len + 1;
    const x = try std.fs.path.join(arena, &.{ dir, "node-oci" });
    try (try run(&.{ "rm", "-rf", x }, .{})).ok();
    try Io.Dir.cwd().createDirPath(std.testing.io, x);
    try (try run(&.{ "tar", "-xf", a, "-C", x }, .{})).ok();
    const index = try std.json.parseFromSliceLeaky(std.json.Value, arena, try Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(arena, &.{ x, "index.json" }), arena, .limited(1 << 20)), .{});
    const mdigest = str(index.object.get("manifests").?.array.items[0], "digest");
    const manifest = try std.json.parseFromSliceLeaky(std.json.Value, arena, try Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(arena, &.{ x, "blobs", "sha256", mdigest["sha256:".len..] }), arena, .limited(1 << 20)), .{});
    try std.testing.expectEqual(want, manifest.object.get("layers").?.array.items.len);
}

test "h9x -o OUT DIR still works, with a warning [prototype]" {
    _ = try built("go-mod");
    const src = try std.fs.path.join(arena, &.{ work(), "cases", "built", "go-mod" });
    const out = try std.fmt.allocPrint(arena, "{s}.h9", .{src});
    const r = try run(&.{ "h9x", "-o", out, src }, .{});
    try r.ok();
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "deprecated") != null);
    try Io.Dir.cwd().access(std.testing.io, try std.fs.path.join(arena, &.{ out, "artifact.json" }), .{});
}

test "the library plans, builds, and runs an example" {
    _ = try built("go-mod");
    const r = try run(&.{ opts.lib_example, try std.fs.path.join(arena, &.{ work(), "cases", "built", "go-mod" }) }, .{});
    if (!r.has("Hello from Go")) return failed(r, "Hello from Go");
}
