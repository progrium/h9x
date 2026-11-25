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

h9x is a proof of concept today: one POSIX shell script, `h9x [-o OUT] APPDIR`, and three guest scripts, which build an app into layers that h9 runs. [docs/design.md](../docs/design.md) describes where it's headed: seven subcommands, a small config file, per-phase sandbox policy in h9's plan format, single-file packs and executables, and a Zig library on h9's `Machine`. This proposal is the first spec for that h9x, scoped to a prototype that can be built in parallel and used. The prototype is one Zig program that links h9, with the commands `run`, `build`, `shell`, `plan`, `pack`, `export`, and `cache`, git and tarball sources, `h9x.toml`, `--json` events, policy written as h9 plan lines, packs with an index, executables for h9's release targets, and OCI image tarballs. Railpack, mise, apk, and the package managers keep running as guests, and the build engine keeps the POC's behaviour: the same layers, keys, sharing, and pruning.

## Background

What exists today, in [h9x](../h9x) and [guest/](../guest):

- **One command.** `h9x [-o OUT] APPDIR` takes a local directory and writes `OUT/` with `layers/`, `layers.txt`, `env`, `plan.json`, `run`, and `cache/`. Running the app is `OUT/run`, a generated script of `h9` flags.
- **An engine that works.** Railpack plans in a machine on the builder root, mise installs runtimes, Wolfi packages make the base and builder roots, and each of the runtime, deps, and app layers is built as an h9 up layer over the layers below it. Plans are kept by a key of the source, layers by chained input keys, runtime layers are shared between apps in `$cache/runtimes`, and the app layer is pruned to what the plan deploys. A build with nothing changed takes about half a second, and the README's table lists the fourteen Railpack examples that build and run.
- **Shell all the way down.** The host side has no JSON parser, so `guest/plan.sh` runs `jq` in a guest to turn `plan.json` into plain text files (`steps.txt`, `keys.txt`, `shared.txt`, `deploy.txt`, and two apt lists) that the host script reads with `awk`. Config is environment variables. Policy is whatever flags the script passes to `h9`, and builds run with `--net enable`.
- **Nothing to hand someone.** The output depends on the base root and runtime layers in the user's cache, so it can't be copied to another machine, and there's no pack, image, or executable.

[docs/design.md](../docs/design.md) settled the surface: the commands and their flags, `h9x.toml`'s tables and precedence, the per-phase policy table, the pack format with its index, the executable containers per OS, the targets table, and Zig on h9's library as the language. Its phasing builds the surface in shell first and ports it to Zig in phase 4. This proposal changes that order: the prototype is Zig from the start (see Rationale), and it takes the parts of phases 1, 3, and 4 that make the launch story usable, leaving hardening and distribution for later proposals.

