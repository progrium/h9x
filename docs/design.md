# h9x as a standalone CLI and library

Nov 23, 2026 · Jeff Lindsay. Exported from the design doc at https://claude.ai/artifact/ArF6sxaq1syi7VmiSahJXE; that doc is the live copy.

## Summary

h9x should be pitched as **one command that safely runs any repo**: `h9x run github.com/foo/bar` detects the language, builds it in sandboxed, cached layers, and runs it, with no Docker, daemon, or root. Dev shells (`h9x shell`) and agent sandboxes fall out of the same layers, so those three lead; OCI export, single-file packs, and cache sharing are follow-ons.

The main recommendations:

- **Seven commands:** `run`, `build`, `shell`, `plan`, `export`, `pack`, `cache`. `run` and `shell` build implicitly, so most people never type `build`.
- **Don't invent a build config.** Build overrides stay in Railpack's own `railpack.json`. h9x adds one small `h9x.toml` for roots, limits, and sandbox policy, and a committed `h9x.lock` for reproducibility.
- **Sandbox policy is h9's plan format.** Each phase (plan, build, run, shell) gets a default h9 plan, which the user can print and narrow. Builds get registry-only network by default.
- **Write the library in Zig, on h9's Zig library**, and ship one static binary with h9 inside. Railpack, mise, and apk keep running as guest Linux binaries. A C ABI with JSON in and out covers Go, Python, and Node callers.
- **Be honest about "safe".** h9's sandbox hasn't been audited. The untrusted-code pitch should wait on that audit, and on the build failures and cold-build speed listed under Gaps.

## Naming

**Decided: h9x.** It reads like `npx` (`h9x github.com/foo/bar`), keeps the h9 family name, and no tool by that name turned up in a quick search. The ranking below is kept for the record. Before the first release, check Homebrew, npm, PyPI, and crates.io for the name.

| Rank | Name | For | Against | Clash found |
| --- | --- | --- | --- | --- |
| 1 | build9 | Short, reads as a 9front-family tool, and works as a library name (`build9.build(...)`). It's not tied to h9's name if h9 is renamed. | Says "build" while the pitch is "run". That's fine: `docker build` and `docker run` coexist. | None in a quick search |
| 2 | h9x | `h9x github.com/foo/bar` reads like `npx`, and the run story is the headline. | Cryptic on its own. Better as an alias of `build9 run` than as the project name. | None in a quick search |
| 3 | h9build | Descriptive, and it was the name it incubated under. | Long to type, and ties the tool to h9's brand. | None |
| 4 | `h9 build` (a subcommand) | No new name. | h9 is a flags-only runtime, and folding Railpack, mise, and OCI export into it would bloat it. | n/a |

