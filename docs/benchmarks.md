# Benchmarks: h9x vs Railpack on Docker, and vs a Dockerfile

Measured Nov 2026 in a Claude cloud container: x86\_64 Linux, 4 vCPUs, no
KVM, so h9 ran with `--backend native`, behind a TLS-intercepting proxy. These
are the "v2" numbers, taken after the plan cache and shared runtime layers
(progrium/scratch#25) landed. The harness (`bench.sh`, `all.sh`,
`report.py`, the hand-written Dockerfiles, and the Railpack image rebuilds the
proxy needed) isn't in this repo yet; it was kept with the files of the project h9x
incubated in (progrium/scratch, where it was h9build) as `h9build-vs-docker/`.

There are two separate comparisons:

1. **h9x vs Railpack on Docker** is like for like. Both take a bare source
   directory, run the same Railpack plan, and install runtimes with mise.
   Railpack builds through BuildKit (`railpack build`).
2. **h9x vs a hand-written Dockerfile** is the expert ceiling: an idiomatic
   multi-stage Dockerfile per app on the official runtime image, with versions
   pinned to what Railpack resolved.

The apps are Railpack's examples. The phases are *cold* (per-app caches gone,
shared roots and base images kept), *cold, runtime already installed* (another
app already installed the same runtimes), *no change*, and *small change* (one
comment line appended to the main source file). Sizes are h9's base root plus
the run layers vs the image, gzip-compressed. Each cell is h9x vs the
other, with the ratio; under 1.0× means h9x is faster.

## h9x vs Railpack on Docker

| App | Cold (s) | Cold, runtime already installed (s) | No change (s) | Small change (s) | Size, compressed (MB) |
| --- | --- | --- | --- | --- | --- |
| go-mod | 42.0 vs 21.1 (2.0×) | 20.0 vs 21.1 (0.9×) | 0.7 vs 0.8 (0.8×) | 4.1 vs 1.9 (2.1×) | 14.3 vs 44.4 (-68%) |
| node-npm | 38.5 vs 34.5 (1.1×) | 25.1 vs 34.5 (0.7×) | 0.9 vs 2.1 (0.4×) | 3.0 vs 3.2 (0.9×) | 73.8 vs 158.9 (-54%) |
| node-bun | 22.4 vs 32.2 (0.7×) | 7.8 vs 32.2 (0.2×) | 1.0 vs 2.8 (0.4×) | 5.2 vs 4.9 (1.1×) | 128.9 vs 215.4 (-40%) |
| python-uv | 16.8 vs 26.5 (0.6×) | 7.4 vs 26.5 (0.3×) | 0.8 vs 2.0 (0.4×) | 3.7 vs 4.0 (0.9×) | 62.1 vs 146.9 (-58%) |
| ruby-latest | 34.4 vs 43.8 (0.8×) | 6.0 vs 43.8 (0.1×) | 0.9 vs 2.6 (0.3×) | 3.2 vs 4.1 (0.8×) | 124.6 vs 197.9 (-37%) |
| cpp-cmake | 23.5 vs 16.3 (1.4×) | 5.2 vs 16.3 (0.3×) | 0.6 vs 0.7 (0.9×) | 4.9 vs 2.2 (2.3×) | 13.4 vs 43.5 (-69%) |

## h9x vs a hand-written Dockerfile

| App | Cold (s) | Cold, runtime already installed (s) | No change (s) | Small change (s) | Size, compressed (MB) |
| --- | --- | --- | --- | --- | --- |
| go-mod | 42.0 vs 17.9 (2.4×) | 20.0 vs 17.9 (1.1×) | 0.7 vs 0.8 (0.9×) | 4.1 vs 1.3 (3.1×) | 14.3 vs 1.7 (+760%) |
| node-npm | 38.5 vs 24.7 (1.6×) | 25.1 vs 24.7 (1.0×) | 0.9 vs 0.9 (1.0×) | 3.0 vs 0.8 (3.6×) | 73.8 vs 79.9 (-8%) |
| node-bun | 22.4 vs 10.1 (2.2×) | 7.8 vs 10.1 (0.8×) | 1.0 vs 0.8 (1.2×) | 5.2 vs 2.4 (2.1×) | 128.9 vs 89.1 (+45%) |
| python-uv | 16.8 vs 5.7 (2.9×) | 7.4 vs 5.7 (1.3×) | 0.8 vs 0.7 (1.2×) | 3.7 vs 1.6 (2.3×) | 62.1 vs 47.6 (+31%) |
| ruby-latest | 34.4 vs 7.2 (4.7×) | 6.0 vs 7.2 (0.8×) | 0.9 vs 0.8 (1.1×) | 3.2 vs 0.8 (4.1×) | 124.6 vs 89.8 (+39%) |
| cpp-cmake | 23.5 vs 18.3 (1.3×) | 5.2 vs 18.3 (0.3×) | 0.6 vs 0.7 (0.8×) | 4.9 vs 1.4 (3.5×) | 13.4 vs 29.8 (-55%) |

## What the numbers say

- Against Railpack, h9x wins on no-change rebuilds (about 0.5 to 1 s, from
  the kept plan), on a second app that shares runtimes, and on size (37 to 69%
  smaller). It loses on cold Go and C++ builds and on small-change rebuilds,
  where it rebuilds the whole app layer.
- Against a hand-written Dockerfile, it's slower cold and on small changes.
  The images are comparable in size except Go, where a distroless static image
  is hard to beat.
- Cold builds are held back by h9 itself, mostly the cost of creating files and
  of threads on the native backend. A profiling run with an h9 patched to skip
  the sandbox policy check (`H9_EXP_NOPOLICY`, `--cpus 1`) cut cold times by
  about 35 to 55% (go-mod 77 to 48 s, ruby-latest 79 to 36 s, cpp-cmake 40 to
  18 s), so the per-call policy check is a large part of it.
- The first round (before the plan cache and shared runtimes) had no-change
  rebuilds at about 2 s and cold go-mod at 124 s.

## The hang

One of the roughly six cold python-uv builds hung forever in `uv sync` during
bytecode compile. That's progrium/hyper9#276 (a lost wakeup on the native
backend, 0% CPU, every uv thread parked in a guest syscall). It was closed by
progrium/hyper9#280 (epoll\_wait missing a wake that lands just before it
sleeps); progrium/hyper9#283 (F\_DUPFD and nonblocking pipe reads racing other
threads) is the other half and was still open when this was written.
