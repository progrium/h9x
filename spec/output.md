# The output directory

`h9x build` writes an app's build to an output directory: `NAME.h9` in the current directory for a directory source, `$cache/builds/KEY` for a git or tarball source, or the directory `-o` names. `run`, `shell`, `pack`, and `export` build into the same place first. The directory is a contract: a tool that wants to run, pack, or inspect a build can read it without h9x's library, starting from `artifact.json`.

```
myapp.h9/
  artifact.json          everything a consumer needs, in one file
  layers.txt             the layers the run stacks, bottom first
  env                    the run environment
  run                    runs the app: h9x run on this directory
  layers/runtime         a link to $cache/runtimes/KEY: what the plan's packages steps changed (mise's runtimes)
  layers/deps/           what its install steps changed: node_modules, a venv, gems
  layers/app/            what its build steps changed, pruned to what the plan deploys
  layers/deps.key        each built layer's chained key
  layers/app.key
  plan.json, info.json   Railpack's plan and its info, as Railpack wrote them
  plan.key               the key they were made under
  steps.txt, keys.txt, shared.txt, deploy.txt, apt-build.txt, apt-runtime.txt
                         the plan as text, for build.sh
  cache/                 per-app package manager caches, kept between builds
```

`$cache` is h9x's cache directory: `$H9X_CACHE`, or else `${XDG_CACHE_HOME:-~/.cache}/h9x` ([cache.md](cache.md)).

## artifact.json

```json
{
  "version": 1,
  "arch": "amd64",
  "base": {
    "path": "$cache/roots/base-d6db79adad4b5d8e",
    "packages": ["wolfi-baselayout", "glibc", "ld-linux", "libgcc", "libstdc++", "libssl3", "zlib", "ca-certificates-bundle", "tzdata", "busybox", "bash"]
  },
  "layers": [
    {"name": "runtime", "key": "9aa944058785c652", "path": "$cache/runtimes/9aa944058785c652"},
    {"name": "deps", "key": "1f0e…", "path": "layers/deps"},
    {"name": "app", "key": "5e10…", "path": "layers/app"}
  ],
  "env": ["NODE_ENV=production", "H9X_START=node server.js", "PATH=/mise/installs/node/22.21.1/bin:/usr/local/bin:/usr/bin:/bin"],
  "start": "node server.js",
  "cwd": "/app"
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `version` | number | The format's version, 1. A reader refuses a version it doesn't know, and ignores fields it doesn't know. |
| `arch` | string | The guest architecture the layers hold binaries for: `amd64` or `arm64`. |
| `base.path` | string | The base root the run starts from. |
| `base.packages` | strings | The Wolfi packages it was made from, the plan's runtime apt packages included. A package that's a list of alternatives, `a\|b`, is written as given: roots.sh installed the first one the repository had. |
| `layers` | objects | The layers the run stacks over the base root, bottom first, as in `layers.txt`: each one's `name`, its chained `key`, and its `path`. |
| `env` | strings | The run environment, as `NAME=VALUE`, as in `env`. |
| `start` | string or null | The plan's start command, or null if it has none. |
| `cwd` | string | Where the run starts: `/app`. |

A path is `$cache/...` for something in the cache, relative for something in the output directory, and absolute otherwise. A layer that's in neither isn't written by h9x today, but a reader takes an absolute path as it is.

## Running a build

To run a build without h9x, stack each layer read-only over the base root, in order, as the Linux root, give the run somewhere to write (a discarded overlay), set `env`, and run the start command with `/bin/sh -c` in `cwd`. With h9's CLI, for the artifact above:

```sh
h9 --dir "$cache/roots/base-d6db79adad4b5d8e:#L" \
   --dir "$cache/runtimes/9aa944058785c652:#L" \
   --dir myapp.h9/layers/deps:#L --dir myapp.h9/layers/app:#L \
   --env NODE_ENV=production --env 'H9X_START=node server.js' --env PATH=… \
   /bin/sh -c 'cd /app && exec sh -c "$H9X_START"'
```

`run` does this through `h9x run`, with the run phase's policy, and passes its arguments as the command to run instead of the start command.

## The layers

Each layer is a directory in OCI's layer form: the files the layer's steps added or changed, and a `.wh.NAME` file for each one they removed from a layer below. h9 wrote it as the up layer of the machine that built it ([upper-layers](https://github.com/progrium/hyper9/blob/main/design/upper-layers.md)).

- **runtime** is what the plan's `packages:` steps changed: mise's runtimes under `/mise`, and what a step put beside them (Ubuntu's libcrypto for Hex's Erlang, under `/usr/lib`). It's shared between apps in `$cache/runtimes/KEY`, and `layers/runtime` links to it. The files its steps copy from the source (a `mise.toml`) are taken out of it, and the deps layer makes them again.
- **deps** is what the install steps changed: `node_modules`, a venv, gems, Go's module cache.
- **app** is what the build steps changed, pruned to what the plan deploys: the deploy paths, less their excludes, with a whiteout for an exclude that a layer below holds (Rust's `target`), so it doesn't show through. A deps deploy under 1 MiB (Rust's `Cargo.lock`) is copied into the app layer, so the run needn't stack deps for it. When the run doesn't stack the runtime layer, the runtime's `/usr/lib` is copied into the app layer.

The run stacks only the layers it needs, and `layers.txt` lists them: the runtime when the plan deploys from a packages step and the runtime layer holds that path (a Go binary doesn't need its toolchain), deps when it holds a path the plan deploys, and app when it has anything in it.

## Keys

Keys are the first 16 hex digits of a SHA-256. They chain, so a layer is built again whenever anything below it changed:

| Key | Hashes |
| --- | --- |
| The runtime layer's shared key, its directory's name in `$cache/runtimes` | The architecture, the builder root's key, `build.sh`, the plan's runtime steps and the files they copy (less idiomatic version files such as `.nvmrc`, whose versions the plan has resolved), `H9X_RUBY_COMPILE`, and h9x's version |
| runtime's `key` in `artifact.json` | The shared key, then the runtime steps' own key from the plan, with every file they copy |
| deps | The runtime's key, then the install steps and the files they copy |
| app | The deps key, then the build steps, the files they copy, and the plan's deploy |

The plan's key, in `plan.key`, hashes the architecture, the source's content hash, Railpack's version (or for `H9X_RAILPACK`, its path, size, and mtime), and h9x's version. A kept plan is used while its key matches, so the versions Railpack resolved stay until the source changes, or `--replan`.

A build keeps every layer whose key matches. Each is built in `layers/NAME.tmp` (`$cache/runtimes/.KEY.tmp-PID` for the runtime) and moved into place when its steps succeed, so a failed step leaves no layer, and the next build starts that layer again.

## env

One `NAME=VALUE` per line: the plan's deploy variables, `DOTNET_USE_POLLING_FILE_WATCHER=1` for a .NET plan (h9 has no inotify), `H9X_START` (the start command, or `sh`), and `PATH`, which is the directories the steps put on it, mise's runtimes' own `bin` directories instead of its shims, then `/usr/local/bin:/usr/bin:/bin`. Secrets are never in it.

## cache/

Package managers' caches, per app, kept between builds: `npm`, `uv`, `go/mod`, `nuget`, `hex`, mise's downloads, and the rest, which `build.sh` points the managers at instead of the plan's own cache directories, so they don't land in a layer. Removing `cache/` costs downloads on the next build that rebuilds a layer, and nothing else.
