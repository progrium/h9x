---
slug: design-process
title: Proposal-driven design process
status: implemented
created: 2026-11-26
authors: [progrium]
depends: []
areas: [process]
branch: [main]
---

# Proposal: Proposal-driven design process

## Abstract

Adopt a proposal-driven design process: one Markdown proposal per design change in `design/`, the spec under `spec/` describing h9x as built, a small in-repo tool (`zig build design`) that validates and summarizes proposals, and a CI job that enforces the rules.

## Background

h9x's first design doc, the [prototype](prototype.md) proposal, already has proposal frontmatter and sections, and the spec has started under `spec/`, but nothing said how proposals are written, decided, or finished, and nothing checked them.
hyper9 uses a process adapted from Go's, with a Zig tool to start from.

## Proposal

Add the process described in the [design README](README.md):

- `spec/` describes h9x as built.
- `design/` holds the process README, `TEMPLATE.md`, and one `<slug>.md` per proposal.
- Proposal frontmatter is a strict YAML subset with the keys, statuses, and computed states the README defines.
- `tools/design.zig`, run as `zig build design -- <command>`, provides `list`, `ready`, `graph`, `new`, `log`, and `check`, using only Zig and git.
- A `design` job in `ci.yml` runs `check` on every PR.
- `AGENTS.md` restates the rules for AI agents.

## Rationale

A smaller process than hyper9's: hyper9's adds a generated status index, issue-sync commands, epoch folders, test tags that gate integration cases, and signing by PR comment, which are more than a repository of h9x's size needs. `list`, `ready`, and `graph` show the same state on demand, and each piece can be added with its own proposal.
Signatures were left out. hyper9 signs proposals and the spec with a dated line per reviewer, a `SIGNERS` file, a `sign` command, and a check on both. For h9x the authors list and the PR history record who directed a change, and the README's Review step asks for the same read-through without the ceremony.
The tool is a trimmed port of hyper9's `tools/design.zig`, so it builds with the toolchain h9x already needs and a PR that changes a rule changes the checker in the same diff.
A strict YAML subset instead of a YAML library keeps the parser small and makes `check` reject anything another parser could read differently. Storing only facts and computing state from git avoids an "in progress" status that goes stale.
Milestones and a separate changelog were rejected: the dependency graph orders the work, and `log <slug>` reconstructs history from git. The prototype's workstream plan stays outside the repository for the same reason: it's an order of work, not a design.

## Compatibility

None for h9x's users: no change to the CLI, formats, or output.
For contributors, design changes now need a proposal, as listed in the README.

## Security

None: the check job only reads the repository, and the tool writes only the file `new` creates.

## Done criteria

- [x] `zig build design -- check` passes on the repository.
- [x] The `check` rules are covered by the fixtures in `tools/testdata/check`, run by `zig build test`.
- [x] `list`, `ready`, `graph`, `new`, and `log` work on the repository.
- [x] The `design` CI job and `AGENTS.md` are in place.

## Implementation

1. Add the README, the template, and this proposal.
2. Port `tools/design.zig` from hyper9 without signatures, epochs, the status index, issue commands, and test tags, and with the rules the README lists.
3. Add the fixtures, the `design` build step, and the CI job.
4. Add `AGENTS.md`.
