# Packs, packed executables, and images

`h9x pack` writes a build's run stage as one file: a tar, or an executable per target that runs it with nothing installed. `h9x export` writes it as an OCI image. This is the contract for each, for tools that read them without h9x. [design/prototype.md](../design/prototype.md) has the reasons.

```sh
h9x pack OUT.h9 [-o FILE]                    # a tar, NAME.tar by default
h9x pack OUT.h9 --exe [-o FILE]              # an executable for this host, NAME by default
h9x pack OUT.h9 --target LIST|all [-o DIR]   # one per target in DIR (dist/), with SHA256SUMS
h9x pack OUT.h9 --print                      # the policy it would seal, and nothing else
h9x pack --inspect FILE                      # what's in a packed executable
h9x export OUT.h9 --oci FILE                 # an OCI image layout, as a tar
h9x export OUT.h9 --docker | docker load     # a docker save tarball
```

NAME is the output directory's name without `.h9`. Pack and export take a build's output directory (one with an `artifact.json`), or a SOURCE, which they build first as `h9x build` would.

## The tar

A pack is a POSIX tar of the base root and the run layers from `layers.txt`, bottom first, flattened: each layer's `.wh.NAME` hides NAME below it, `.wh..wh..opq` hides everything below its directory, and neither is written. It's deterministic, so the same layers and options make the same bytes: entries are sorted by path, depth first, with mtimes, uids, and gids of 0, no user or group names, hard links written as copies, and devices and sockets left out. Long paths and link targets take a PAX header.

Three entries are h9x's:

| Path | What it is |
| --- | --- |
| `.h9x/pack.json` | What a runner needs to start the app (below) |
| `.h9x/run` | A shell script that starts the app with plain h9 (below) |
| `.h9x/index` | The last entry: each entry's kind, mode, offset, and size, so a reader opens any file with one seek. [src/index.zig](../src/index.zig) specifies its text. |

Any tar tool lists or extracts a pack, and h9 mounts one:

```sh
h9 --archive app.tar:#L sh /.h9x/run [ARGS...]
```

## pack.json

```json
{
  "version": 1,
  "arch": "amd64",
  "digest": "sha256:…",
  "env": ["PATH=…", "NODE_ENV=production"],
  "start": "node server.js",
  "cwd": "/app",
  "policy": "dir rw . /work\nnet outbound\nwrite overlay\nmemory 1G\n",
  "layers": [{"name": "deps", "key": "…"}, {"name": "app", "key": "…"}],
  "debug": true
}
```

| Field | Meaning |
| --- | --- |
| `version` | 1. A reader refuses another. |
| `arch` | The guest architecture the layers hold: `amd64` or `arm64` |
| `digest` | The seal (below) |
| `env` | The app's environment, as `NAME=VALUE` |
| `start` | The start command, a shell command line, or null |
| `cwd` | Where the app starts |
| `policy` | The run policy, sealed, as h9 plan lines (below) |
| `layers` | The run layers' names and keys. Host paths aren't written. |
| `debug` | Whether `H9X_PACK=info` and `H9X_PACK=shell` work; false with `--no-debug` |

Field order is fixed, with `digest` third. A reader ignores fields it doesn't know.

### The seal

`digest` is `sha256:` and the SHA-256, in hex, of the whole tar with that field's 64 hex digits read as `0`s. `h9x pack` writes the tar with zeros there while hashing it, then writes the digest over them, so the digest covers every other byte, pack.json and its policy included. To check one: find pack.json through the index, find `"digest":"sha256:` in its text, and hash the tar with the 64 bytes after it as `0`s. `h9x pack --inspect` does, and prints whether it matches.

The digest names the pack: two packs with the same digest are the same bytes. It isn't a signature, so a pack is as trusted as wherever it came from. It's distinct from the tar's own SHA-256, which `--inspect` prints as the archive's digest, and from an executable's SHA-256, which `SHA256SUMS` lists.

### The sealed policy

`policy` is the run policy `h9x run` uses for a local source: the run phase's defaults, the user's config, `H9X_*` variables, and `[run] policy`, with the pack's mounts added. The mounts are `--mount HOST:GUEST[:ro]` flags at pack time, or `[pack] mount` in `h9x.toml` without them, as `dir` lines. A relative HOST stays relative, and is resolved against the runner's working directory when it runs, so `--mount .:/work` gives a CLI the directory it's run in. The lines that bind the machine to the pack (the root) aren't in it: the runner adds those.

