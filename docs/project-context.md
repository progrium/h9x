# h9x: project context

A short brief for anyone (or any agent) picking up h9x. The long-form plan is
[design.md](design.md); the numbers are in [benchmarks.md](benchmarks.md).

## What it is

h9x builds an app from its source into layers that
[h9](https://github.com/progrium/hyper9) runs, using tools that already exist
rather than a builder of its own: Railpack plans, mise installs runtimes,
Wolfi packages make the roots, and every step runs sandboxed in an h9 machine
whose changes land in an h9 up layer. No Docker, no daemon, no root. The
same script works on macOS and Linux because nothing runs on the host's own
OS; the host needs only h9, `curl`, `tar`, and a POSIX shell.

The pitch it's growing toward: **one command that safely runs any repo**,
`h9x run github.com/foo/bar`, with dev shells (`h9x shell`) and agent
sandboxes falling out of the same layers.

## Naming

Decided: **h9x**, as in `npx`. It incubated as h9build, and the code has
been renamed: the script is `h9x`, the variables are `H9X_*`, the guest paths
are `/h9x/...`, and the cache is `$cache/h9x`. h9x warns about leftover
`H9BUILD_*` variables and ignores the old `~/.cache/h9build`. Check Homebrew,
npm, PyPI, and crates.io for the name before a first release.

## Where things are

- `h9x` is the host script (about 420 lines of POSIX sh): bootstrap,
  roots, plan, layers, run.
- `guest/roots.sh`, `guest/plan.sh`, and `guest/build.sh` run inside h9
  machines.
- `README.md` describes how it works and what does and doesn't build.
- `docs/design.md` is the CLI and library design, exported from the live
  design doc (https://claude.ai/artifact/ArF6sxaq1syi7VmiSahJXE).
- `docs/benchmarks.md` has the comparisons with Railpack on Docker and with
  hand-written Dockerfiles.
- History before this repo is in progrium/scratch under `h9build/`. The
  commits came over with it; their PR numbers point at scratch
  (progrium/scratch#18, #20, #25).

## How it builds

1. Bootstrap: Alpine's minirootfs and Railpack's static binary, downloaded
   once. Alpine's `apk` reads Wolfi's repository.
2. Roots: *base* (runs apps, about 40 MB) and *builder* (adds compilers and
   headers), kept in the cache by package set.
3. Plan: `railpack plan` in a machine on the builder root. The plan is kept
   with a key of the source files, Railpack, and `plan.sh`, so a no-change
   rebuild is about half a second.
4. Layers: *runtime* (mise's packages steps, shared between apps in
   `$cache/runtimes`), *deps* (install steps), and *app* (the rest, pruned to
   what the plan deploys). Each is an OCI layer with `.wh.` whiteouts and an
   input key.
5. Run: `OUT/run` stacks the layers read-only over the base root.

## Dependency on h9 (progrium/hyper9)

h9x needs a recent h9 built from progrium/hyper9 main. In particular:

- Up layers ([upper-layers](https://github.com/progrium/hyper9/blob/main/design/upper-layers.md)),
  including progrium/hyper9#254.
- Linux fixes the examples turned up: #257 (lseek/mremap, for rustup and
  `zig build`), #258 (`sched_getparam`, for MSBuild), #263 (epoll on host
  sockets, for NuGet through a proxy), #264 (a signal breaks a pipe read
  waiting behind another, and `getsockname` before `listen`, for cargo's
  jobserver and Kestrel).
- progrium/hyper9#276: `uv sync` hung forever during bytecode compile on the
  native backend (a lost wakeup). Closed by #280; #283 (F\_DUPFD and
  nonblocking pipe reads racing other threads) was still open on Nov 24, 2026.
- Run h9 with `--backend native` or a real hypervisor, never the emulator,
  for builds (`H9_FLAGS=--backend native` on hosts without KVM).

## Status (Nov 24, 2026)

- Builds and runs Railpack's examples for Go, Node (npm, bun, native deps),
  Python (uv), Deno, Ruby 4, C++ (CMake), Gleam, Elixir, Rust, Zig, and .NET,
  on x86\_64 Linux only. arm64 and macOS are untried.
- Doesn't build: older Ruby (needs a source build, which hung), PHP (needs
  FrankenPHP's image), Java (untried).
- Against Railpack on Docker: faster on no-change rebuilds, on a second app
  sharing runtimes, and 37 to 69% smaller; slower cold for Go and C++, and on
  small-change rebuilds. Cold builds are limited by h9's file-creation,
  threading and per-call policy-check costs.

## Next steps

From the design doc's phasing, in order:

1. Surface, still in shell: subcommands `run`, `build`, `shell`, `plan`; git
   and tarball sources; `h9x.toml`; `--json` events. Done when
   `h9x run <git url>` works for every Railpack example that builds today.
2. Tighter builds: registry allowlists (`netallow` derived from the plan),
   secrets by name, `h9x.lock` with Wolfi versions, deterministic layer tars.
3. Outputs: `export` (OCI tarball and push), `pack` (`.h9a`), and `cache`
   prune/push/pull.
4. Zig port: a library on h9's `Machine` API, one static binary with h9
   inside, a small C ABI, and arm64 Linux and macOS releases.
5. Untrusted-code launch, gated on an h9 sandbox audit, the h9 bugs behind
   any failing languages, and cold builds near Railpack's.

Open questions: whether `shell` writes back into the source or is
copy-on-write; whether to depend on Railpack's planner long term or make the
plan format h9x's own; whether packs carry the builder root.

## Working notes

- Builds in a sandbox behind an HTTPS proxy need a Railpack patched to pass
  the proxy to mise (`H9X_RAILPACK`) and `H9_FLAGS="--env
  MISE_GITHUB_ATTESTATIONS=false --env MISE_AQUA_COSIGN=false --env
  MISE_AQUA_SLSA=false"`.
- `sh -n h9x guest/*.sh` is the quick syntax check; a real check is
  building a few Railpack examples (`go-mod`, `node-npm`, `python-uv`) and
  running `OUT/run`.
- h9's sandbox isn't audited. Don't pitch running untrusted code as safe yet.
