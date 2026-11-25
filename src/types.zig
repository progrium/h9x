//! The types the modules share (design/prototype.md). The skeleton writes
//! this file and nothing else does: a module that needs a field added asks
//! for it in its pull request, so parallel work never edits the same
//! interface twice.
//!
//! Slices in these types are borrowed. Whoever builds a value owns its
//! memory, usually an arena that lives as long as the command.

const std = @import("std");
const builtin = @import("builtin");

/// A guest architecture. Every key includes it (design/prototype.md,
/// "Architecture"). The prototype builds for the host's only.
pub const Arch = enum {
    amd64,
    arm64,

    /// The host's, or null on a host h9x doesn't build for.
    pub fn host() ?Arch {
        return switch (builtin.cpu.arch) {
            .x86_64 => .amd64,
            .aarch64 => .arm64,
            else => null,
        };
    }

    /// The name Alpine, Wolfi, and the guest scripts use.
    pub fn linuxName(a: Arch) []const u8 {
        return switch (a) {
            .amd64 => "x86_64",
            .arm64 => "aarch64",
        };
    }

    /// The name Railpack's release archives use.
    pub fn railpackName(a: Arch) []const u8 {
        return switch (a) {
            .amd64 => "x86_64",
            .arm64 => "arm64",
        };
    }
};

/// h9x's exit codes (design/prototype.md, "Exit codes"). `run` and `shell`
/// also exit with the program's own status, as h9 maps it, which isn't one
/// of these.
pub const Exit = enum(u8) {
    /// Success, or the run's program exited with an empty status.
    ok = 0,
    /// A build step failed, or Railpack made no steps.
    failed = 1,
    /// A usage, config, or policy error, such as a widening flag.
    usage = 2,
    /// A timeout, as h9's.
    timeout = 124,
    /// Setup failed: a download, a root, or a machine h9 couldn't start.
    setup = 125,
    _,

    pub fn code(e: Exit) u8 {
        return @intFromEnum(e);
    }
};

// ---------------------------------------------------------------- sources

/// What an app is built from (design/prototype.md, "Sources"). source.zig
/// makes these.
pub const Source = struct {
    pub const Kind = enum { dir, git, tarball };

    kind: Kind,
    /// The SOURCE argument as given.
    spec: []const u8,
    /// The tree on the host: absolute, symlinks resolved, and for a git
    /// source with `//SUBDIR`, the subdirectory.
    path: []const u8,
    /// The app's name: the directory's basename, or the repository's or
    /// tarball's name. Railpack sees the source at /h9x/src/NAME.
    name: []const u8,
    /// The content hash, in hex: the commit, the tarball's sha256, or the
    /// directory's hash of its files.
    hash: []const u8,

    /// Git and tarball sources are remote: they run under the untrusted
    /// profile unless `--trust` is given, and are read-only to every phase
    /// but `shell`.
    pub fn remote(s: Source) bool {
        return s.kind != .dir;
    }
};

// ---------------------------------------------------------------- plans

/// The layers an app is built into, in stacking order.
pub const LayerName = enum {
    runtime,
    deps,
    app,

    pub const all = [_]LayerName{ .runtime, .deps, .app };
};

/// One of Railpack's steps, and the layer it builds in (plan.sh's
/// steps.txt).
pub const Step = struct {
    /// The step's index in plan.json's `steps`.
    index: u32,
    name: []const u8,
    layer: LayerName,
};

/// A path the run takes from a layer, with its excludes, all absolute
/// (plan.sh's deploy.txt).
pub const Deploy = struct {
    layer: LayerName,
    path: []const u8,
    exclude: []const []const u8 = &.{},
};

/// A tool and the version Railpack resolved for it.
pub const Version = struct {
    name: []const u8,
    version: []const u8,
};

