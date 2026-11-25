# The cache

h9x keeps everything it downloads or builds that more than one build can use in one directory: `$H9X_CACHE` if it's set, or else `${XDG_CACHE_HOME:-~/.cache}/h9x`. Nothing in it is needed to run an app that's been packed, so it's safe to remove, at the cost of downloading and building it all again.

## Layout

Each kind of entry has a directory, and each entry is a file or directory in it.

| Directory | What's in it | Keyed by |
|---|---|---|
| `bootstrap/` | Alpine's minirootfs, whose `apk` makes the other roots, and Wolfi's signing key | Alpine's version and the architecture |
| `dl/` | Downloads kept as they came: the minirootfs and Railpack's release archive | Their names and versions |
| `tools/` | Railpack, and the mise binary it pins | Their versions |
| `roots/` | The base and builder roots, `base-KEY` and `builder-KEY` | The architecture, the Wolfi repository, and the package set |
| `runtimes/` | Runtime layers that apps share | The builder root, `build.sh`, and the plan's runtime steps |
| `sources/` | Git and tarball sources, and the file lists of directory sources (below) | |
| `builds/` | The output directories of remote sources' builds | The source's hash and the plan |
| `runners/` | `h9x-runner` for targets other than the host's, from h9x's release | The target and h9x's version |
| `packs/` | Packs that a packed executable has extracted | The archive's digest |

`sources/` holds three kinds of entry of its own:

- `sources/git/KEY` is a bare repository per git URL, which each fetch of that URL adds to.
- `sources/tree/HASH` is a source's files: a git commit's tree under the commit, or a tarball's unpacked tree under the tarball's SHA-256. A tree is written once and never changed, so a build of the same commit reads the tree that's there and fetches nothing.
- `sources/dirs/KEY` is a directory source's file list, keyed by its path: each file's size, mtime, and SHA-256. The next build of that directory reads only the files whose size or mtime changed.

`sources/tmp/` holds a tarball while it's fetched, and `ca/` holds a copy of `SSL_CERT_FILE` that machines mount. Neither is an entry. Names that start with `.` are entries being made, which a build that fails part way can leave behind; `prune` removes them once they're old enough.

## Last use

Each entry's mtime is the last time a build used it. h9x touches an entry whenever it uses one, including entries it finds already made, so an entry's age is how long it's gone unused rather than how long ago it was made.

## `h9x cache ls`

Lists every entry, by kind and then by name, with its size and how long ago it was last used, and the total:

```
ENTRY                    SIZE   USED
roots/base-0c1d2e3f      212M     2d  (named by a build)
roots/builder-4a5b6c7d   1.4G     2d
runtimes/9e8f7a6b        186M    40d
sources/tree/aac3f6dd    314K     3h
total                    1.8G
```

Sizes count every file below the entry, without following symlinks. An entry that a build in `builds/` names says so. With `--json`, each entry is a JSON object on its own line, with `kind`, `name`, `path`, `size` in bytes, `used` in Unix seconds, and `named`.

## `h9x cache prune`

Removes every entry that hasn't been used in 30 days, or in the `--unused` duration given (`12h`, `7d`, `90d`), and says what it removed and how much space that freed. `--dry-run` says what it would remove, and removes nothing.

A base root or runtime layer that a build in `builds/` still names, in its `artifact.json`, is kept whatever its age. Builds are pruned first, so a root or runtime that only an old build names goes along with that build. An output directory outside the cache, such as `./app.h9`, isn't known to the cache, so the roots and runtimes it names are kept only while builds keep touching them.

Entries that guests made read-only, such as Go's module cache in a layer, are made writable before they're removed.