h9 provides what the prototype needs as a library ([docs/embedding.md](https://github.com/progrium/hyper9/blob/main/docs/embedding.md)): `Machine.init` with `.dir` mounts and up layers ([upper-layers](https://github.com/progrium/hyper9/blob/main/design/upper-layers.md)), `.tmp` and `.archive` mounts, `net`, `net_allow`, memory, pids, and timeout limits, `compilePlan` and `print` for `--print`, and `run` with a status. [plan-format](https://github.com/progrium/hyper9/blob/main/design/plan-format.md), a draft in h9, makes the plan a text format that `Machine.init` takes as `.plan`; the prototype writes its policy in that format and compiles the lines it uses into `Machine.Options` itself until h9 does.

## Proposal

### One program, two binaries

h9x is a Zig project with h9 as a dependency in `build.zig.zon`, pinned to a hyper9 commit. `zig build` makes two executables from one module tree:

- **`h9x`**, the CLI: the commands below, with the guest scripts, the base and builder package lists, and the host target's runner embedded.
- **`h9x-runner`**, the runner for packed executables: h9's `Machine`, the pack reader, and the container lookup, with none of the builder.

The modules, under `src/`, and what each owns:

| Module | Owns |
| --- | --- |
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
| `oci.zig` | OCI image layouts and `docker load` tarballs |
| `cache.zig` | The cache's layout, `cache ls`, and `cache prune` |
| `runner/main.zig` | The runner's `main` |

`guest/build.sh` and `guest/roots.sh` stay guest scripts, embedded in `h9x` and mounted into build machines from memory. `guest/plan.sh` goes away: the host reads `plan.json` with `std.json`, so the builder root no longer needs `jq` for h9x's own use. The shell script stays in the repo, as `poc/h9x`, until the prototype builds every example it does, and is then removed.

### Commands

Each command takes a SOURCE, which defaults to `.`. `run`, `shell`, `pack`, and `export` build first, reusing every layer whose key matches.

```sh
h9x run [SOURCE] [--trust] [--listen PORT] [--mount HOST:GUEST[:ro]] [--net MODE] [--timeout D] [--print] [-- CMD ARGS...]
h9x build [SOURCE] [-o OUT] [--replan] [--json]
h9x shell [SOURCE] [--stage build|run] [--keep] [-- CMD ARGS...]
h9x plan [SOURCE] [--json]
h9x pack [SOURCE|OUT.h9] [-o FILE|DIR] [--exe] [--target LIST|all] [--mount HOST:GUEST[:ro]] [--runner FILE] [--no-debug]
h9x export [SOURCE|OUT.h9] (--oci FILE | --docker)
h9x cache ls | prune [--unused DURATION] [--dry-run]
```

- **`run`** builds, then runs the start command, or the command after `--`, on the run stage (below). A remote source runs under the untrusted profile unless `--trust` is given.
- **`build`** writes the output directory, by default `NAME.h9` in the cwd for a directory source and `$cache/builds/KEY` for a remote one. `--replan` replaces `H9X_REPLAN=1`.
- **`shell`** stacks the build stage's layers with the source at `/app` and a scratch up layer on top, and runs `sh`, or the given command. The scratch layer is removed at exit unless `--keep` names it. `--stage run` gives the run stage instead, for debugging a start command.
- **`plan`** prints a summary: the provider, the resolved versions, each step and its layer, the deploy paths, the apt packages and their Wolfi names, and the start command. `--json` prints `plan.json` as kept. It plans if there's no kept plan, and builds nothing.
- **`pack`**, **`export`**, and **`cache`** are below.

`h9x` with no subcommand and one directory argument keeps the POC's meaning, `h9x build DIR`, with a deprecation warning, so existing scripts keep working through the prototype. `-o` keeps its meaning.

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

A `Source` has a path on the host, whether it's remote, and a content hash: the commit, the tarball's digest, or, for a directory, the hash of its files that the plan key uses today. The directory hash checks each file's size and mtime against the last build's list and rehashes only the files that changed.

### Config

`h9x.toml` is read from the source's root, then from `~/.config/h9x/config.toml` for user defaults. Its tables are design.md's: `[roots]` with `base` and `build`, `[build]` with `memory`, `net`, `netallow`, and `secrets`, and `[run]` with `policy`, plus `[pack]` with `mount` and `targets`. `toml.zig` parses the subset these need: tables, strings, integers, booleans, arrays of strings, and multi-line basic strings. Anything else is exit 2 with the line.

Precedence runs from strongest to weakest: flags, then `H9X_*` variables, then the source's `h9x.toml`, then the user config, then Railpack's own files. A source's file can narrow a policy but never widen the defaults for its trust level; a flag or variable can narrow it further. The POC's variables keep working and map across: `H9X_MEMORY` is `build.memory`, `H9X_BASE_PACKAGES` and `H9X_BUILD_PACKAGES` are `roots.base` and `roots.build`, `H9X_CACHE`, `H9X_RAILPACK`, and `H9X_RUBY_COMPILE` keep their meanings, and `H9`, the h9 binary, goes away, since h9 is linked in. `H9_FLAGS` is replaced by `H9X_BACKEND`, which sets the backend for every machine.

### Policy

A policy is h9 plan text ([plan-format](https://github.com/progrium/hyper9/blob/main/design/plan-format.md)), so it's printable and diffable, and `--print` on any command writes the policy of each machine it would start, then exits. The prototype uses these lines: `dir`, `tmp`, `net`, `netallow`, `write`, `memory`, `pids`, `timeout`, `env`, `cwd`, and `run`. `policy.zig` parses them, applies narrowing, and compiles them into `Machine.Options`. When h9's `Machine.init` takes `.plan`, `policy.zig` passes the text through and its compiler goes away; the text h9x writes doesn't change.

The defaults per phase are design.md's table, as plan lines:

| Phase | Mounts | `net` | `netallow` | Limits |
| --- | --- | --- | --- | --- |
| plan | Builder root; source read-only | `outbound` | The version hosts: mise's, GitHub's, and the runtimes' release hosts | `memory 2G`, `timeout 2m` |
| build | Builder root and lower layers read-only; the new layer `up`; the app's `cache/` writable | `enable` | The registries for the plan's ecosystems | `memory 4G`, `timeout 30m` |
| run, local | Base root and run layers read-only; `--mount`s | `outbound`, `enable` with `--listen` | None (any) | `memory 1G` |
| run, remote | Base root and run layers read-only; nothing from the host | `disable`, unless `--net` or `--listen` | None | `memory 1G`, `timeout 10m` |
| shell | Builder root and layers; source writable at `/app`; a scratch layer `up` | `enable` | The registries | `memory 4G` |

`netallow` for build and shell is derived from the plan's providers, with a table in `policy.zig`: npm's, PyPI's, RubyGems', Go's proxy and sum database, crates.io's, NuGet's, Hex's, Deno's, JSR's, and Wolfi's hosts, and GitHub's for mise's downloads. `build.netallow` adds more, and `build.net = "outbound"` or `"none"` narrows. Builds stay on `net enable` rather than `outbound` because Mix listens on 127.0.0.1 for its lock, and `--net outbound` refuses every listen.

Secrets named by `build.secrets` or `--secret NAME` are read from the host environment and passed as `env` lines to build steps only. They're never written into a layer's key, `plan.json`, `env`, `artifact.json`, or `--print`'s output, which shows `env NAME=…`.

### The build engine

The engine is the POC's, carried across step by step, with the shell's text files becoming Zig types:

- **Roots.** The bootstrap (Alpine's minirootfs and Railpack's static binary, pinned by version and sha256) and the base and builder roots, made by `roots.sh` in a machine on the Alpine root, keyed by architecture, repository, and package set, with busybox's links made by h9x afterwards, as now.
- **Plan.** Railpack runs in a machine on the builder root and writes `plan.json`. `plan.zig` reads it into a `Plan`: the steps with the layer each builds in, each layer's key, the runtime layer's shared key and whether its steps copy files, the deploy paths and excludes, and the build and runtime apt packages. The rules are `plan.sh`'s, including the step ranking, Gleam's packages step above the runtime layer, the idiomatic version files left out of the shared key, and "Railpack made no build steps" with Railpack's logs. The plan is kept with a key of the source's hash, Railpack's version, and h9x's version.
- **Layers.** Runtime, deps, and app, each built by `build.sh LAYER` in a machine on the builder root with the layers below stacked over it and the new layer's `.tmp` directory as its up layer. Keys chain as now. The runtime layer is shared in `$cache/runtimes/KEY`. A failed step leaves no layer.
- **Pruning.** The app layer is pruned to the deploy paths, with whiteouts for excludes a lower layer holds, a small deps deploy is copied into the app layer, the runtime's `/usr/lib` goes with the app when the runtime isn't run, and `layers.txt` lists the layers the run stacks. All as now, in Zig.
- **Architecture.** Every key includes the guest architecture. The prototype builds for the host's architecture only; `--arch` is a later proposal.

### The output directory

The output keeps the POC's layout, which becomes a documented contract in `docs/output.md`, and adds `artifact.json`, which is everything a consumer needs without reading the rest:

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

`run` is still written, as a script that runs `h9x run OUT`, so `OUT/run` keeps working.

### Events

Every command reports through `events.zig`. Without `--json`, events print to stderr as the POC's `h9x:` lines. With `--json`, each is one JSON object per line on stderr, and the program's own output stays on stdout:

```json
{"event":"phase","phase":"plan","state":"start"}
{"event":"layer","layer":"deps","state":"cached","key":"…"}
{"event":"step","layer":"app","step":"build","state":"start"}
{"event":"output","layer":"app","step":"build","stream":"stderr","text":"…"}
{"event":"step","layer":"app","step":"build","state":"exit","status":0,"ms":4120}
{"event":"result","command":"build","status":0,"out":"/home/me/app.h9","ms":5302}
```

The kinds are `phase`, `fetch`, `root`, `layer`, `step`, `output`, `policy`, and `result`, and the last line is always `result`, with the exit code. `docs/events.md` documents each field.

### Packs

`h9x pack` writes design.md's pack: the base root and the run layers flattened into one tar, whiteouts applied, with `/.h9x/pack.json` (the env, start command, cwd, run policy, and the layers' keys) and `/.h9x/run`, a script that starts the app with plain h9. The tar's last entry is `/.h9x/index`, which lists each file's path, offset, and size. `tar.zig` writes it deterministically: entries sorted by path, mtimes set to 0, uid and gid 0, and no host names, so the same layers make the same bytes. The pack's digest is the sha256 of the tar.

`--exe` and `--target` join the pack to a runner:

- **Containers.** As design.md's table: appended after the ELF image on Linux, a `__H9X,__pack` section before `__LINKEDIT` on macOS, and a `.h9x` section on Windows. Every target also gets the 32-byte trailer (a magic string, the archive's offset and length, and a version), so `h9x pack --inspect FILE` and the runner find the archive in any of them the same way.
- **Signing.** macOS executables are ad-hoc signed with the `com.apple.security.hypervisor` entitlement by `adhoc.zig`, a port of the ad-hoc signer in Zig's Mach-O linker, from any host. Linux and Windows executables aren't signed; h9x writes `SHA256SUMS` beside a `--target` build's files.
- **Runners.** The host's runner is embedded in `h9x`. The others come from h9x's release, pinned by version and sha256 in `h9x`, and are downloaded into `$cache/runners/` the first time a pack asks for them. `--runner FILE` uses one built by hand, which is how the prototype's tests pack for other targets before there's a release.
- **Targets.** `--target` takes `linux-amd64`, `linux-arm64`, `macos-arm64`, and `windows-amd64`, or `all` for those of them whose architecture matches the layers. Since the prototype builds for the host's architecture only, `all` on an amd64 host means `linux-amd64` and `windows-amd64`, and on an arm64 host `linux-arm64` and `macos-arm64`. A target of the other architecture is exit 2, naming `--arch` as later work.

The runner reads the trailer from its own file, verifies the archive's digest, and extracts it once into `${XDG_CACHE_HOME:-~/.cache}/h9x/packs/DIGEST`, which it mounts read-only with a `tmp` overlay for writes. It then runs the start command with its own arguments appended, under the policy sealed in `pack.json`, which the environment can narrow (`H9X_PACK_NET=none`) and never widen. `H9X_PACK=info` prints the digest, layers, and policy, and `H9X_PACK=shell` runs `sh` in the pack, unless the pack was made with `--no-debug`. Serving the tar in place, without extracting it, needs h9's in-file archive mount and is a later proposal.

### Export

`h9x export --oci FILE` writes an OCI image layout as a tar, and `--docker` writes a `docker save` tarball to stdout for `docker load`. The image's layers are the base root, then each run layer from `layers.txt`, each written by `tar.zig` deterministically and gzipped with `std.compress.flate`, with `.wh.` whiteouts as they are. The config has the architecture, `Env`, `WorkingDir` (`/app`), and `Cmd` (`["/bin/sh", "-c", START]`). The same build makes the same image digest.

### Cache

The cache's layout is documented in `docs/cache.md`: `bootstrap/`, `dl/`, `tools/`, `roots/`, `runtimes/`, `sources/`, `builds/`, `runners/`, and `packs/`. Each entry that a build uses gets its mtime touched, so `h9x cache ls` lists each kind with its entries, sizes, and last use, and `h9x cache prune --unused 30d` removes what hasn't been used in 30 days. A runtime or root that a build in the cache still names is kept, whatever its age. `--dry-run` lists what it would remove.

## Rationale

**Zig from the start, rather than the surface in shell first.** design.md's phasing tries the surface in shell where it's cheap to change. Three things argue against it now. The surface is settled in design.md in more detail than a shell trial would teach. The shell script can't parse JSON or TOML, write an indexed tar, or edit a Mach-O file without guest tools, so phases 1 and 3 in shell would mostly be work thrown away in phase 4. And a Zig module tree with fixed interfaces can be built by several people, or agents, at once, where one 430-line script can't. The POC stays as the reference for the engine's behaviour, and the example table is how the prototype is checked against it.

**Keep the engine's rules, move the code.** The layer split, keys, sharing, and pruning rules are what the README's numbers measure, and each has a reason in the POC's comments. Changing them and the language at once would make a regression impossible to place, so the prototype ports them as they are, and changes come as their own proposals.

**Railpack stays the planner.** design.md leaves open whether the plan format becomes h9x's own. Reading `plan.json` in Zig keeps that door open, since `plan.zig`'s `Plan` type is the seam either way, without deciding it.

**Policy text now, `Machine.Options` underneath.** Writing policy as plan lines means `--print`, `h9x.toml`'s `[run] policy`, and `pack.json` use the format h9 is moving to. Compiling the lines h9x uses is a small parser, and it goes away when h9 takes `.plan`.

**Extract packs, rather than serving them in place.** h9's `--archive` unpacks into memory, which is too large for a runtime and `node_modules`. Serving a range of a file needs an h9 change. Extracting once into the user cache, keyed by digest, is slower on first start and costs disk, but needs nothing from h9 and keeps the pack format the same, so the in-place mount can replace it later.

**Host architecture only.** Building the other architecture's layers runs on h9's emulator, which is too slow for native modules to test in the prototype. Keys include the architecture from the start, so `--arch` adds a second set without invalidating the first.

**Left out.** `--compress zstd`, `--sign` and `--notarize`, `export --push` and `cache push` and `pull`, `h9x.lock` and `verify`, `doctor` and `fetch`, the C ABI, `--arch` and `--guest-arch`, and `macos-amd64` and `windows-arm64` targets. Each is in design.md, each is independent of the prototype's formats, and each gets its own proposal when it's next.

## Compatibility

- **The POC's command.** `h9x [-o OUT] APPDIR` keeps working as `h9x build`, with a warning. Its environment variables map as under Config, except `H9` and `H9_FLAGS`, which warn and are ignored.
- **The output directory.** The same layout, plus `artifact.json`. Keys change, since they include the architecture and h9x's version, so the first build with the prototype rebuilds every layer once. Runtime layers in `$cache/runtimes` rebuild once too.
- **The cache.** The same root, with new directories. Roots are kept if their key's inputs are unchanged.
- **h9.** The prototype pins a hyper9 commit that has up layers and the Linux fixes the README lists. It needs nothing from h9 that isn't on main. When h9 takes `.plan` ([plan-format](https://github.com/progrium/hyper9/blob/main/design/plan-format.md)), `policy.zig`'s compiler is removed without changing h9x's output.
- **Host tools.** The host no longer needs `curl`, `tar`, or a shell: downloads use `std.http`, and tars are read and written in Zig.

## Security

What the guest can reach is set per phase by the policy table, and `--print` shows it. The changes from the POC are mostly tighter: builds get a registry allowlist instead of an open network, a remote source runs with no host files and no network by default, and secrets reach only build steps and never land in a file h9x writes. Two things are new. A git or tarball source is fetched in a machine allowed to reach that source's host only, and its tree is read-only to every phase but `shell`. A packed executable's policy is sealed in `pack.json`, and the runner verifies the archive's digest before extracting it, so a tampered pack is refused rather than run; the digest isn't a signature, so a pack is as trusted as wherever it came from. h9's sandbox isn't audited, so the untrusted profile is defence in depth, and the docs say so where they describe `run` on a remote source.

## Done criteria

Integration cases are in `tests/*.zig`, run by `zig build integration`, and unit cases by `zig build test`. The examples are Railpack's, from a pinned commit of its repository.

- [ ] `zig build` makes `h9x` and `h9x-runner` on Linux amd64, and `zig build test` passes.
- [ ] `test "every example the POC builds also builds and runs [prototype]"` passes for `go-mod`, `node-npm`, `node-bun`, `node-lts-npm-native-deps`, `python-uv`, `deno-2`, `ruby-latest`, `cpp-cmake`, `gleam`, `elixir-latest`, `rust-rocket`, `zig`, `dotnet-cli`, and `dotnet-api`, under the default build policy.
- [ ] `test "a rebuild with nothing changed takes under a second and rebuilds no layer [prototype]"` passes for `node-npm` and `python-uv`.
- [ ] `test "a second app on the same runtimes shares the runtime layer [prototype]"` passes.
- [ ] `test "plan.zig reads each example's plan.json as plan.sh did [prototype]"` passes, against `plan.sh`'s output kept as fixtures.
- [ ] `h9x run github.com/railwayapp/railpack@REF//examples/node-npm` prints the example's expected output, and a second run plans nothing.
- [ ] `test "a tarball source builds [prototype]"` passes.
- [ ] `test "h9x shell -- node -v runs in the build stage, and the source is writable [prototype]"` passes.
- [ ] `test "--print shows each phase's policy, and a widening flag or h9x.toml line is exit 2 [prototype]"` passes.
- [ ] `test "a build step that connects outside the allowlist fails [prototype]"` passes.
- [ ] `test "a secret reaches the build step and no file h9x writes [prototype]"` passes.
- [ ] `test "--json emits one event per line, ending in result [prototype]"` passes, and `docs/events.md` documents each kind.
- [ ] `test "pack writes the same tar twice, and h9 --archive runs it [prototype]"` passes for `go-mod`.
- [ ] `test "pack --exe runs the app on linux-amd64 with nothing else installed [prototype]"` passes for `go-mod` and `node-npm`, in a clean home directory.
- [ ] `test "pack --target writes a macOS section, a PE section, and the trailer, which --inspect reads [prototype]"` passes, with runners given by `--runner`.
- [ ] A `macos-arm64` executable packed on Linux runs on Apple Silicon.
- [ ] `test "export --oci writes the same digest twice, and its layers match the run's [prototype]"` passes.
- [ ] `h9x export . --docker | docker load` and `docker run` print `node-npm`'s expected output.
- [ ] `test "cache prune --unused removes only what no build names [prototype]"` passes.
- [ ] `test "the POC's h9x -o OUT DIR still works, with a warning [prototype]"` passes.
- [ ] The README describes the prototype, and `docs/output.md`, `docs/events.md`, and `docs/cache.md` document the formats.

## Implementation

1. The skeleton: `build.zig` and `build.zig.zon` on h9, the two executables, `cli.zig` with every subcommand as a stub, the shared types (`Source`, `Plan`, `Layer`, `Artifact`, `Policy`, and `Event`) with their fields, `machine.zig`, and the embedded guest scripts. It lands first, so the parts below build on fixed interfaces.
2. In parallel: the policy and config, the plan reader, the tar and index writer, the executable containers and signer, and the sources and cache.
3. Roots and layers on the plan reader and policy, with `build` working end to end.
4. Packs, the runner, and export, on the tar writer, the containers, and a built artifact.
5. `run`, `shell`, `plan`, and the examples' integration cases; the POC moves to `poc/` and is removed once every example passes.
6. The docs.

## Open issues

- Whether a source's `h9x.toml` may raise `build.memory` or `build.timeout` past the defaults. As written, limits count as widening, so it can't without `--trust`.
- Whether `shell` writes into the source by default, as written, or works on a copy unless `--rw`. design.md leaves this open too.
- Where a remote source's build output goes. As written it's `$cache/builds/KEY`, which `cache prune` cleans, and `-o` puts it elsewhere.
- Whether the runner's extract step should fall back to h9's `.archive` mount for small packs, to skip the disk.
- Whether `run`'s local profile should default to `net disable` too, with `--net` to allow it, for symmetry with remote sources.