/// Railpack's plan, as h9x reads it (design/prototype.md, "The build
/// engine"). plan.zig makes it from plan.json with plan.sh's rules.
pub const Plan = struct {
    /// The provider Railpack detected (`node`, `python`, ...).
    provider: []const u8,
    /// The versions Railpack resolved, for `h9x plan`.
    versions: []const Version = &.{},
    /// The steps, apt steps left out, in plan order.
    steps: []const Step,
    /// Each layer's key: a hash of its steps and the files they read, and
    /// for the app layer, the deploy (plan.sh's keys.txt). layers.zig
    /// chains them.
    keys: std.enums.EnumFieldStruct(LayerName, []const u8, null),
    /// The key the runtime layer is shared under across apps (plan.sh's
    /// shared.txt).
    shared_key: []const u8,
    /// Whether the runtime steps copy files from the source, which the deps
    /// layer then makes.
    runtime_copies: bool,
    /// What the run takes from each layer.
    deploy: []const Deploy = &.{},
    /// The Debian packages the plan installs to build, and to run.
    apt_build: []const []const u8 = &.{},
    apt_runtime: []const []const u8 = &.{},
    /// The start command, if the plan has one.
    start: ?[]const u8 = null,
    /// The plan's key: the source's hash, Railpack's version, and h9x's.
    key: []const u8,
    /// plan.json as kept, for `h9x plan --json` and the guest scripts.
    json: []const u8,
};

// ---------------------------------------------------------------- layers

/// A built layer, as `artifact.json` lists it.
pub const Layer = struct {
    name: LayerName,
    /// The chained key it was built under.
    key: []const u8,
    /// Its directory: `$cache/runtimes/KEY` for a shared runtime layer, or
    /// `layers/NAME` relative to the output directory.
    path: []const u8,
};

/// A root tree in the cache (design/prototype.md, "Roots").
pub const Root = struct {
    pub const Kind = enum { bootstrap, base, builder };

    kind: Kind,
    /// Its directory, absolute.
    path: []const u8,
    /// The Wolfi packages it was made from; empty for the bootstrap.
    packages: []const []const u8 = &.{},
};

// ---------------------------------------------------------------- artifacts

/// The output directory's `artifact.json`: everything a consumer needs to
/// run a build without reading the rest (design/prototype.md, "The output
/// directory"). Field names are the JSON's.
pub const Artifact = struct {
    pub const current_version = 1;

    pub const Base = struct {
        path: []const u8,
        packages: []const []const u8,
    };

    version: u32 = current_version,
    arch: Arch,
    base: Base,
    /// The layers the run stacks, bottom first (`layers.txt`).
    layers: []const Layer,
    /// `NAME=VALUE` lines.
    env: []const []const u8,
    start: ?[]const u8,
    cwd: []const u8 = "/app",
};

// ---------------------------------------------------------------- policy

/// Which machine a policy is for (design/prototype.md, "Policy").
pub const Phase = enum {
    /// Fetching a git or tarball source: network to its host only.
    fetch,
    /// Making a root with apk in the bootstrap root.
    root,
    plan,
    build,
    run,
    shell,
};

/// How far a policy is trusted. A remote source is untrusted unless
/// `--trust` is given; a directory is trusted.
pub const Trust = enum { trusted, untrusted };

/// h9's network modes, as the `net` line names them.
pub const Net = enum {
    disable,
    outbound,
    enable,

    /// Whether `a` gives the guest no more than `b` does.
    pub fn narrows(a: Net, b: Net) bool {
        return @intFromEnum(a) <= @intFromEnum(b);
    }
};

/// A namespace line h9x writes: `dir ACCESS SRC DST` or `tmp DST`.
pub const Mount = struct {
    pub const Kind = enum { dir, tmp };
    /// h9's access modes that h9x uses.
    pub const Access = enum { ro, rw, up };

    kind: Kind,
    /// A host path, absolute and resolved; empty for `tmp`.
    src: []const u8 = "",
    /// A guest path: `#L` for the Linux root, or a path under it.
    dst: []const u8,
    access: Access = .ro,
};

/// A guest environment variable.
pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
    /// A secret: passed to the guest, but printed as `env NAME=…` and never
    /// written to a file h9x makes.
    secret: bool = false,
};

