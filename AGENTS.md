# Agent guidance

Rules for AI agents working in this repository. They restate [the design process](design/README.md); where the two differ, the README wins.

## Design changes

- Before changing anything a proposal covers (see "When a proposal is needed" in the README), find its proposal with `zig build design -- list`.
- If there's none, draft one with `zig build design -- new <slug>` and stop, unless the person directing the work says to build it. Then the PR adds or updates the proposal as it goes: its `branch` (the PR's branch), its Done criteria checkboxes, and its status.
- Refer to proposals by slug everywhere: `depends`, links (`design/<slug>.md`), commits, and PRs. Never by issue number.
- Never write progress into a proposal's body. Progress goes in `status`, `branch`, Done criteria checkboxes, and dated Updates notes.
- Never edit an accepted proposal's body except to check or waive Done criteria items: add a dated note under its Updates section, or draft a new proposal.
- Add a dependency you discover to the proposal's `depends` in the same PR, and say so.
- The spec (the files under `spec/`) describes only what's built. Update it in the PR that finishes a proposal, never before.
- Bug fixes, workarounds, and refactors that don't change behavior need no proposal; explain them in code comments and commit messages.

## Before opening a PR

- Run `zig build design -- check` and `zig build test`.
- Never skip or disable a test to get CI green.
