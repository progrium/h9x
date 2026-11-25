# Events and exit codes

Every h9x command reports what it's doing as events on stderr. Without `--json`, events are the `h9x:` lines a person reads. With `--json`, each event is one JSON object on its own line (NDJSON), and the last line is always a `result` with the command's exit code. A command's own output, such as `plan`'s summary or `--print`'s policies, goes to stdout either way, so a script can read stdout and stderr separately.

```
$ h9x build ./app --json 2>events.ndjson
```

```json
{"event":"phase","phase":"plan","state":"start"}
{"event":"layer","layer":"deps","state":"cached","key":"…"}
{"event":"step","layer":"app","step":"build","state":"start"}
{"event":"output","layer":"app","step":"build","stream":"stderr","text":"…"}
{"event":"step","layer":"app","step":"build","state":"exit","status":0,"ms":4120}
{"event":"result","command":"build","status":0,"out":"/home/me/app.h9","ms":5302}
```

`src/events.zig` writes both forms.

## The JSON form

Each line is an object whose `event` field names its kind, followed by the kind's fields in the order listed below. A field that has no value is left out rather than written as `null`. Enum values, such as states, layers, and phases, are lowercase strings. Strings are UTF-8: a byte that isn't part of a UTF-8 sequence is written as U+FFFD, so a program's binary output can't make a line that a JSON parser rejects. Durations (`ms`) are milliseconds, and sizes (`bytes`) are bytes.

A reader should ignore kinds and fields it doesn't know, since later versions add them.

### States

Kinds with a `state` field share one set of values:

| State | Meaning |
| --- | --- |
| `start` | The work began. |
| `done` | The work finished. |
| `cached` | Kept from an earlier run, so nothing was done. |
| `shared` | Taken from the shared cache, such as a runtime layer another app built. |
| `building` | Being built now. |
| `exit` | A program ended; `status` says how. |
| `failed` | The work failed; a `log` event says why. |

## Kinds

### `phase`

A phase of a command began or ended. The phases are the policy table's: `fetch`, `root`, `plan`, `build`, `run`, and `shell`.

| Field | Type | |
| --- | --- | --- |
| `phase` | string | The phase. |
| `state` | string | `start`, `done`, `cached` (such as a kept plan), or `failed`. |

### `fetch`

A git or tarball source being fetched.

| Field | Type | |
| --- | --- | --- |
| `url` | string | The source's URL. |
| `state` | string | `start`, `done`, `cached`, or `failed`. |
| `bytes` | number, optional | How much was fetched, when known. |

### `root`

A root that machines run on: `bootstrap`, `base`, or `builder`.

| Field | Type | |
| --- | --- | --- |
| `root` | string | The root's kind. |
| `key` | string | The root's cache key. |
| `state` | string | `building`, `done`, `cached`, or `failed`. |

### `layer`

One of the app's layers: `runtime`, `deps`, or `app`.

| Field | Type | |
| --- | --- | --- |
| `layer` | string | The layer. |
| `state` | string | `building`, `done`, `cached`, `shared`, or `failed`. |
| `key` | string | The layer's cache key. |

### `step`

A Railpack step running in a layer's machine.

| Field | Type | |
| --- | --- | --- |
| `layer` | string | The layer it builds in. |
| `step` | string | Railpack's name for the step. |
| `state` | string | `start`, then `exit`, or `failed` if it couldn't run. |
| `status` | number, optional | With `exit`: the step's exit code, as h9 maps the guest's status. |
| `ms` | number, optional | With `exit`: how long it ran. |

### `output`

Bytes a program in a machine wrote. A program's output is cut into events by size and when its machine ends, not by line, so a reader that wants lines joins `text` across events of the same `layer`, `step`, and `stream`. A UTF-8 sequence is never split between two events.

| Field | Type | |
| --- | --- | --- |
| `layer` | string, optional | The layer, when the program is a build step. |
| `step` | string, optional | The step, when the program is a build step. |
| `stream` | string | `stdout` or `stderr`. |
| `text` | string | The bytes. |

### `policy`

The policy a machine runs under, as h9 plan lines. `--print` writes these and exits, and `--json` reports one for each machine a command starts.

| Field | Type | |
| --- | --- | --- |
| `phase` | string | The phase the machine is for. |
| `text` | string | The plan lines, each ending in a newline. Secrets show as `env NAME=…`. |

### `log`

A note or warning for the person, such as the deprecation warning for `h9x DIR`, or why a command failed.

| Field | Type | |
| --- | --- | --- |
| `text` | string | The message, without the `h9x:` prefix. |

### `result`

The last event of every command, usage errors included. Nothing is written after it.

| Field | Type | |
| --- | --- | --- |
| `command` | string | The subcommand, such as `build`. |
| `status` | number | The exit code h9x exits with (below). |
| `out` | string, optional | What the command made, such as `build`'s output directory or `pack`'s file. |
| `ms` | number | How long the command took. |

## The text form

Without `--json`, events print as the POC's `h9x:` lines, and only when there's something to see: a start, a kept or shared layer, a failure, or a note. `done` states and a zero exit are left out.

| Event | Line |
| --- | --- |
| `phase` `start` | `h9x: plan` |
| `phase` `cached` | `h9x: plan: unchanged` |
| `fetch` `start` | `h9x: fetching URL` |
| `root` `building` | `h9x: making the base root` |
| `layer` `building` | `h9x: layer deps` |
| `layer` `cached` | `h9x: layer deps: unchanged` |
| `layer` `shared` | `h9x: layer runtime: shared, KEY` |
| `step` `start` | `h9x: layer app: step build` |
| `step` `exit`, nonzero | `h9x: layer app: step build: exit 1` |
| any `failed` | `h9x: layer app: failed`, and so on |
| `output` | the program's bytes, as they are |
| `policy` | `# PHASE`, then the plan lines |
| `log` | `h9x: TEXT` |
| `result`, nonzero | `h9x: build: exit 1` |
| `result`, zero with `out` | `h9x: done: OUT` |

The text form is for people and may change; scripts should use `--json` and the exit code.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success, or the run's program exited with an empty status. |
| 1 | A build step failed, or Railpack made no steps. |
| 2 | A usage, config, or policy error, such as a widening flag. |
| 124 | A timeout, as h9's. |
| 125 | Setup failed: a download, a root, or a machine h9 couldn't start, as h9's. |
| other | For `run` and `shell`, the program's exit status, as h9 maps it. |

h9 maps a guest's status to a code as its CLI does: an empty status is 0, a number from 1 to 255 is itself, any other status is 1, a timeout is 124, and a machine that was killed for another reason is 125.

### In the code

A command returns its exit code, or an error. `events.exitFor` maps an error to a code by the error's name:

- **2**, `events.UsageError`: `Usage`, `BadConfig`, `BadPolicy`, `PolicyWidens`, `PolicyConflict`, `BadSource`, `BadTarget`, and `BadBackend`.
- **1**, `events.FailedError`: `StepFailed`, `NoSteps`, and the skeleton's `NotImplemented`.
- **124**, `events.TimeoutError`: `Timeout`.
- **125**: any other error, such as a failed download, a missing file, or h9's machine errors.

A module that fails for one of these reasons returns an error of that name, so the mapping needs no table of its own. To say why, a command logs before it returns: `return ctx.events.fail(error.PolicyWidens, "--net enable widens the build policy", .{})` writes the `log` event and returns 2.
