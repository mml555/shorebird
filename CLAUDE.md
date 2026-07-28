# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A self-hosted fork of [Shorebird](https://github.com/shorebirdtech/shorebird).
It keeps the upstream CLI and on-device updater version-pinned, and adds
`packages/code_push_server` — a control plane they talk to instead of
`api.shorebird.dev`. Self-host docs live in `selfhost/`; the supported
CLI/engine/updater revisions are pinned in `selfhost/compatibility.yaml`.

Releases are cut as `selfhost-vX.Y.Z` (the whole distribution — the tag users
pin) and `code_push_server-vX.Y.Z` (the package). The CLI carries fork changes
under a `+selfhost.N` build suffix rather than a version bump, so it never
collides with an upstream release.

## Build Commands

```bash
# Run all tests (must run from packages/ directory to avoid cache conflicts)
cd packages && very_good test -r

# Run tests for a single package (can use -r failures-only to reduce output)
dart test packages/shorebird_cli

# code_push_server is standalone — own pubspec.lock, NOT a workspace member,
# so run its tests from its own directory. `-x integration` skips the tests
# needing live Postgres/MinIO.
cd packages/code_push_server && dart test -x integration
```

## Architecture

Dart monorepo. Upstream's main package is `shorebird_cli`; this fork's own work
is `packages/code_push_server`.

**Platform-specific operations** use the Releaser/Patcher pattern:
- `commands/release/` - `Releaser` base class with platform implementations
- `commands/patch/` - `Patcher` base class with platform implementations

**Dependency injection** uses `scoped_deps` with zone-based refs (see any `*Ref` variable).

## Code Style

- PR titles must follow semantic commit format (enforced in CI)
- CSpell: use inline `// cspell:words` for 1-2 files; add to global config for more
- Prefer new commits over amending in PRs - history gets squashed anyway
