# The command line

`h9x` builds an app from its source into layers that [h9](https://github.com/progrium/hyper9) runs, then runs it, opens a shell in it, or writes it out as a pack, executables, or an OCI image. This is the contract for its commands, sources, config, and policy. [design/prototype.md](../design/prototype.md) has the reasons.

```sh
h9x run [SOURCE] [--trust] [--listen PORT] [--mount HOST:GUEST[:ro]] [--net MODE]
        [--timeout D] [--print] [-- CMD ARGS...]
h9x build [SOURCE] [-o OUT] [--replan] [--secret NAME] [--json]
h9x shell [SOURCE] [--stage build|run] [--keep[=DIR]] [-- CMD ARGS...]
h9x plan [SOURCE] [--replan] [--json]
h9x pack [SOURCE|OUT.h9] [-o FILE|DIR] [--exe] [--target LIST|all]
         [--mount HOST:GUEST[:ro]] [--runner [TARGET=]FILE] [--no-debug]
h9x pack --inspect FILE
h9x export [SOURCE|OUT.h9] (--oci FILE | --docker)
h9x cache ls
h9x cache prune [--unused DURATION] [--dry-run]
h9x --help | --version
```

Every command takes `--json` (events as NDJSON, [events.md](events.md)), `--print` (the policies it would use, and nothing started), and `--help`. `build`, `run`, `shell`, `pack`, and `export` take `--secret NAME`, repeatable. A flag's value can follow it or come after `=`: `--timeout 5m` or `--timeout=5m`. Durations are a number and `s`, `m`, `h`, or `d`; sizes are a number and `K`, `M`, or `G`, or bytes.

## Commands

**`run`** builds SOURCE, as `build` does, then runs the start command on the run stage: the base root with the run layers stacked over it read-only, in `/app`, with the build's `env`. With `-- CMD ARGS...`, it runs CMD instead of the start command, found on the run stage's `PATH`. Writes go to an overlay that's thrown away at exit. The run's exit code is the program's. A remote source runs untrusted (below) unless `--trust` is given or the user's config trusts it.

- `--mount HOST:GUEST[:ro]` shares a host directory at GUEST, read-write unless `:ro`. An untrusted run refuses it, exit 2.
- `--net disable|outbound|enable` sets the network mode (`none` is `disable`), and `--listen PORT` asks for `enable`, which lets the app listen. `--listen` with another `--net` is exit 2.
- `--timeout D` ends the run after D, exit 124. It only narrows: a remote source's 10m can't be raised without `--trust`.

SOURCE may also be a build's output directory, one with an `artifact.json`, which runs as it is, trusted, without building.

**`build`** writes SOURCE's build to its output directory ([output.md](output.md)): `NAME.h9` in the current directory for a directory source, `$cache/builds/KEY` for a git or tarball source, or `-o OUT`. It reuses every layer whose key matches, so a build with nothing changed builds nothing. `--replan` runs Railpack's planner even when the source hasn't changed. On success, the `result` event's `out` is the output directory.

**`shell`** builds SOURCE, then runs `sh` or `CMD ARGS...` on the build stage: the builder root, the runtime and deps layers read-only, every step's variables and `PATH`, and the package managers' caches pointed at the output's `cache/`, in `/app`. A directory source is at `/app` read-write, over what the deps layer put there (`node_modules`, `.venv`), so edits and new files land in the source. Everything else the shell changes lands in a scratch layer, removed at exit unless `--keep` (kept where it was made, `OUT/scratch-ID`) or `--keep=DIR` (moved to DIR). A remote source's tree is read-only, and edits to it land in the scratch layer. `--stage run` gives the run stage instead, as `run` starts it, for debugging a start command; `--keep` doesn't apply to it.

**`plan`** plans SOURCE, or reads the plan kept in its output directory, and prints a summary: the provider, the versions Railpack resolved, each step and its layer, the deploy paths, the apt packages and their Wolfi names, and the start command. `--json` prints `plan.json` as kept, on stdout. It makes the builder root Railpack runs on, and builds no layer.

**`pack`** and **`export`** take a build's output directory, or build SOURCE first. [pack.md](pack.md) specifies what they write. `pack --print` prints the policy a pack would seal.

**`cache ls`** lists the cache's entries ([cache.md](cache.md)) with their sizes and last use, and with `--json` writes them as one JSON object on stdout. **`cache prune`** removes what hasn't been used in `--unused` (default 30d) and no build in the cache names; `--dry-run` lists it instead.

**`h9x [-o OUT] DIR`**, with no command, is the proof of concept's form: `h9x build DIR [-o OUT]`, with a warning that it's deprecated.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success, or the program `run` or `shell` ran exited with an empty status |
| 1 | A build step failed, or Railpack made no steps; `pack --inspect` found no pack or one that doesn't check out |
| 2 | A usage, config, or policy error, such as a widening flag |
| 124 | A timeout, as h9's |
| 125 | Setup failed: a download, a root, or a machine h9 couldn't start |
| other | For `run` and `shell`, the program's exit status, as h9 maps it |

A `log` event before the `result` says why a command failed.

## Sources

A SOURCE is a directory, a git repository, or a tarball. Anything that isn't one of the URL forms below is a directory, and a directory that exists wins over `github.com/OWNER/REPO`.

| Form | Example |
| --- | --- |
| A directory | `.`, `./app`, `/home/me/app` |
| Git over HTTPS | `https://github.com/OWNER/REPO`, `https://host/path.git` |
| Git over SSH, fetched over HTTPS | `git@github.com:OWNER/REPO` |
| GitHub | `github.com/OWNER/REPO`, `gh:OWNER/REPO` |
| A tarball | `https://host/app.tar.gz`, `.tgz`, or `.tar` |

A git source takes `@REF` (a branch, tag, or full commit) and either kind of remote source takes `//SUBDIR`: `gh:railwayapp/railpack@v0.43.0//examples/node-npm`.

- **Directories** are used in place, read-only to every machine but `shell`'s. Their content hash covers every file, and rehashes only the files whose size or mtime changed since the last build.
- **Git** sources are cloned in a machine on the builder root into `$cache/sources/git/`, keyed by the URL, and the ref's commit is checked out into `$cache/sources/tree/COMMIT`, which is never written again, so a second build of the same commit plans nothing.
- **Tarballs** are downloaded in a machine and unpacked into `$cache/sources/tree/SHA256`, keyed by the download's digest. A tarball of one top-level directory, as GitHub's archives are, is that directory, so `//SUBDIR` is relative to it.

Git and tarball sources are remote, and run untrusted.

## Config

h9x's own config is `h9x.toml`, read from the source's root, and `~/.config/h9x/config.toml` (`$XDG_CONFIG_HOME/h9x/config.toml`) for the user's defaults. Build steps, the start command, and deploy paths stay in Railpack's `railpack.json`, and runtime versions in the languages' own files (`mise.toml`, `.nvmrc`, `.python-version`).

```toml
[roots]
base  = ["libjemalloc"]          # more Wolfi packages at run time
build = ["protobuf-dev"]         # more at build time

[build]
memory   = "4G"
timeout  = "30m"
net      = "registries"          # none | registries | outbound | enable
netallow = ["tcp!api.example.com!443"]
secrets  = ["NPM_TOKEN"]         # passed to build steps only

[run]
policy = """
net disable
memory 1G
"""
trusted = ["gh:me/"]             # the user's config only: remote sources run trusted

[pack]
mount   = [".:/work"]
targets = ["linux-amd64", "windows-amd64"]   # or ["all"]
```

| Key | Type | Meaning |
| --- | --- | --- |
| `roots.base`, `roots.build` | strings | Wolfi packages added to the base or builder root |
| `build.memory`, `build.timeout` | size, duration | The build and shell machines' limits |
| `build.net` | string | The build and shell network: `none`, `registries` (`enable`, with the registry allowlist), `outbound`, or `enable` |
| `build.netallow` | strings | Patterns added to the build and shell allowlist: `tcp!HOST!PORT`, `HOST:PORT`, or `HOST` (port 443) |
| `build.secrets` | strings | Host variables passed to build steps only |
| `run.policy` | string | Policy lines (below) laid over the run's |
| `run.trusted` | strings | Prefixes of a SOURCE, or of the URL it's fetched from, that run trusted, as `--trust` does |
| `pack.mount` | strings | `HOST:GUEST[:ro]` mounts sealed into a pack, when `pack` has no `--mount` |
| `pack.targets` | strings | `--target`'s default for `pack --exe` |

`toml.zig` reads the subset these need: tables, strings, integers, booleans, arrays of strings, and multi-line basic strings. An unknown table or key, a value of the wrong type, or TOML outside the subset is exit 2, naming the file and line.

### Precedence

From strongest to weakest: flags, then `H9X_*` variables, then the source's `h9x.toml`, then the user's config, then Railpack's own files and detection. For policy, precedence also decides who may widen a phase's defaults: the user's config may, as may a trusted source's `h9x.toml`. An untrusted source's file, a variable, and a flag only narrow, and one that would widen is exit 2. `run`'s `--net` and `--listen` are the exception, and set the mode as given.

### Variables

| Variable | Meaning |
| --- | --- |
| `H9X_CACHE` | The cache directory. Default `${XDG_CACHE_HOME:-~/.cache}/h9x` |
| `H9X_BACKEND` | h9's backend for every machine: `auto`, `kvm`, `hvf`, `whp`, `native`, or `emulator` |
| `H9X_MEMORY` | `build.memory`; only narrows |
| `H9X_BASE_PACKAGES`, `H9X_BUILD_PACKAGES` | `roots.base` and `roots.build`, space-separated |
| `H9X_REPLAN=1` | `--replan` |
| `H9X_RAILPACK` | A Railpack binary to plan with instead of the pinned release |
| `H9X_RUBY_COMPILE=1` | Build Ruby from source rather than mise's precompiled builds |
| `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY` | Used for h9x's downloads, and `HTTPS_PROXY` is passed into build machines, whose allowlist then includes it |
| `SSL_CERT_FILE` | A CA bundle, copied into the cache and passed into machines as `SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`, and `GIT_SSL_CAINFO` |
| `MISE_GITHUB_ATTESTATIONS`, `MISE_AQUA_COSIGN`, `MISE_AQUA_SLSA`, `MISE_AQUA_MINISIGN`, `MISE_AQUA_GITHUB_ATTESTATIONS` | Passed to build machines when set |

`H9` and `H9_FLAGS`, from the proof of concept, and `H9BUILD_*`, from h9x's earlier name, are ignored with a warning. Machines never see the host's environment otherwise.

## Policy

A machine's policy is h9 plan text ([plan-format](https://github.com/progrium/hyper9/blob/main/design/plan-format.md)), one line each, with `#` comments, rc's quoting, and `;` or a newline between lines:

| Line | Meaning |
| --- | --- |
| `dir ro\|rw\|up SRC DST` | A host directory at DST: `#L` (the Linux root's stack) or a guest path under it |
| `tmp DST` | An empty tree in memory |
| `net disable\|outbound\|enable` | No network, outbound connections only, or connections and listens |
| `netallow PATTERN...` | The only hosts the network reaches; none means any |
| `write ro\|overlay\|rw` | Where writes go |
| `memory SIZE`, `pids N`, `timeout D` | Limits |
| `env NAME=VALUE` | A variable |
| `cwd PATH` | The working directory |
| `run PROGRAM ARGS...` | What runs |

The defaults per phase:

| Phase | Mounts | `net` | Limits |
| --- | --- | --- | --- |
| fetch | Builder root; the source's work directory writable | `outbound` | `memory 1G`, `timeout 10m` |
| root | Alpine's root; the new root as the up layer | `outbound` | `memory 2G`, `timeout 10m` |
| plan | Builder root; source read-only | `outbound` | `memory 2G`, `timeout 2m` |
| build | Builder root and lower layers read-only; the new layer `up` | `enable` | `memory 4G`, `timeout 30m` |
| run, trusted | Base root and run layers read-only; `--mount`s; writes to a discarded overlay | `outbound`, `enable` with `--listen` | `memory 1G` |
| run, untrusted | Base root and run layers read-only; nothing from the host; writes to a discarded overlay | `disable`, unless `--net` or `--listen` | `memory 1G`, `timeout 10m` |
| shell | Builder root, runtime and deps layers; the source at `/app`; a scratch layer `up` | `enable` | `memory 4G` |

Each phase that reaches registries has an allowlist: the plan's ecosystems' registries for build and shell, the version hosts for plan, Wolfi's for root, and the source's host for fetch. Until h9 matches host names for a Linux guest that does its own DNS, those phases run with no allowlist (`policy.open_builds`), and `--print` shows none.

Secrets, from `build.secrets` or `--secret NAME`, are read from the host's environment and reach build steps only, as `env` lines. They're never in a layer's key, `plan.json`, `env`, `artifact.json`, or `--print`'s output, which shows `env NAME=…`.

### --print

`--print` on `build`, `plan`, `run`, `shell`, and `pack` writes the policy of each machine the command would start, each after a `# PHASE, TRUST` line, and exits without starting one. With `--json`, each is a `policy` event. It fetches nothing and builds nothing, so what a build would decide is shown by where it would be: the roots for the default package sets, a remote source's tree as `$cache/sources/tree/COMMIT`, a remote build as `$cache/builds/KEY`, and the runtime layer as `$cache/runtimes/KEY`. A remote source's own `h9x.toml` isn't known before it's fetched, so it isn't applied; it can only narrow. When the build's output already exists, `run --print` shows its real layers. `shell`'s source and output directory are bound into the machine outside the policy's lines, and `--print` shows those as comments.

## Untrusted runs

h9's sandbox hasn't been audited, and its README says it shouldn't be trusted with malicious code. The untrusted profile is defence in depth on top of a normal OS account, not a guarantee.
