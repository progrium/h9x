# The library

h9x is also a Zig module, `h9x`, for programs that plan, build, and run apps as calls instead of running the `h9x` command. The CLI is a client of the same code, so a step does what its command does, with the same cache, config, policies, and output directory. [design/prototype.md](../design/prototype.md) has the reasons. [tests/lib_example.zig](../tests/lib_example.zig) is a complete program.

```zig
const h9x = @import("h9x");

var b = try h9x.Builder.init(gpa, io, .{ .env = env, .on_event = report });
defer b.deinit();

const src = try b.source(.{ .git = .{ .url = "https://github.com/foo/bar", .ref = "v1.2" } });
const plan = try b.plan(src, .{});
const art = try b.build(plan, .{ .out_dir = "bar.h9" });

var m = try art.machine(.{ .policy = .untrusted });
const code = try m.run(&.{});
try art.exportOci("bar.oci.tar");
try art.pack("bar.tar", .{});
```

A program gets the module from its `build.zig.zon` dependency on h9x, as `dep.module("h9x")`.

## The builder

`Builder.init(gpa, io, options)` returns a heap-allocated builder, and `deinit` frees it with every value its steps returned. Every value lives until then.

| Option | What it is |
| --- | --- |
| `cache_dir` | The cache ([cache.md](cache.md)). Null is `H9X_CACHE` from `env`, or `${XDG_CACHE_HOME:-~/.cache}/h9x`. |
| `machine.backend` | h9's backend for every machine, as `H9X_BACKEND` names it. Null is h9's default. |
| `env` | What h9x reads from the host's environment: the proxy and CA variables, `H9X_*` settings, the secrets named for builds, and `HOME` for the user's config. The builder keeps its own copy. Null is an empty environment. |
| `on_event`, `event_ctx` | Called with each event ([events.md](events.md)), one at a time, from the calling thread or a machine's output thread. Null drops them. |

`setSecrets(names)` names variables in `env` that build steps get, as `--secret` does. They reach no file h9x writes.

## Steps

| Step | Returns | What it does |
| --- | --- | --- |
| `b.source(spec)` | `Source` | Resolves a source: a directory's content hash, or a git or tarball source fetched into the cache. `spec` is `.dir`, `.git{url, ref, subdir}`, `.tarball{url, subdir}`, or `.spec`, a SOURCE as the CLI takes it ([cli.md](cli.md)). |
| `b.plan(src, .{out_dir, replan})` | `Plan` | Makes the builder root and plans the source, keeping the plan in the output directory. With the source unchanged, the kept plan is used unless `replan`. `out_dir` null is `$cache/builds/KEY`. |
| `b.build(plan, .{out_dir})` | `Artifact` | Builds the plan's layers, keeping each whose key matches, and writes the output directory ([output.md](output.md)). `out_dir` null is where the plan was kept; another directory gets a copy of the plan. |
| `b.open(out_dir, remote)` | `Artifact` | An existing output directory. `remote` is whether it was built from a git or tarball source. |

`Plan.value()` is the plan (Railpack's, with the layer split and keys) and `Plan.dir()` its output directory. `Artifact.value()` is `artifact.json`'s contents, `Artifact.dir()` the output directory, and `Artifact.stack()` the base root and run layers, bottom first, as host paths.

## Machines

`art.machine(options)` returns a `Machine` on the run stage, under `h9x run`'s policy for the given trust, narrowed by the options.

| Option | What it is |
| --- | --- |
| `policy` | A `Policy{trust, text}`. `Policy.local` is `h9x run`'s defaults for a directory source, and `Policy.untrusted` its defaults for a remote one. `text` is h9 plan lines that narrow those defaults, as `[run] policy` does; a line that widens them is `error.PolicyWidens`. |
| `mounts` | Host directories, as `--mount` gives them. Refused under an untrusted policy. |
| `net` | `.disable`, `.outbound`, or `.enable`, as `--net`, which sets the mode as given. |
| `timeout_ns` | The machine's timeout, as `--timeout`. |

`m.print(w)` writes the policy as h9 plan text, as `--print` shows it. `m.run(argv)` starts the machine with argv, or the start command when argv is empty, on the process's stdin, stdout, and stderr, and returns the program's exit code (124 for a timeout). `m.runWith(argv, stdio)` does the same with the given stdio.

## Writing it out

`art.exportOci(path)` writes an OCI image layout, as a tar, to `path`. `art.pack(path, .{exe, targets, runners, mounts, debug})` writes a pack to `path`, or with `exe` or `targets`, an executable to `path` (one target) or one per target into the directory `path`. Both make what `h9x export --oci` and `h9x pack` make ([pack.md](pack.md)), and both take paths rather than writers, since an executable for several targets is several files. A usage error is `error.Usage`, and any other failure `error.Failed`.

## Errors

A step that fails returns its error, and the `log` events before it say why. `h9x.exitCode(err)` gives the exit code the CLI would return for it ([cli.md](cli.md)).
