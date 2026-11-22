# h9build

A proof of concept: build an app from its source into layers that
[h9](https://github.com/progrium/hyper9) runs, using tools that already exist
rather than a builder of our own.

```sh
h9build -o ./myapp.h9 ./myapp   # detect, install runtimes and deps, build
./myapp.h9/run                  # run it on h9
./myapp.h9/run node -v          # or anything else in it
```

| Job | Done by |
| --- | --- |
| Detecting the language, versions, and commands | [Railpack](https://github.com/railwayapp/railpack)'s `railpack plan`, without its BuildKit backend |
| Installing runtimes | [mise](https://mise.jdx.dev), at the version Railpack pins, as Railpack's own builds do |
| Installing deps and building | The plan's commands (`npm ci`, `uv sync`, ...), as written |
| The base root | [Wolfi](https://wolfi.dev) packages: glibc, certificates, busybox |
| Running every step, sandboxed | h9's Linux personality |

The host needs only h9, `curl`, `tar`, and a POSIX shell. Nothing runs on the
host's own OS: Railpack, mise, apk, and the package managers all run inside h9
machines, so the same script works on macOS and Linux.

## What it makes

```
myapp.h9/
  layers/runtime/mise/...      the runtimes mise installed (/mise in the guest)
  layers/deps/app/node_modules the deps: what the plan deploys from /app besides the app
  layers/app/app/...           the app's files and build output (/app)
  plan.json                    Railpack's plan
  env                          the run environment: PATH, the plan's variables, the start command
  layers.txt                   the layers the run stacks (no runtime when the plan doesn't deploy it)
  run                          h9 with the layers stacked on #L over the base root
  cache/                       per-app package manager caches, kept between builds
```

Each layer is a tree rooted at `/`, so `run` stacks them in order with
`--dir LAYER:#L`: the base root, then runtime, deps, and app. The base root is
shared by every app and lives in the cache, at about 22 MB.

## How it works

1. **Bootstrap.** h9build downloads Alpine's minirootfs and Railpack's static
   binary once. Alpine's `apk` is the only package manager h9build needs to
   start: it reads Wolfi's repository just as well.
2. **Roots.** In an h9 machine on the Alpine root, `apk --root` installs Wolfi
   packages into a tree in the machine's memory, which goes out as a tar and
   is unpacked into the cache, keyed by the package set. Two roots: *base*
   (glibc, `libstdc++`, certificates, `tzdata`, busybox, and bash, which
   mise's Node uses for its `npm` wrapper), which apps run on, and *builder*,
   which adds jq and git.
3. **Plan.** In a machine on the builder root, `railpack plan` reads the source
   and writes `plan.json`. Railpack downloads the mise it pins and resolves
   versions over the network.
4. **Build.** `guest/build.sh` carries out the plan's steps in order in one
   machine, as Railpack's BuildKit backend would in layers: the mise step
   installs runtimes into `/mise`, and the install and build steps copy the
   source into `/app` and run their commands there. `/mise` and `/app` are
   binds of the output's layer directories. Then what the plan deploys from
   under `/app` besides the app itself (`node_modules`, `.venv`) moves to the
   deps layer.
5. **Run.** `run` stacks the layers read-only over the base root, with the
   plan's variables and start command.

## Where it stands

Tried on x86\_64 Linux with h9's native backend (`H9_FLAGS=--backend native`),
on Railpack's own example apps, with the caches warm (a first build adds the
downloads and about a minute to make the two roots):

| Example | Build | Layers run | Run |
| --- | --- | --- | --- |
| `node-lts-npm-native-deps` (bcrypt, better-sqlite3, canvas, sharp) | 40 s | base 22 MB, runtime 208 MB, deps 74 MB, app 60 KB | prints its test's expected output, 1.4 s |
| `go-mod` | 40 s | base 22 MB, app 2.1 MB (no runtime: the plan doesn't deploy Go) | prints its test's expected output, 40 ms |
| `python-uv` (Flask on gunicorn) | 25 s | base 22 MB, runtime 126 MB, deps 6.9 MB (the venv), app 44 KB | prints its test's expected output, and `/` answers "Hello from Python Flask!" |

The venv is in the deps layer and its `python` is an absolute link into the
runtime layer (`/mise/installs/python/...`): that resolves because h9 follows
a Linux program's links from its root
([linux-symlinks](https://github.com/progrium/hyper9/blob/main/design/linux-symlinks.md)),
in `main` from `7ded875`. Python needs an h9 at least that new.

Not tried yet: arm64 and macOS, the other languages Railpack knows, and apps
that need build tools (compilers, headers) for native code.

These runs were in a sandbox behind an HTTPS proxy, which took two things a
normal machine doesn't need: a Railpack built with a patch that passes the
proxy settings through to the mise it runs (the release clears them), and
`H9_FLAGS="--env MISE_GITHUB_ATTESTATIONS=false"`, as the proxy refused the
GitHub API calls that mise makes to check uv's attestations. The h9 was built
from hyper9's `main` at `8b1764f`.

What it leaves out, for now:

- **apt packages.** Railpack's plans name Debian packages (`libatomic1`) for
  its Debian images; h9build skips those steps. Add Wolfi packages to the
  base root with `H9BUILD_BASE_PACKAGES` when an app needs one.
- **Caching across builds.** Each build starts the layers over; only the
  package managers' caches and the roots are kept. A layer could be reused
  when its inputs (the lockfile, the runtime versions) are unchanged.
- **A tighter sandbox.** The build machines have outbound network, and can
  write only the output directory. `--net-allow` for the registries a plan
  uses would close that further.
- **Pruning.** Railpack's plans keep dev dependencies unless told otherwise
  (`RAILPACK_PRUNE_DEPS`).

## h9 behaviour it works around

- **Writable `#L` stack members** (`--dir DIR:#L/PATH:rw`) refuse renames
  across directories with `EXDEV`, which every package manager does; and
  creates of long paths through them hit a use-after-free
  ([progrium/hyper9#220](https://github.com/progrium/hyper9/pull/220)). So
  `/mise` and `/app` are `--bind`s of directories under the cwd instead,
  with `c` so they take creates.
- **Symlinks in host trees**, before
  [linux-symlinks](https://github.com/progrium/hyper9/blob/main/design/linux-symlinks.md):
  dangling ones didn't show in `readdir`, and an absolute target was followed
  as a host path. h9build still builds roots in memory and tars them out,
  keeps mise's shims in `/tmp`, and puts the directories that hold the
  runtimes' executables on `PATH` rather than mise's shims or `.mise-bins`
  links. With linux-symlinks those may no longer be needed; they haven't been
  tried without.
- **Absolute links in the guest's overlay** resolve in the Linux tree, which
  doesn't have `/mnt/term`, so a cache directory can't be a link to the
  output's `cache/`. h9build sets the package managers' cache variables
  (`npm_config_cache`, `UV_CACHE_DIR`, `GOMODCACHE`, ...) to it instead.
- **apk's scripts** need `chroot`, which h9 doesn't have, so apk runs with
  `--no-scripts`, and h9build makes busybox's applet links itself. And since
  Alpine's apk keeps its database in `/lib/apk`, the root's `/lib -> usr/lib`
  link is made afterwards; glibc's loader is found through it on arm64.

## Environment

| Variable | |
| --- | --- |
| `H9` | The h9 binary (default `h9` on `PATH`) |
| `H9_FLAGS` | Extra flags for every h9 run, such as `--backend native` |
| `H9BUILD_CACHE` | The cache (default `${XDG_CACHE_HOME:-~/.cache}/h9build`) |
| `H9BUILD_BASE_PACKAGES` | More Wolfi packages for the base root |
| `HTTPS_PROXY`, `SSL_CERT_FILE` | Passed into the guest when set |
