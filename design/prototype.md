---
slug: prototype
title: The h9x prototype
status: draft
created: 2026-11-25
authors: [progrium]
depends: []
areas: [cli, build, sandbox, pack, export, cache, tests]
branch: []
---

# Proposal: The h9x prototype

## Abstract

h9x is one command that safely runs any repo: `h9x run github.com/foo/bar` detects the language, builds the app in sandboxed, cached layers, and runs it on [h9](https://github.com/progrium/hyper9), with no Docker, daemon, or root. Dev shells and agent sandboxes come from the same layers, and the layers can be written out as single-file packs, executables for each platform, or OCI images. This proposal is the first spec for h9x, scoped to a prototype that can be built in parallel and used. The prototype is a Zig program that links h9's library, with the commands `run`, `build`, `shell`, `plan`, `pack`, `export`, and `cache`, git and tarball sources, `h9x.toml`, `--json` events, policy written as h9 plan lines, packs with an index, executables for h9's release targets, and OCI image tarballs. Railpack, mise, apk, and the package managers run as guests, and the build engine keeps the proof of concept's behaviour: the same layers, keys, sharing, and pruning.

## Background

### Why

The use cases, ranked by how many people have the problem, how well h9x beats the alternatives, and how close the proof of concept is. The top three share one engine (plan, build layers, and run them in an h9 sandbox), so they ship together as the launch story.

| Rank | Use case | Who | Why h9x wins |
| --- | --- | --- | --- |
| 1 | Run any repo: `h9x run github.com/foo/bar` | Developers trying a project, people following a README | No Docker, daemon, root, or toolchain install. A second app on the same runtimes skips installing them. |
| 2 | Dev shells: `h9x shell` | Contributors, onboarding | The project's exact toolchain from the same cached layers as the build: a devcontainer without Docker Desktop. |
| 3 | Agent and untrusted-code sandbox | AI coding agents, CI on fork PRs, code review | A per-phase policy (no host files, registry-only network, limits, and timeouts) that's printable and diffable, and machine-readable events. |
| 4 | OCI export: `h9x export` | CI, teams on Kubernetes or a PaaS | A daemonless buildpacks alternative whose images were 37 to 69% smaller than Railpack's on Docker ([benchmarks](../docs/benchmarks.md)). |
| 5 | Packs and executables: `h9x pack` | Shipping CLIs, tools, and demos to people without h9, and the browser host | One tar runs anywhere h9 runs, browser included. With `--exe`, one executable per platform runs with nothing installed, and one machine can make every platform's. |
| 6 | Shared build cache | Teams, CI fleets | Input-keyed layers can move between machines with no BuildKit. |
| 7 | Reproducibility checks: `h9x verify` | Release engineers | A pinned plan and content-keyed layers can be rebuilt and diffed. |
| 8 | Embedding as a library | A PaaS, an editor's "run this project" button, uitree's app builder | Plan, build, and run as calls, not shell-outs. |

The prototype covers 1 to 5 and the Zig library behind 8. Shared caches, `verify`, and the C ABI are later proposals.

### The proof of concept

The proof of concept is [h9x](../h9x), a POSIX shell script of about 430 lines, and three guest scripts in [guest/](../guest). `h9x [-o OUT] APPDIR` builds a local directory into `OUT/`, and `OUT/run` runs it. It works:

- **Roots.** Alpine's minirootfs and Railpack's static binary are downloaded once. In a machine on the Alpine root, `guest/roots.sh` runs `apk --root` to install Wolfi packages into two roots in the cache, keyed by package set: *base*, which apps run on (glibc, `libstdc++`, OpenSSL, zlib, certificates, `tzdata`, busybox, and bash, about 40 MB), and *builder*, which adds what Railpack's builder image has (gcc, make, cmake, the autotools, git, jq, and the usual headers).
- **Plan.** In a machine on the builder root, `railpack plan` writes `plan.json`, and `guest/plan.sh` uses `jq` to turn it into plain text files the host script reads with `awk`: which layer each step builds in, each layer's key, the shared runtime key, the deploy paths, and the apt packages. The plan is kept with a key of every source file, Railpack, and `plan.sh`, since planning is most of a build with nothing changed.
- **Packages.** The plan's apt steps name Debian packages, which h9x maps to Wolfi's names with a table for the common ones and guesses for the rest, adding the build ones to the builder root and the runtime ones to the base root.
- **Layers.** Runtime (the `packages:` steps, mise's), deps (`install`), and app (the rest), each built by `guest/build.sh` in its own machine on the builder root, with the layers below stacked over it and the new layer's directory as the h9 up layer on top ([upper-layers](https://github.com/progrium/hyper9/blob/main/design/upper-layers.md)), so whatever its steps change lands there as an OCI layer with `.wh.` whiteouts.
- **Caching.** A layer's key hashes its steps and the source files they copy in, chained with the keys below it, so changing the app's code rebuilds only the app layer. The runtime layer is shared between apps in `$cache/runtimes`, under a key of the builder root and the plan's runtime steps, so a runtime is installed once per machine. A build with nothing changed takes about half a second, and a second app on runtimes another app installed built Ruby in 7 s rather than 70 s.
- **Pruning.** The app layer keeps only what the plan deploys, with whiteouts for excludes a lower layer holds (Rust's `target`). The run stacks the runtime layer only when the plan deploys from it (a Go binary doesn't need its toolchain), and the deps layer only when it holds a deployed path. A small deps deploy (Rust's `Cargo.lock`) is copied into the app layer instead.

On x86\_64 Linux, with h9's native backend, it builds and runs Railpack's examples `go-mod`, `node-npm`, `node-bun`, `node-lts-npm-native-deps`, `python-uv`, `deno-2`, `ruby-latest`, `cpp-cmake`, `gleam`, `elixir-latest`, `rust-rocket`, `zig`, `dotnet-cli`, and `dotnet-api`. It doesn't build older Ruby (mise's precompiled Ruby covers recent versions only, and building 3.1.2 from source hung in h9), PHP (Railpack's PHP plans build on FrankenPHP's image), or Java (untried). arm64 and macOS are untried.

What it lacks is the surface around the engine: one command, a local directory only, config in environment variables, policy as whatever flags the script passes (builds run with `--net enable`), and an output that depends on roots and runtime layers in the user's cache, so there's nothing to hand someone.

### What h9 provides

h9 is a Zig library with a `Machine` API ([docs/embedding.md](https://github.com/progrium/hyper9/blob/main/docs/embedding.md)): `Machine.init` with `.dir` mounts and up layers, `.tmp` and `.archive` mounts, `net`, `net_allow`, memory, pids, and timeout limits, `compilePlan` and `print` for `--print`, and `run` with a status. [plan-format](https://github.com/progrium/hyper9/blob/main/design/plan-format.md), a draft in h9, makes the plan a text format that `Machine.init` takes as `.plan`.

h9x needs an h9 with up layers, including [progrium/hyper9#254](https://github.com/progrium/hyper9/pull/254) (a working directory below a layer sees what's changed in it since), and the Linux fixes the examples turned up: [#257](https://github.com/progrium/hyper9/pull/257) (`lseek(SEEK_END)` on long names and `mremap` over joined mappings, for rustup and `zig build`), [#258](https://github.com/progrium/hyper9/pull/258) (`sched_getparam`, for MSBuild), [#263](https://github.com/progrium/hyper9/pull/263) (edge-triggered epoll on a host socket, for NuGet through a proxy), and [#264](https://github.com/progrium/hyper9/pull/264) (a signal breaks a pipe read waiting behind another, and `getsockname` before `listen`, for cargo's jobserver and Kestrel). uv's bytecode compile now and then panics or hangs in h9 ([#276](https://github.com/progrium/hyper9/issues/276), half fixed by [#280](https://github.com/progrium/hyper9/pull/280), the rest in [#283](https://github.com/progrium/hyper9/pull/283)). Builds should run on a hypervisor or the native backend, never the emulator.

## Proposal

### One program, two binaries

h9x is a Zig project with h9 as a dependency in `build.zig.zon`, pinned to a hyper9 commit. `zig build` makes two executables from one module tree:

- **`h9x`**, the CLI: the commands below, with the guest scripts, the base and builder package lists, and the host target's runner embedded.
- **`h9x-runner`**, the runner for packed executables: h9's `Machine`, the pack reader, and the container lookup, with none of the builder.

The modules, under `src/`, and what each owns:

| Module | Owns |
| --- | --- |
| `root.zig` | The library's public surface (below) |
| `main.zig`, `cli.zig` | Argument parsing, the subcommands, `--help`, and exit codes |
| `source.zig` | Directory, git, and tarball sources, their fetch, and their content hash |
| `config.zig`, `toml.zig` | `h9x.toml`, the `H9X_*` variables, and precedence |
| `policy.zig` | Policy as plan lines, the per-phase defaults, narrowing, the registry allowlist, and compiling lines to `Machine.Options` |
| `machine.zig` | One helper that starts an h9 machine from a policy and mounts, with h9x's stdio, proxy, and CA handling |
| `roots.zig`, `wolfi.zig` | The bootstrap, the base and builder roots, and the Debian-to-Wolfi table |
| `plan.zig` | Running Railpack, reading `plan.json`, the layer split, keys, deploy paths, and apt lists |
| `layers.zig` | Building the layers, the shared runtime layer, pruning, and `layers.txt` |
| `artifact.zig` | The output directory and its `artifact.json` |
| `events.zig` | Events, as text on stderr or NDJSON with `--json` |
| `tar.zig`, `index.zig` | Deterministic tar writing, whiteout flattening, and the pack index |
| `pack.zig` | Packs: the flattened tar, `/.h9x/pack.json`, and `/.h9x/run` |
| `exe/` (`trailer.zig`, `elf.zig`, `macho.zig`, `pe.zig`, `adhoc.zig`) | Joining a runner and an archive per OS, the trailer, and macOS ad-hoc signing |
| `oci.zig` | OCI image layouts and `docker save` tarballs |
| `cache.zig` | The cache's layout, `cache ls`, and `cache prune` |
| `runner/main.zig` | The runner's `main` |

`guest/build.sh` and `guest/roots.sh` stay guest scripts, embedded in `h9x` and mounted into build machines from memory. `guest/plan.sh` goes away: the host reads `plan.json` with `std.json`, so the builder root no longer needs `jq` for h9x's own use. The shell script moves to `poc/h9x` as the reference for the engine's behaviour, and is removed once the prototype builds every example it does.

### The library

`root.zig` exports four steps, each returning a value the next one takes:

```zig
const h9x = @import("h9x");

var builder = try h9x.Builder.init(gpa, io, .{
    .cache_dir = cache,                 // roots, runtimes, sources, and layers
    .machine = .{ .backend = .auto },   // passed through to h9's Machine.Options
    .on_event = report,                 // step start, output, exit, and cache hit
});
defer builder.deinit();

const src  = try builder.source(.{ .git = "https://github.com/foo/bar", .ref = "v1.2" });
const plan = try builder.plan(src, .{});                    // Railpack in a guest
const art  = try builder.build(plan, .{ .out_dir = "bar.h9" });

// The artifact is the layer stack, env, and start command. Run it, open a shell, or write it out.
var m = try art.machine(.{ .stage = .run, .policy = h9x.Policy.untrusted });
const status = try m.run(&.{});
try art.exportOci(file.writer(), .{});
try art.pack(file.writer(), .{});                           // a tar, with its index
try art.pack(exe.writer(), .{ .target = .{ .os = .macos, .arch = .aarch64 } });
```

The types are `Source` (a directory, git ref, or tarball, with its content hash), `Plan` (Railpack's plan plus the layer split and keys), `Layer` (name, key, and path), `Artifact` (the stacked layers, env, and start command), `Policy` (h9 plan text), and `Event`. The CLI is a client of this library and does nothing it can't.

### Commands

Each command takes a SOURCE, which defaults to `.`. `run`, `shell`, `pack`, and `export` build first, reusing every layer whose key matches, so `build` is mostly for CI and scripts.

```sh
h9x run [SOURCE] [--trust] [--listen PORT] [--mount HOST:GUEST[:ro]] [--net MODE] [--timeout D] [--print] [-- CMD ARGS...]
h9x build [SOURCE] [-o OUT] [--replan] [--json]
h9x shell [SOURCE] [--stage build|run] [--keep] [-- CMD ARGS...]
h9x plan [SOURCE] [--json]
h9x pack [SOURCE|OUT.h9] [-o FILE|DIR] [--exe] [--target LIST|all] [--mount HOST:GUEST[:ro]] [--runner FILE] [--no-debug] [--inspect FILE]
h9x export [SOURCE|OUT.h9] (--oci FILE | --docker)
h9x cache ls | prune [--unused DURATION] [--dry-run]
```

- **`run`** builds, then runs the start command, or the command after `--`, on the run stage. A remote source runs under the untrusted profile unless `--trust` is given.
- **`build`** writes the output directory, by default `NAME.h9` in the cwd for a directory source and `$cache/builds/KEY` for a remote one. `--replan` runs Railpack's planner even when the source hasn't changed.
- **`shell`** stacks the build stage's layers with the source at `/app` and a scratch up layer on top, and runs `sh`, or the given command. The scratch layer is removed at exit unless `--keep` is given. Package managers' caches point at the build's `cache/`, so `npm install` in the shell is warm. `--stage run` gives the run stage instead, for debugging a start command.
- **`plan`** prints a summary: the provider, the resolved versions, each step and its layer, the deploy paths, the apt packages and their Wolfi names, and the start command. `--json` prints `plan.json` as kept. It plans if there's no kept plan, and builds nothing.
- **`pack`**, **`export`**, and **`cache`** are below.

`h9x DIR` and `h9x -o OUT DIR`, with no subcommand, keep the proof of concept's meaning, `h9x build`, with a deprecation warning.

```sh
h9x run github.com/railwayapp/railpack//examples/node-npm
h9x run . -- npm test            # replace the start command
h9x run gh:foo/bar@v1.2 --net none --timeout 5m
h9x run . --listen 8080          # a server: allow it to listen
h9x run . --mount ./data:/data   # share a host directory, read-write
h9x run . --print                # show the policy and exit
```

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success, or the run's program exited with an empty status |
| 1 | A build step failed, or Railpack made no steps |
| 2 | A usage, config, or policy error, such as a widening flag |
| 124 | A timeout, as h9's |
| 125 | Setup failed: a download, a root, or a machine h9 couldn't start, as h9's |
| other | For `run` and `shell`, the program's exit status, as h9 maps it |

### Sources

A SOURCE is a directory, a git URL, or a tarball URL:

- **Directories** are used in place, read-only to every machine but `shell`'s.
- **Git** is `https://…`, `git@…`, `github.com/OWNER/REPO`, or `gh:OWNER/REPO`, each with an optional `@REF` and `//SUBDIR`. h9x clones in a machine on the builder root, which has `git`, with network allowed to the source's host only, into `$cache/sources/git/` keyed by the URL, then checks out the ref into `$cache/sources/tree/COMMIT`. A tree is never written again, so a second run of the same commit plans nothing.
- **Tarballs** are an `https://` URL ending in `.tar.gz`, `.tgz`, or `.tar`, fetched in a machine and unpacked into `$cache/sources/tree/SHA256`, keyed by the download's digest.

A `Source` has a path on the host, whether it's remote, and a content hash: the commit, the tarball's digest, or, for a directory, a hash of its files. The directory hash checks each file's size and mtime against the last build's list and rehashes only the files that changed, so a large tree isn't hashed whole on every build.

### Config

h9x adds as little config as it can. Build behaviour already has a home in Railpack, and sandbox behaviour in h9's plan format, so h9x's own file covers only what neither does:

| What | Where | Example |
| --- | --- | --- |
| Build steps, packages, start command, and deploy paths | `railpack.json`, Railpack's own config | `{"deploy": {"startCommand": "node server.js"}}` |
| Runtime versions | `mise.toml`, `.nvmrc`, `.python-version`, and the like, as Railpack reads them | `node = "22"` |
| Roots, limits, and build network | `h9x.toml` | below |
| Sandbox policy per phase | h9 plan lines, in `h9x.toml` | `netallow tcp!api.example.com!443` |

```toml
# h9x.toml
[roots]
base  = ["libjemalloc"]          # more Wolfi packages at run time
build = ["protobuf-dev"]         # more at build time

[build]
memory   = "4G"
net      = "registries"          # none | registries | outbound
netallow = ["tcp!api.example.com!443"]
secrets  = ["NPM_TOKEN"]         # passed to build steps only, never kept in a layer

[run]
policy = """
net disable
memory 1G
"""

[pack]
mount   = [".:/work"]
targets = ["linux-amd64", "macos-arm64"]
```

`h9x.toml` is read from the source's root, then from `~/.config/h9x/config.toml` for user defaults. `toml.zig` parses the subset these need: tables, strings, integers, booleans, arrays of strings, and multi-line basic strings. Anything else is exit 2 with the line.

Precedence runs from strongest to weakest: flags, then `H9X_*` variables, then the source's `h9x.toml`, then the user config, then Railpack's own files and detection. One rule from h9 carries over: a source's file, a flag, or a variable can narrow a policy but never widen the defaults for its trust level. Widening needs `--trust` or an edit to the user config, so a repo can't loosen your sandbox and a script can't do it by accident.

The proof of concept's variables keep working and map across: `H9X_MEMORY` is `build.memory`, `H9X_BASE_PACKAGES` and `H9X_BUILD_PACKAGES` are `roots.base` and `roots.build`, and `H9X_REPLAN=1` is `--replan`. `H9X_CACHE` (default `${XDG_CACHE_HOME:-~/.cache}/h9x`), `H9X_RAILPACK`, and `H9X_RUBY_COMPILE` keep their meanings. `H9`, the h9 binary, goes away, since h9 is linked in, and `H9_FLAGS` is replaced by `H9X_BACKEND`, which sets the backend for every machine. `HTTPS_PROXY` and `SSL_CERT_FILE` are passed into the guest when set, as now. `H9BUILD_*` variables, from h9x's earlier name, warn and are ignored.

### Policy

A policy is h9 plan text ([plan-format](https://github.com/progrium/hyper9/blob/main/design/plan-format.md)), so it's printable and diffable, and `--print` on any command writes the policy of each machine it would start, then exits. The prototype uses these lines: `dir`, `tmp`, `net`, `netallow`, `write`, `memory`, `pids`, `timeout`, `env`, `cwd`, and `run`. `policy.zig` parses them, applies narrowing, and compiles them into `Machine.Options`. When h9's `Machine.init` takes `.plan`, `policy.zig` passes the text through and its compiler goes away; the text h9x writes doesn't change.

The defaults per phase, as tight as each phase allows:

| Phase | Mounts | `net` | `netallow` | Limits |
| --- | --- | --- | --- | --- |
| plan | Builder root; source read-only | `outbound` | The version hosts: mise's, GitHub's, and the runtimes' release hosts | `memory 2G`, `timeout 2m` |
| build | Builder root and lower layers read-only; the new layer `up`; the app's `cache/` writable | `enable` | The registries for the plan's ecosystems | `memory 4G`, `timeout 30m` |
| run, local | Base root and run layers read-only; `--mount`s; writes to a discarded overlay | `outbound`, `enable` with `--listen` | None (any) | `memory 1G` |
| run, remote | Base root and run layers read-only; nothing from the host; writes in memory | `disable`, unless `--net` or `--listen` | None | `memory 1G`, `timeout 10m` |
| shell | Builder root and layers; source writable at `/app`; a scratch layer `up` | `enable` | The registries | `memory 4G` |

`netallow` for build and shell is derived from the plan's providers, with a table in `policy.zig`: npm's, PyPI's (`pypi.org` and `files.pythonhosted.org`), RubyGems', Go's proxy and sum database, crates.io's, NuGet's, Hex's, Deno's, JSR's, and Wolfi's hosts, and GitHub's for mise's downloads. `build.netallow` adds more, and `build.net = "outbound"` or `"none"` narrows. Builds stay on `net enable` rather than `outbound` because Mix listens on 127.0.0.1 for its lock, and `outbound` refuses every listen.

A few rules hold across phases:

- **No host environment.** h9 never imports it. Secrets named by `build.secrets` or `--secret NAME` are read from the host environment and passed as `env` lines to build steps only. They're never written into a layer's key, `plan.json`, `env`, `artifact.json`, or `--print`'s output, which shows `env NAME=…`.
- **Trust is explicit.** `--trust`, or a trusted-sources list in the user config, switches a remote source to the local defaults.
- **Agents get structure.** `--json` gives an agent each step's result and the final exit code, so it can tell a build failure from a test failure without scraping logs.

### The build engine

The engine is the proof of concept's, carried across step by step, with the shell's text files becoming Zig types. Its rules are what the measured build times and sizes rest on, so the prototype ports them as they are, and changes to them come as their own proposals.

- **Roots.** The bootstrap (Alpine's minirootfs and Railpack's static binary, pinned by version and sha256) and the base and builder roots, made by `roots.sh` in a machine on the Alpine root, keyed by architecture, repository, and package set.
- **Plan.** Railpack runs in a machine on the builder root and writes `plan.json`. `plan.zig` reads it into a `Plan`: the steps with the layer each builds in, each layer's key, the runtime layer's shared key and whether its steps copy files, the deploy paths and excludes, and the build and runtime apt packages. The rules are `plan.sh`'s, including the step ranking (a step never builds in a layer below an earlier step's), Gleam's packages step above the runtime layer deploying from both, idiomatic version files (`.nvmrc`, `.python-version`, a `Gemfile`) left out of the shared key, and "Railpack made no build steps" with Railpack's logs. The plan is kept with a key of the source's hash, Railpack's version, and h9x's version, and a kept plan keeps the versions Railpack resolved until the source changes or `--replan`.
- **Layers.** Runtime, deps, and app, each built by `build.sh LAYER` in a machine on the builder root with the layers below stacked over it and the new layer's `.tmp` directory as its up layer. Keys chain as now. The runtime layer is shared in `$cache/runtimes/KEY`, and the files its steps copy from the source (a `mise.toml`) are taken out of it and made again in the deps layer. A failed step leaves no layer.
- **Pruning.** The app layer is pruned to the deploy paths, with whiteouts for excludes a lower layer holds, a deps deploy under 1 MB is copied into the app layer, the runtime's `/usr/lib` goes with the app when the runtime isn't run, and `layers.txt` lists the layers the run stacks.
- **Architecture.** Every key includes the guest architecture. The prototype builds for the host's architecture only.

The workarounds the proof of concept needs for h9 and for Wolfi carry over:

- **apk's scripts** need `chroot`, which h9 doesn't have, so apk runs with `--no-scripts` and h9x makes busybox's applet links itself. Alpine's apk keeps its database in `/lib/apk`, so `roots.sh` makes the root's `/lib -> usr/lib` link first.
- **mise's shims** are links to the mise binary, which only the builder has, so the run puts the runtimes' own bin directories on `PATH` instead, and mise's shims stay in `/tmp`.
- **inotify**, which h9 doesn't have, is how .NET watches its config files, so the run sets `DOTNET_USE_POLLING_FILE_WATCHER=1` for a .NET plan.
- **Package manager caches** are pointed at the output's `cache/` (`npm_config_cache`, `UV_CACHE_DIR`, `GOMODCACHE`, and the rest), over the plan's own cache directories, which would otherwise land in the layers.
- **Ruby** uses mise's precompiled builds (`MISE_RUBY_COMPILE=false`) unless `H9X_RUBY_COMPILE=1`.
- **Erlang** comes from Hex's prebuilt OTP for Ubuntu 24.04, put where mise would install it, as building it with kerl didn't finish in h9. Its `crypto` NIF needs SM4, which Wolfi's libcrypto leaves out, so h9x gives it Ubuntu 24.04's libcrypto in `/usr/lib/x86_64-linux-gnu`, the first place the NIF's RUNPATH looks.
- **A venv's `python`** is an absolute link into the runtime layer, which resolves because h9 follows a Linux program's links from its root ([linux-symlinks](https://github.com/progrium/hyper9/blob/main/design/linux-symlinks.md)).

Behind an HTTPS proxy, Railpack's release clears the proxy settings before running mise, so `H9X_RAILPACK` names a Railpack patched to pass them through, and mise's attestation checks may need turning off with `MISE_GITHUB_ATTESTATIONS=false`, `MISE_AQUA_COSIGN=false`, and `MISE_AQUA_SLSA=false` where the proxy refuses GitHub's API and Sigstore.

### The output directory

The output keeps the proof of concept's layout, specified in `spec/output.md` as a contract other tools can consume without the library:

```
myapp.h9/
  layers/runtime -> $cache/runtimes/KEY   what the plan's packages steps changed: mise's runtimes, shared
  layers/deps/                            what its install steps changed: node_modules, a venv, gems
  layers/app/                             what its build steps changed, pruned to what the plan deploys
  layers/*.key                            each layer's inputs, hashed
  plan.json, plan.key                     Railpack's plan, and its key
  layers.txt                              the layers the run stacks
  env                                     the run environment: PATH, the plan's variables, the start command
  artifact.json                           everything below in one file
  run                                     runs the app: h9x run on this directory
  cache/                                  per-app package manager caches, kept between builds
```

`artifact.json` is everything a consumer needs without reading the rest:

```json
{
  "version": 1,
  "arch": "amd64",
  "base": {"path": "$cache/roots/base-KEY", "packages": ["glibc", "..."]},
  "layers": [{"name": "runtime", "key": "…", "path": "$cache/runtimes/KEY"}, {"name": "deps", "key": "…", "path": "layers/deps"}],
  "env": ["PATH=…", "H9X_START=node server.js"],
  "start": "node server.js",
  "cwd": "/app"
}
```

### Events

Every command reports through `events.zig`. Without `--json`, events print to stderr as `h9x:` lines. With `--json`, each is one JSON object per line on stderr, and the program's own output stays on stdout:

```json
{"event":"phase","phase":"plan","state":"start"}
{"event":"layer","layer":"deps","state":"cached","key":"…"}
{"event":"step","layer":"app","step":"build","state":"start"}
{"event":"output","layer":"app","step":"build","stream":"stderr","text":"…"}
{"event":"step","layer":"app","step":"build","state":"exit","status":0,"ms":4120}
{"event":"result","command":"build","status":0,"out":"/home/me/app.h9","ms":5302}
```

The kinds are `phase`, `fetch`, `root`, `layer`, `step`, `output`, `policy`, and `result`, and the last line is always `result`, with the exit code. `spec/events.md` specifies each field.

### Packs

```sh
h9x pack . -o app.tar                       # a tar, for h9 or the browser host
h9 --archive app.tar:#L sh /.h9x/run

h9x pack . --exe -o app                     # an executable for this machine
./app --port 8080                           # runs the start command, with these args

h9x pack . --target linux-amd64,windows-amd64 -o dist/
h9x pack ./app.h9 --target all -o dist/     # from a build directory, without building
```

A pack is the base root and the run layers flattened into one tar, whiteouts applied, with `/.h9x/pack.json` (the env, start command, cwd, run policy, and the layers' keys) and `/.h9x/run`, a script that starts the app with plain h9. The tar's last entry is `/.h9x/index`, which lists each file's path, offset, and size, as eStargz's table of contents does, so a reader can open any file with one seek. `tar.zig` writes it deterministically: entries sorted by path, mtimes 0, uid and gid 0, and no host names, so the same layers make the same bytes. The pack's digest is the sha256 of the tar. It's a plain tar, so any tar tool lists it, and h9's `--archive` mounts it. h9's `.h9a` isn't used: it was made for the browser host's root and has no index.

**Executables.** `--exe` and `--target` wrap the pack in an executable: a prebuilt runner for the target with the archive joined to it, so the result runs on a machine with no h9, h9x, or Docker. `--exe` means the host's own target. `--target` takes a comma-separated list of `OS-ARCH` names, or `all`, and writes `DIR/NAME-OS-ARCH` (`.exe` on Windows) for each. Making one needs no compiler and no SDK, so any host can make every target's. Each OS gets the container its own tools expect, so signing and inspection tools still work on the result:

| Target OS | Where the archive goes | How the runner finds it |
| --- | --- | --- |
| Linux | Appended after the ELF image | Reads the trailer from the end of `/proc/self/exe` |
| macOS | A segment of its own, `__H9X` with one section `__pack`, added before `__LINKEDIT`, as Node's single-executable applications do | Looks up the section in its own Mach-O header, then reads that range of the file from `_NSGetExecutablePath` |
| Windows | A PE section, `.h9x`, added after the last section, before any Authenticode certificate | Walks its own section table from `GetModuleHandleW(NULL)`, then reads that range of the file from `GetModuleFileNameW` |

Every target also ends with a 32-byte trailer: a magic string, the archive's offset and length, and a version. So one code path in the runner, and `h9x pack --inspect FILE`, finds the archive in any of them, and the section is what keeps the OS's signature valid.

**Signing.** Adding the archive changes the executable, so the runner's own signature never survives. macOS executables are ad-hoc signed with the `com.apple.security.hypervisor` entitlement, which HVF requires to start a VM, by `adhoc.zig`, a port of the ad-hoc signer in Zig's own Mach-O linker, from any host. That's enough to run on the machine that made it, or after `xattr -d com.apple.quarantine`. Linux and Windows executables aren't signed; h9x writes `SHA256SUMS` beside a `--target` build's files.

**Runners.** The runner is h9's library plus a small `main`. It's a separate build from `h9x`, without Railpack, the guest scripts, or the cache, so it adds only h9's size to the app. The host's runner is embedded in `h9x`, so `--exe` works offline. The others come from h9x's release as `h9x-runner-VERSION-TARGET`, pinned by version and sha256 in `h9x`, and download into `$cache/runners/` the first time a pack asks for them. `--runner FILE` uses one built by hand, for a patched h9, and is how the prototype's tests pack for other targets before there's a release.

**Targets.** h9's release targets, each needing a test pass of a packed app before h9x calls it supported:

| Target | h9 build | Same-architecture guests run on | In the prototype |
| --- | --- | --- | --- |
| `linux-amd64` | `x86_64-linux-musl`, static | KVM, or the emulator without `/dev/kvm` | Yes |
| `linux-arm64` | `aarch64-linux-musl`, static | KVM, or the emulator | Yes |
| `macos-arm64` | `aarch64-macos` | HVF | Yes, ad-hoc signed |
| `windows-amd64` | `x86_64-windows-gnu` | WHP where the Windows Hypervisor Platform feature is on, or the emulator | Yes. h9 doesn't make symlinks in a Windows host's overlays, which some package managers do at run time. |
| `macos-amd64` | None: h9 doesn't build it | Would be HVF on Intel | No: needs an h9 target first |
| `windows-arm64` | `aarch64-windows-gnu` | The emulator: h9's WHP backend runs amd64 only | No: slow until h9 runs arm64 on WHP |

The layers hold Linux binaries for one architecture, and the prototype builds the host's, so `all` means the targets whose architecture matches: `linux-amd64` and `windows-amd64` on an amd64 host, and `linux-arm64` and `macos-arm64` on an arm64 host. A target of the other architecture is exit 2. On a host with no usable hypervisor, the runner falls back to the emulator with h9's usual warning. The browser host takes the tar, not an executable.

**Running a pack.** The runner reads the trailer from its own file, verifies the archive's digest, and extracts it once into `${XDG_CACHE_HOME:-~/.cache}/h9x/packs/DIGEST`, which it mounts read-only with a `tmp` overlay for writes, thrown away at exit. It runs the start command with the executable's arguments after it, as `h9x run . -- ARGS` would. A few rules keep a packed executable predictable:

- **Arguments are the app's.** Everything after `argv[0]` goes to the start command. The runner reads one variable of its own, `H9X_PACK`: `H9X_PACK=info ./app` prints the pack's digest, layers, and policy, and `H9X_PACK=shell ./app` opens a shell in it. `--no-debug` at pack time turns both off.
- **The policy is sealed in.** The run policy from `h9x.toml`'s `[run]` table is in `pack.json`, and the runner applies it as `h9x run` would for a local source. Host files are reachable only through the `--mount` lines given at pack time, such as `--mount .:/work` for a CLI that works on the current directory. The environment can narrow the policy (`H9X_PACK_NET=none`) but never widen it.

### Export

```sh
h9x export . --oci app.tar          # an OCI image layout tarball
h9x export . --docker | docker load
```

`--oci FILE` writes an OCI image layout as a tar, and `--docker` writes a `docker save` tarball to stdout. The image's layers are the base root as one layer, then each run layer from `layers.txt`, each written by `tar.zig` deterministically and gzipped with `std.compress.flate`, with `.wh.` whiteouts as they are. The config has the architecture, `Env`, `WorkingDir` (`/app`), and `Cmd` (`["/bin/sh", "-c", START]`). The same build makes the same image digest.

### Cache

```sh
h9x cache ls                         # roots, runtimes, sources, builds, runners, and packs, with sizes and last use
h9x cache prune --unused 30d
```

The cache's layout is specified in `spec/cache.md`: `bootstrap/`, `dl/`, `tools/`, `roots/`, `runtimes/`, `sources/`, `builds/`, `runners/`, and `packs/`. Each entry a build uses has its mtime touched, so `cache ls` lists each kind with its entries, sizes, and last use, and `cache prune --unused 30d` removes what hasn't been used in 30 days. A runtime or root that a build in the cache still names is kept, whatever its age. `--dry-run` lists what it would remove.

### After the prototype

These are part of h9x's design, are independent of the prototype's formats, and each gets its own proposal when it's next:

- **`--compress zstd[:LEVEL]`** stores a pack as a seekable `.tar.zst`: the same tar in independent zstd frames, each holding one file's header and data (small files sharing a frame up to 64 KB, big files split into 1 MB frames), with the index in a frame of its own recording each file's frame, offset, and size. `zstd -d | tar -x` still reads it, since the frames concatenate into an ordinary stream, as Podman's `zstd:chunked` layers do. zstd rather than brotli or xz because it decompresses several times faster at a similar ratio and Zig's std has a decoder. `none` stays the default, since start-up is the runner's hot path and a download is compressed anyway. It needs h9's `--archive` to read zstd.
- **Serving packs in place.** A mount that serves an indexed tar read-only from a range of a host file, reading files as they're opened, with writes to an overlay above it (`--archive FILE@OFFSET+LENGTH`, or a `Machine.Options` mount kind), so the runner doesn't extract. It needs an h9 change.
- **Developer ID signing.** `--sign IDENTITY` and `--notarize`: `codesign` and `notarytool` on a Mac, or [rcodesign](https://github.com/indygreg/apple-platform-rs) as a guest from Linux or CI, given the certificate and an App Store Connect key as secrets by name. On Windows, `osslsigncode` as a guest, or `signtool` on a Windows host, so SmartScreen doesn't warn.
- **The other architecture.** `h9x build --arch` builds on each architecture's machine, and `h9x pack ./app-amd64.h9 ./app-arm64.h9 --target all` picks each target's build by architecture. `--guest-arch amd64` packs amd64 layers for every target, running on the emulator on arm64 hosts, as a fallback. Building the other architecture on h9's emulator works but is too slow for native modules.
- **`export --push REF`** straight to a registry, with no daemon, by plain HTTP or `crane` as a guest; and **`cache push` and `pull`** to share layers by key, which needs keys that don't depend on host paths.
- **`h9x.lock` and `verify`.** The kept plan and its key, promoted to a committed file with the Wolfi package versions added, since those float, and `verify`, which rebuilds from it and diffs the layer digests.
- **`h9x doctor`**, which checks h9, its backends, and the network, and **`h9x fetch`** and **`cache export`**, which warm the cache and write it to a tarball for a CI cache step.
- **The C ABI.** `h9x_build`, `h9x_run`, `h9x_export`, and `h9x_pack`, taking and returning JSON, so Go, Python, and Node bindings stay thin. Until then, the output directory and `--json` are the contract for other languages.
- **Distribution.** One static binary per OS and architecture, with h9 linked in, from GitHub releases, a Homebrew tap, and an install script, notarized on macOS. A release pins Railpack, Alpine, and the root package set, so two people on the same release plan the same way, and bumping Railpack is a release. Before the first one, check Homebrew, npm, PyPI, and crates.io for the name.
- **The untrusted-code launch.** Pitching `h9x run` as safe for any repo waits on an audit of h9's sandbox, fixes for the h9 bugs behind any failing languages, and cold builds near Railpack's times, which are limited today by h9's file-creation, threading, and per-call policy-check costs.

## Rationale

**Zig, on h9's library.** h9 is a Zig library with a `Machine` API, so h9x drives machines in-process instead of running an `h9` binary. That gives one static binary with h9 inside, one process to sign on macOS, and code shared with h9's browser host. The runner has to embed h9, so it would be Zig or C in any language, and sharing the tar index reader and the section lookup with `h9x` makes that one build. Go's real advantages are go-containerregistry and importing Railpack's planner. Running `crane` as a guest covers the first, and running Railpack as a guest covers the second, so neither outweighs a single binary.

**Every third-party tool stays a guest.** Railpack, mise, apk, and the package managers run in h9 as Linux binaries, as they do now, so h9x never links Go or Rust code and nothing runs on the host's own OS. The plan is the seam: Railpack writes `plan.json`, and Zig reads it.

**Railpack stays the planner.** Whether the plan format becomes h9x's own, with Railpack as one producer, is left open. `plan.zig`'s `Plan` type is the seam either way.

**No build config of h9x's own.** Build overrides stay in `railpack.json` and the languages' own files, and sandbox policy in h9's plan format, so `h9x.toml` covers only roots, limits, and the network. A second build config would be one more thing to keep in step with Railpack.

**Policy text now, `Machine.Options` underneath.** Writing policy as plan lines means `--print`, `h9x.toml`'s `[run] policy`, and `pack.json` use the format h9 is moving to. Compiling the lines h9x uses is a small parser, and it goes away when h9 takes `.plan`.

**Seven commands, with `build` implicit.** `run` and `shell` build first, so most people never type `build`, and the launch story is one command.

**A plain tar with an index, not `.h9a`.** Any tar tool can read it, h9's `--archive` mounts it today, and the index makes opening one file one seek. `.h9a` was made for the browser host's root and has no index.

**Extract packs, rather than serving them in place.** h9's `--archive` unpacks into memory, which is too large for a runtime and `node_modules`, and serving a range of a file needs an h9 change. Extracting once into the user cache, keyed by digest, is slower on first start and costs disk, but needs nothing from h9 and keeps the pack format the same, so the in-place mount can replace it later.

**Host architecture only.** Building the other architecture's layers runs on h9's emulator, which is too slow for native modules to test in the prototype. Keys include the architecture from the start, so `--arch` adds a second set without invalidating the first.

**Rejected names.** h9x reads like `npx` (`h9x github.com/foo/bar`) and keeps the h9 family name. build9, h9build (its name while incubating), and `h9 build` as a subcommand were considered: h9 is a flags-only runtime, and folding Railpack, mise, and OCI export into it would bloat it. run9 ([breezewish/run9-cli](https://pkg.go.dev/github.com/breezewish/run9-cli)), anyrun (a Wayland launcher), hatch (Python's packaging tool), and layup (too generic) were ruled out.

## Compatibility

- **The proof of concept's command.** `h9x [-o OUT] APPDIR` keeps working as `h9x build`, with a warning. Its environment variables map as under Config, except `H9` and `H9_FLAGS`, which warn and are ignored.
- **The output directory.** The same layout, plus `artifact.json`. Keys change, since they include the architecture and h9x's version, so the first build with the prototype rebuilds every layer once, and runtime layers in `$cache/runtimes` rebuild once too.
- **The cache.** The same root, with new directories. Roots are kept if their key's inputs are unchanged. h9build's old cache, `~/.cache/h9build`, isn't used, and h9x says it can be removed.
- **h9.** The prototype pins a hyper9 commit with up layers and the fixes listed under Background, and needs nothing from h9 that isn't on main. When h9 takes `.plan`, `policy.zig`'s compiler is removed without changing h9x's output.
- **Host tools.** The host no longer needs `curl`, `tar`, or a shell: downloads use `std.http`, and tars are read and written in Zig.

## Security

What the guest can reach is set per phase by the policy table, and `--print` shows it. The changes from the proof of concept are mostly tighter: builds get a registry allowlist instead of an open network, a remote source runs with no host files and no network by default, and secrets reach only build steps and never land in a file h9x writes. Two things are new. A git or tarball source is fetched in a machine allowed to reach that source's host only, and its tree is read-only to every phase but `shell`. A packed executable's policy is sealed in `pack.json`, and the runner verifies the archive's digest before extracting it, so a tampered pack is refused rather than run; the digest isn't a signature, so a pack is as trusted as wherever it came from.

h9's sandbox hasn't been audited, and h9's README says it shouldn't be trusted with malicious code. Until that changes, the untrusted profile is defence in depth on top of a normal OS account, and h9x's docs say so wherever they describe `run` on a remote source.

## Done criteria

Integration cases are in `tests/*.zig`, run by `zig build integration`, and unit cases by `zig build test`. The examples are Railpack's, from a pinned commit of its repository.

- [ ] `zig build` makes `h9x` and `h9x-runner` on Linux amd64, and `zig build test` passes.
- [ ] `test "every example the proof of concept builds also builds and runs [prototype]"` passes for `go-mod`, `node-npm`, `node-bun`, `node-lts-npm-native-deps`, `python-uv`, `deno-2`, `ruby-latest`, `cpp-cmake`, `gleam`, `elixir-latest`, `rust-rocket`, `zig`, `dotnet-cli`, and `dotnet-api`, under the default build policy.
- [ ] `test "a rebuild with nothing changed takes under a second and rebuilds no layer [prototype]"` passes for `node-npm` and `python-uv`.
- [ ] `test "a second app on the same runtimes shares the runtime layer [prototype]"` passes.
- [ ] `test "plan.zig reads each example's plan.json as plan.sh did [prototype]"` passes, against `plan.sh`'s output kept as fixtures.
- [ ] `h9x run github.com/railwayapp/railpack@REF//examples/node-npm` prints the example's expected output, and a second run plans nothing.
- [ ] `test "a tarball source builds [prototype]"` passes.
- [ ] `test "h9x shell -- node -v runs in the build stage, and the source is writable [prototype]"` passes.
- [ ] `test "--print shows each phase's policy, and a widening flag or h9x.toml line is exit 2 [prototype]"` passes.
- [ ] `test "a build step that connects outside the allowlist fails [prototype]"` passes.
- [ ] `test "a secret reaches the build step and no file h9x writes [prototype]"` passes.
- [ ] `test "--json emits one event per line, ending in result [prototype]"` passes.
- [ ] `test "pack writes the same tar twice, and h9 --archive runs it [prototype]"` passes for `go-mod`.
- [ ] `test "pack --exe runs the app on linux-amd64 with nothing else installed [prototype]"` passes for `go-mod` and `node-npm`, in a clean home directory.
- [ ] `test "pack --target writes a macOS section, a PE section, and the trailer, which --inspect reads [prototype]"` passes, with runners given by `--runner`.
- [ ] A `macos-arm64` executable packed on Linux runs on Apple Silicon.
- [ ] `test "export --oci writes the same digest twice, and its layers match the run's [prototype]"` passes.
- [ ] `h9x export . --docker | docker load` and `docker run` print `node-npm`'s expected output.
- [ ] `test "cache prune --unused removes only what no build names [prototype]"` passes.
- [ ] `test "h9x -o OUT DIR still works, with a warning [prototype]"` passes.
- [ ] `spec/` describes what's built: the CLI, the output directory, events, the pack and executable formats, and the cache.

## Implementation

1. The skeleton: `build.zig` and `build.zig.zon` on h9, the two executables, `cli.zig` with every subcommand as a stub, the shared types with their fields, `machine.zig`, and the embedded guest scripts. It lands first, so the parts below build on fixed interfaces.
2. In parallel: the policy and config, the plan reader, the tar and index writer, the executable containers and signer, the sources and cache, and the events.
3. Roots and layers on the plan reader and policy, with `build` working end to end.
4. Packs, the runner, and export, on the tar writer, the containers, and a built artifact.
5. `run`, `shell`, `plan`, and the examples' integration cases; the proof of concept moves to `poc/` and is removed once every example passes.
6. The spec.

## Open issues

- Whether a source's `h9x.toml` may raise `build.memory` or `build.timeout` past the defaults. As written, limits count as widening, so it can't without `--trust`.
- Whether `shell` writes into the source by default, as written, or works on a copy unless `--rw`.
- Where a remote source's build output goes. As written it's `$cache/builds/KEY`, which `cache prune` cleans, and `-o` puts it elsewhere.
- Whether the runner should use h9's `.archive` mount for small packs, to skip the disk.
- Whether `run`'s local profile should default to `net disable` too, with `--net` to allow it, for symmetry with remote sources.
- Whether builds can get a network mode that allows outbound connections plus loopback listens, which would let them drop `net enable`.
- Whether packs should carry the builder root too, so a pack can rebuild itself.
- Whether `--target all` should include targets whose app runs only on the emulator, or leave them to be named.
- Whether one executable should carry both architectures' layers, as a macOS universal binary does, or one file per target is simpler.
- Whether the runner should check for a newer pack, or updating is the app's own job.
- How PHP builds without FrankenPHP's image, and whether Java builds at all. Older Ruby needs h9 to finish ruby-build's source build.
- Whether dev dependencies should be pruned by default, with Railpack's `RAILPACK_PRUNE_DEPS`.