Ruled out: **run9** ([breezewish/run9-cli](https://pkg.go.dev/github.com/breezewish/run9-cli) exists), **anyrun** (a popular Wayland launcher, [anyrun-org/anyrun](https://awesome.ecosyste.ms/projects/github.com%2Fanyrun-org%2Fanyrun)), **hatch** (Python's packaging tool), and **layup** (too generic to own).

## Target use cases, ranked

The top three share one engine (plan, build layers, run them in an h9 sandbox), so they should ship together as the launch story. Ranks weigh how many people have the problem, how well h9x beats the alternatives, and how close today's scripts are.

| Rank | Use case | Who | Why h9x wins | Readiness today |
| --- | --- | --- | --- | --- |
| 1 | Run any repo: `h9x run github.com/foo/bar` | Developers trying a project, people following a README | No Docker, daemon, root, or toolchain install. Should work the same on a Mac and Linux, though only x86\_64 Linux is tried. A second app on the same runtimes skips installing them. | Close. Local dirs work, but there's no remote source, and older Ruby, PHP, and Java don't build yet. |
| 2 | Dev shells: `h9x shell` | Contributors, onboarding | The project's exact toolchain from the same cached layers as the build. It's a devcontainer without Docker Desktop. | Not built. The layers exist, so it's mostly a new run mode. |
| 3 | Agent and untrusted-code sandbox | AI coding agents, CI on fork PRs, code review | A per-phase policy (no host files, registry-only network, limits, timeouts) that's printable and diffable. Machine-readable events. | The engine is there, but the h9 sandbox isn't audited and builds have open outbound network. |
| 4 | OCI export: `h9x export` | CI, teams on Kubernetes or a PaaS | A daemonless buildpacks alternative whose images are 37 to 69% smaller than Railpack's on Docker. | Layers are already OCI layers. It needs a config, manifest, gzip, and push. |
| 5 | Single-file packs: `h9x pack` | Shipping CLIs and demos, the browser host | One file runs anywhere h9 runs, browser included. | Needs the base root folded in and an `.h9a` writer. |
| 6 | Shared build cache | Teams, CI fleets | Input-keyed layers can move between machines with no BuildKit. | Keys exist. Needs push and pull, and keys that don't depend on the host path. |
| 7 | Reproducibility checks: `h9x verify` | Release engineers | A pinned plan plus content-keyed layers let you rebuild and diff. | Needs a lockfile and deterministic tar output (mtimes, ordering). |
| 8 | Embedding as a library | A PaaS, an editor's "run this project" button, uitree's app builder | Plan, build, and run as calls, not shell-outs. | Needs the Zig port (see Library API). |

## Commands

Seven subcommands, each taking a SOURCE that defaults to `.`. A SOURCE is a directory, a git URL with an optional `@ref` and `//subdir`, or a tarball URL. `run`, `shell`, `export`, and `pack` build first, reusing any cached layer whose key matches, so `build` is mostly for CI and scripting.

| Command | Does | Today |
| --- | --- | --- |
| `run` | Build if needed, then run the start command or the given command | `h9x DIR && DIR.h9/run` |
| `build` | Plan and build the layers into an output directory | `h9x -o OUT DIR` |
| `shell` | A shell in the build environment, with the source mounted | Not built |
| `plan` | Print or explain the plan without building | Inside the build only |
| `export` | Write or push an OCI image | Not built |
| `pack` | Write one self-contained `.h9a` file | Not built |
| `cache` | List, size, prune, push, and pull cached roots and layers | Not built |

### run

```sh
h9x run github.com/railwayapp/railpack//examples/node-npm
h9x run . -- npm test            # replace the start command
h9x run gh:foo/bar@v1.2 --net=none --timeout 5m
h9x run . --listen 8080          # a server: allow it to listen on one port
h9x run . --mount ./data:/data   # share a host dir, read-write
h9x run . --print                # show the sandbox policy and exit
```

Remote sources are fetched into the cache by content, so a second run of the same commit plans nothing. Unless you pass `--trust`, a remote source runs under the untrusted profile (see Sandbox).

### build

```sh
h9x build . -o app.h9
h9x build . --json > events.ndjson   # step events for CI and agents
h9x build . --replan                 # re-run Railpack's planner
```

The output keeps today's layout (`layers/`, `layers.txt`, `env`, `plan.json`, `run`). That layout becomes a documented contract, so other tools can consume a build without the library.

### shell

```sh
h9x shell                 # builder root + runtime + deps, source at /app read-write
h9x shell -- npm test     # one command, then exit
h9x shell --stage run     # the exact run image, for debugging start failures
```

The shell stacks the same layers the build made, plus a writable layer for anything you install, thrown away at exit unless you pass `--keep`. The source is the one host path that's writable, so edits land in your checkout. Package-manager caches point at the build's `cache/`, so `npm install` in the shell is warm.

### plan

```sh
h9x plan                 # a readable summary: language, versions, steps, layers, deploy paths
h9x plan --json          # Railpack's plan.json, as kept
h9x plan --explain       # which file decided each choice (.nvmrc, package.json engines)
h9x plan --lock          # write h9x.lock
```

### export

```sh
h9x export . --oci app.tar                  # an OCI image layout tarball
h9x export . --push ghcr.io/me/app:1.0      # straight to a registry, no daemon
h9x export . --docker | docker load
```

The image is the base root as one layer, then the run layers from `layers.txt`, with the plan's env and start command in its config.

### pack

```sh
h9x pack . -o app.h9a
h9 --archive app.h9a          # or open it in the browser host
```

A pack is the base root and run layers flattened into one archive, with the env and start command in a header that h9 reads. It's the uitree `pack` story for any app.

### cache

```sh
h9x cache ls                         # roots, runtimes, sources, with sizes and last use
h9x cache prune --unused 30d
h9x cache push s3://bucket/h9x   # share layers by key
h9x cache pull s3://bucket/h9x
```

Two helpers round it out: `h9x doctor` checks h9, its backends, and the network (today's proxy pain), and `h9x verify` rebuilds from the lockfile and diffs the layer digests.

## Config and overrides

h9x should add as little config as it can. Build behaviour already has a home in Railpack, and sandbox behaviour already has one in h9's plan format, so h9x's own file only covers what neither of those does.

| What | Where | Example |
| --- | --- | --- |
| Build steps, packages, start command, deploy paths | `railpack.json`, Railpack's own config | `{"deploy": {"startCommand": "node server.js"}}` |
| Runtime versions | `mise.toml`, `.nvmrc`, `.python-version` and the like, as Railpack reads them | `node = "22"` |
| Roots, limits, build network | `h9x.toml` | below |
| Sandbox policy per phase | h9 plan lines, in `h9x.toml` or a `.plan` file | `netallow *.npmjs.org:443` |
| Pinned resolution | `h9x.lock`, generated | the plan, root package versions, layer keys |

```toml
# h9x.toml
[roots]
base  = ["libjemalloc"]          # more Wolfi packages at run time
build = ["protobuf-dev"]         # more at build time

[build]
memory = "4G"
net    = "registries"            # none | registries | outbound
netallow = ["tcp!api.example.com!443"]
secrets  = ["NPM_TOKEN"]         # passed to build steps only, never kept in a layer

[run]
policy = """
net disable
write overlay
memory 1G
"""
```

Precedence runs from strongest to weakest: command-line flags, then `H9X_*` variables, then `h9x.toml`, then `railpack.json` and the language files, then Railpack's detection. One rule from h9 carries over: a flag or variable can only narrow a policy the file sets, never widen it. Widening needs an explicit `--trust` or an edit to the file, so a repo can't loosen your sandbox and a script can't do it by accident.

Today's environment variables map across directly: `H9X_MEMORY` becomes `build.memory`, `H9X_BASE_PACKAGES` becomes `roots.base`, `H9X_REPLAN` becomes `--replan`, and `H9X_RUBY_COMPILE` belongs in `railpack.json` or `mise.toml` rather than in h9x at all. The lockfile is today's kept `plan.json` and `plan.key`, promoted to a committed file with the Wolfi package versions added, since those float today.

## Sandbox and permissions

Every phase runs in its own h9 machine with a default policy written as h9 plan lines ([plan-format](https://github.com/progrium/hyper9/blob/main/design/plan-format.md)), and `--print` shows the exact policy before anything runs. The defaults are as tight as each phase allows.

| Phase | Host files | Writes | Network | Limits |
| --- | --- | --- | --- | --- |
| plan | Source, read-only | None | Version lookups only (mise, GitHub releases) | 2 GB, 2 min |
| build | Source, read-only | The new layer and the package caches | Registries for the plan's ecosystems | 4 GB, 30 min |
| run, local source | The cwd, if you pass `--mount` | Overlay, thrown away | Outbound, `--listen` to serve | 1 GB |
| run, remote source (untrusted) | None | Ephemeral, in memory | None unless `--net` or `--listen` | 1 GB, 10 min |
| shell | The source, read-write | The source, and a scratch layer | Registries | 4 GB |

A few rules hold across phases:

- **No host environment.** h9 already never imports it. Secrets come in by name through `--secret` or `build.secrets`, and only the steps that need them see them. Longer term they should go through h9's [credential helpers](https://github.com/progrium/hyper9/blob/main/design/credential-helpers.md) so a token never sits in a file inside the guest.
- **Registries as an allowlist.** The plan names its ecosystems, so h9x can derive `netallow` lines: `registry.npmjs.org`, `pypi.org` and `files.pythonhosted.org`, `rubygems.org`, `proxy.golang.org`, `packages.wolfi.dev`, and GitHub for mise's downloads. That closes the open outbound network builds have today.
- **Trust is explicit.** `--trust` (or a trusted-sources list in the user config) switches a remote source to the local defaults. A repo's own `h9x.toml` can narrow but never widen, as in Config.
- **Agents get structure.** `--json` emits one event per step (start, output, exit, layer key, cache hit) and a final result with the exit code, so an agent can tell a build failure from a test failure without scraping logs. Exit codes follow h9's: 124 is a timeout and 125 is a setup error.

The caveat has to be stated plainly. h9's README says its sandbox hasn't been audited and shouldn't be trusted with malicious code. Until that changes, the untrusted profile is defence in depth on top of a normal OS account, and the docs should say so. The "safe to run any repo" pitch should ship only after the audit.

## Library API and language

**Write it in Zig, on h9's Zig library, and keep every third-party tool as a guest.** h9 is already a Zig library with a `Machine` API ([docs/embedding.md](https://github.com/progrium/hyper9/blob/main/docs/embedding.md)), so a Zig h9x drives machines in-process instead of shelling out to an `h9` binary. That gives one static binary, one process to sign on macOS, and a path to the browser host. Railpack, mise, and apk keep running inside h9 as Linux binaries, as they do now, so h9x never links Go or Rust code. The plan is the seam: Railpack writes `plan.json`, and Zig reads it.

|  | Zig | Go |
| --- | --- | --- |
| Talking to h9 | In-process, through `Machine` | Exec the `h9` binary, or cgo into the Zig library |
| Railpack | Run as a guest, as today | Could import Railpack's planner directly |
| OCI and registries | Write by hand: tar, gzip, sha256, and JSON are in Zig's std. Pushing is plain HTTP, or run `crane` as a guest. | go-containerregistry does it all |
| Shipping | One static binary with h9 inside | Two binaries, or cgo builds per platform |
| Browser | Can share code with h9's browser host | No |
| Fit with the project's direction | Same language and build as h9 | A second toolchain |

Go's real advantages are the registry client and importing Railpack. Running `crane` (or `regctl`) as a guest covers the first, and the guest approach already covers the second. Neither outweighs a single binary that embeds h9.

The library has four steps, and each returns a value the next one takes:

```zig
const h9x = @import("h9x");

var builder = try h9x.Builder.init(gpa, io, .{
    .cache_dir = cache,                 // roots, runtimes, sources, layers
    .machine = .{ .backend = .auto },   // passed through to h9's Machine.Options
    .on_event = report,                 // step start, output, exit, cache hit
});
defer builder.deinit();

const src  = try builder.source(.{ .git = "https://github.com/foo/bar", .ref = "v1.2" });
const plan = try builder.plan(src, .{ .lock = lockfile });   // Railpack in a guest
const art  = try builder.build(plan, .{ .out_dir = "bar.h9" });

// The artifact is the layer stack, env, and start command. Run it, open a shell, or write it out.
var m = try art.machine(.{ .stage = .run, .policy = h9x.Policy.untrusted });
const status = try m.run(&.{});
try art.exportOci(file.writer(), .{});
try art.pack(file.writer());
```

The main types are `Source` (a directory, git ref, or tarball, with its content hash), `Plan` (Railpack's plan plus the layer split and keys), `Layer` (name, key, digest, path), `Artifact` (the stacked layers, env, and start command), and `Policy` (h9 plan text, so it's printable and diffable).

Other languages get two ways in. The simpler is the output directory and the `--json` event stream, which are a stable contract and enough for a PaaS or an editor. The other is a small C ABI (`h9x_build`, `h9x_run`, `h9x_export`) that takes and returns JSON, so Go, Python, and Node bindings stay thin and don't track Zig types.

## Distribution

Ship one static binary per OS and architecture, with h9 linked in and the guest scripts embedded. Everything else downloads into the cache on first use, pinned by version and sha256 in the binary: Alpine's minirootfs, Railpack's release, and the Wolfi packages for the roots.

- **Channels:** GitHub releases, a Homebrew tap, and an install script. A container image is pointless for a tool whose job is avoiding Docker.
- **macOS:** the binary needs the Hypervisor.framework entitlement and signing, which h9's build already does. Releases should be notarized.
- **Offline and CI:** `h9x fetch` warms the cache, and `h9x cache export` writes it to a tarball that a CI cache step can restore.
- **Versioning:** a release pins Railpack, Alpine, and the root package set, so two people on the same release plan the same way. Bumping Railpack is a release, since its plans change.
- **Platforms:** Linux x86\_64 is the only one tried. arm64 Linux and Apple Silicon need a test pass before release, and Windows waits on h9's Linux personality there.

## Gaps against today's scripts

Today h9x is a POSIX shell script of about 430 lines plus three guest scripts, with one command, `h9x [-o OUT] APPDIR`. The engine is sound: plan caching, shared runtime layers, and pruning all work. What's missing is mostly the surface around it, plus a few h9 bugs.

| Gap | Blocks | Owner |
| --- | --- | --- |
| Older Ruby versions need a source build, which hung in h9 | run any repo | h9 |
| Cold builds are slower than Docker, because of h9's file-creation and threading costs | run any repo, CI | h9 (Jeff investigating) |
| uv's bytecode compile sometimes panics or hangs | Python | h9 (progrium/hyper9#283) |
| h9's sandbox isn't audited | the untrusted pitch | h9 |
| Build steps have open outbound network | agent sandbox | h9x: derive `netallow` |
| Only local directories, no git or tarball sources | run any repo | h9x |
| No subcommands, `shell`, `plan` command, or `--json` events | dev shells, agents | h9x |
| Config is environment variables only, and there's no lockfile. Wolfi versions float. | reproducibility | h9x |
| Layers aren't deterministic tars (mtimes, ordering), and there's no image config, manifest, or push | export, verify | h9x |
| The base root lives only in the cache, so the output isn't self-contained | pack, export | h9x |
| No cache pruning or sharing. Unused runtimes stay forever. | cache | h9x |
| Every source file is hashed on each build | large repos | h9x: hash by mtime and size first |
| Dev dependencies aren't pruned | image size | Railpack's `RAILPACK_PRUNE_DEPS` |
| PHP needs FrankenPHP's image, and Java is untried | coverage | h9x |
| arm64 and macOS are untried | distribution | h9x, h9 |
| Proxied networks need a patched Railpack | `doctor`, CI | upstream a Railpack fix |

## Phasing and open questions

Try the command surface in shell first, where it's cheap to change, and port to Zig once it settles. Each phase ends with something usable.

1. **Surface, in shell.** Subcommands `run`, `build`, `shell`, and `plan`, git and tarball sources, `h9x.toml`, and `--json` events. Done when `h9x run <git url>` works for every Railpack example that builds today.
2. **Tighter builds.** Registry allowlists, secrets by name, the lockfile with Wolfi versions, and deterministic layer tars. Done when builds pass with `--net=registries` and `verify` reproduces a layer digest.
3. **Outputs.** `export` (OCI tarball and push), `pack`, and `cache` prune, push, and pull.
4. **Zig port.** The library on h9's `Machine`, one static binary, the C ABI, and Linux arm64 and macOS releases.
5. **Untrusted-code launch.** Gated on the h9 sandbox audit, the h9 bugs behind any failing languages, and cold builds near Railpack's times.

Open questions:

- [x] Name: decided, h9x (see Naming)
- [x] Where it lives: its own repo, progrium/h9x (moved from progrium/scratch)
- [ ] Should `shell` write back into the source by default, or copy-on-write unless `--rw`?
- [ ] Is depending on Railpack's planner long-term acceptable, or should the plan format become h9x's own with Railpack as one producer?
- [ ] Should packs carry the builder root too, so a pack can rebuild itself?