## /.h9x/run

A POSIX shell script: it exports `env`, changes to `cwd`, and runs `/bin/sh -c 'START "$@"' sh "$@"`, so its arguments follow the start command. Without a start command, it runs its arguments, or exits 2 if there are none. With `H9X_PACK=shell` in the guest's environment it runs `/bin/sh` with its arguments instead, in `cwd`. Plain h9 and the runner both start the app through it.

## Packed executables

An executable is a runner (`h9x-runner`, h9's library and a small `main`) with the tar joined to it in its OS's container, ending in a 32-byte trailer: `H9XPACK\0`, the archive's offset and length as little-endian u64s, a u32 version (1), and a reserved u32. [src/exe](../src/exe) writes them.

| Target | Container | Signed |
| --- | --- | --- |
| `linux-amd64`, `linux-arm64` | The archive appended to the ELF image | No |
| `macos-arm64` | A `__H9X,__pack` section in a segment before `__LINKEDIT` | Ad hoc, with `com.apple.security.hypervisor` |
| `windows-amd64` | A `.h9x` PE section after the last one, before any certificate | No |

`--exe` makes the host's. `--target` takes a comma-separated list, or `all`, which is the targets whose architecture is the layers': `linux-amd64` and `windows-amd64` for amd64, `linux-arm64` and `macos-arm64` for arm64. Another architecture's target is exit 2. Each is written as `DIR/NAME-TARGET`, with `.exe` on Windows, and `DIR/SHA256SUMS` lists every one, as `sha256sum -c` reads it.

### Runners

For each target, `pack` uses the first of:

1. `--runner TARGET=FILE` for that target, or `--runner FILE` if FILE is a runner for it (its container and architecture). A runner named for a target that isn't one for it, or a bare one that's no target's, is exit 2.
2. The runner embedded in `h9x`, for the host's own target.
3. The release's: `h9x-runner-VERSION-TARGET[.exe]` from `https://github.com/progrium/h9x/releases/download/vVERSION/`, checked against the SHA-256 that `h9x` pins for it and kept in `$cache/runners/`. Until the first release pins any, a target without one is exit 2, saying to give `--runner`.

### Running one

The runner:

1. Reads the trailer from its own file, then the index and pack.json through it.
2. With `H9X_PACK=info` (and `debug`), prints the seal and whether the bytes still match it, the layers, the start command and environment, and the policy, and exits 0, or 1 if the seal doesn't match.
3. Looks for `${XDG_CACHE_HOME:-~/.cache}/h9x/packs/HEX`, HEX being the seal's (`%LOCALAPPDATA%\h9x\packs` on Windows). If it isn't there, it checks the seal, refusing a pack that doesn't match with exit 125, and extracts the tree into a temporary directory beside it, then renames it into place. If it is, it uses that copy, and pack.json from it, without hashing the executable again.
4. Makes the machine's policy: the extracted tree read-only on `#L`, then the sealed policy with its relative mounts resolved. `H9X_PACK_NET=none|outbound|enable` narrows `net`, and one that would widen it is exit 2. Writes go to an overlay that's discarded at exit.
5. Runs `/bin/sh /.h9x/run ARGS...`, ARGS being its own arguments, and exits with the program's status as h9 maps it. With `H9X_PACK=shell` (and `debug`), it runs a shell instead.

`H9X_PACK` is the only variable the runner reads for itself, with `H9X_PACK_NET`. As every machine h9x starts, it also takes `H9X_BACKEND` and passes `HTTPS_PROXY` and `SSL_CERT_FILE` into the guest. The guest sees no other host variable.

## OCI images

`h9x export` writes the base root as one layer, then each run layer, each a deterministic tar as above but with its whiteouts kept, gzipped. The config has the architecture, `os` `linux`, `Env`, `WorkingDir` (`cwd`), and `Cmd` `["/bin/sh", "-c", START]`, with no timestamps or history, so the same build makes the same image digest. `--oci FILE` writes an OCI image layout as a tar; `--docker` writes the same with docker's `manifest.json` added, to stdout, and refuses a terminal. The image is named `NAME:latest`, NAME lowercased with anything docker doesn't take as `-`. [src/oci.zig](../src/oci.zig) has the details.