/// A machine's policy, as the h9 plan lines h9x uses: `dir`, `tmp`, `net`,
/// `netallow`, `write`, `memory`, `pids`, `timeout`, `env`, `cwd`, and
/// `run` (h9's plan-format proposal). policy.zig parses and prints the
/// text, narrows one policy by another, and compiles one into
/// `h9.Machine.Options`.
pub const Policy = struct {
    pub const Write = enum { ro, overlay, rw };

    phase: Phase,
    trust: Trust = .trusted,
    /// `dir` and `tmp` lines, in order.
    mounts: []const Mount = &.{},
    net: Net = .disable,
    /// `netallow` patterns; empty allows any host the `net` mode does.
    netallow: []const []const u8 = &.{},
    write: ?Write = null,
    /// Bytes; null is h9's default.
    memory: ?u64 = null,
    pids: ?u32 = null,
    timeout_ns: ?u64 = null,
    env: []const EnvVar = &.{},
    /// The guest's working directory.
    cwd: ?[]const u8 = null,
    /// The program and its arguments; empty when the caller gives them.
    run: []const []const u8 = &.{},
};

// ---------------------------------------------------------------- events

/// What a command reports, as an `h9x:` line on stderr, or one NDJSON
/// object with `--json` (design/prototype.md, "Events"). events.zig writes
/// them; field names are the JSON's.
pub const Event = union(enum) {
    pub const State = enum { start, done, cached, shared, building, exit, failed };
    pub const Stream = enum { stdout, stderr };

    phase: struct { phase: Phase, state: State },
    fetch: struct { url: []const u8, state: State, bytes: ?u64 = null },
    root: struct { root: Root.Kind, key: []const u8, state: State },
    layer: struct { layer: LayerName, state: State, key: []const u8 },
    step: struct {
        layer: LayerName,
        step: []const u8,
        state: State,
        status: ?u8 = null,
        ms: ?u64 = null,
    },
    output: struct {
        layer: ?LayerName = null,
        step: ?[]const u8 = null,
        stream: Stream,
        text: []const u8,
    },
    /// A machine's policy as plan text, for `--print` and `--json`.
    policy: struct { phase: Phase, text: []const u8 },
    /// Always the last event, with the exit code.
    result: struct {
        command: []const u8,
        status: u8,
        out: ?[]const u8 = null,
        ms: u64,
    },
    /// A warning or note for the person, such as the POC form's
    /// deprecation warning.
    log: struct { text: []const u8 },
};

// ---------------------------------------------------------------- packs

/// The release targets a pack can be joined to a runner for
/// (design/prototype.md, "Packs").
pub const Target = enum {
    @"linux-amd64",
    @"linux-arm64",
    @"macos-arm64",
    @"windows-amd64",

    pub fn arch(t: Target) Arch {
        return switch (t) {
            .@"linux-amd64", .@"windows-amd64" => .amd64,
            .@"linux-arm64", .@"macos-arm64" => .arm64,
        };
    }

    pub const Container = enum { elf, macho, pe };

    /// How the archive is joined to the runner's image.
    pub fn container(t: Target) Container {
        return switch (t) {
            .@"linux-amd64", .@"linux-arm64" => .elf,
            .@"macos-arm64" => .macho,
            .@"windows-amd64" => .pe,
        };
    }
};

/// The 32 bytes at the end of every packed executable, whatever its
/// container, so `pack --inspect` and the runner find the archive the same
/// way. Little-endian. exe/trailer.zig reads and writes it.
pub const Trailer = extern struct {
    pub const magic_bytes = "H9XPACK\x00".*;
    pub const current_version = 1;
    pub const size = 32;

    magic: [8]u8 = magic_bytes,
    /// The archive's offset from the start of the file.
    offset: u64,
    /// The archive's length in bytes.
    length: u64,
    version: u32 = current_version,
    reserved: u32 = 0,

    comptime {
        std.debug.assert(@sizeOf(Trailer) == size);
    }
};

test Trailer {
    const t: Trailer = .{ .offset = 4096, .length = 100 };
    try std.testing.expectEqualSlices(u8, "H9XPACK\x00", &t.magic);
}

test "Net.narrows" {
    try std.testing.expect(Net.disable.narrows(.outbound));
    try std.testing.expect(!Net.enable.narrows(.outbound));
}

test "Target.arch" {
    try std.testing.expectEqual(Arch.arm64, Target.@"macos-arm64".arch());
}
