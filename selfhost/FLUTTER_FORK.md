<!-- cspell:words prebuilts gclient ninja caffeinate APFS -->

# Working on the Flutter fork

The Flutter fork is `mml555/shorebird-flutter`. It holds the framework, flutter_tools and
the engine in one tree, with our changes on top of upstream Shorebird's Flutter branch.
The Dart SDK changes live in `mml555/dart-sdk-shorebird-lineage`. The updater is pinned by
revision in the fork's `DEPS`.

## Layout on the build Mac

All of it is under `~/shorebird-engine`.

| Path | What it is |
|---|---|
| `flutter/` | Frozen at `d0714887`, the supported cell's engine. Never check out anything else here and never modify it. Its `engine/src/out` holds the supported cell's builds. |
| `flutter-350/` | The Flutter 3.50.0 port, branch `selfhost/3.50`. An APFS clone of `flutter/` without `out/`. |
| `flutter-NAME/` | Further engine trees, made by `bin/new-branch NAME --engine`. |
| `bin/` | The scripts below. |
| `env.sh` | Source it before any git, gclient or ninja work. |
| `logs/` | Sync and build logs, and `build.pid` while a build runs. |
| `~/Developer/shorebird-wt/` | Worktrees for framework-only work (`fl-NAME`), the doc worktrees, and `tmp/heavy.lock`. |

An optional checkout of the Dart fork (`dart-sdk-lineage`) can sit beside them; a tree's own
`engine/src/flutter/third_party/dart` is what the build uses.

A tree is cloned with `cp -Rc` (APFS copy-on-write) one top-level entry at a time, skipping
`engine/src/out`. That costs almost no disk until files diverge.

## Scripts

Each prints its plan first, is idempotent and runs with `set -euo pipefail`.

- `bin/new-branch NAME [--from REF] [--engine]`: a worktree for framework work, or a cloned
  tree for engine work.
- `bin/sync [TREE] [--dart-rev SHA|none]`: fetch, set the Dart revision in `.gclient`,
  `gclient sync`, check the Dart checkout, relink the Xcode SDKs. Refuses the frozen tree.
- `bin/build TREE CONFIG... [-j N]`: gn and ninja for `ios_release`, `ios_release_rb`,
  `host_release_arm64`, `host_release_arm64_ddm`. Refuses the frozen tree without
  `--allow-frozen`, and refuses a placeholder Dart revision.
- `bin/promote TREE`: read-only checks along the chain in
  [TOOLCHAIN_PROMOTION.md](TOOLCHAIN_PROMOTION.md). It prints the `compatibility.yaml`
  change and never applies it.
- `bin/clean [TREE] [--configs a,b]`: list `out/` by size and age and delete only the configs
  you name. The supported cell's configs are protected unless `--include-supported`.

## Rules

- Heavy work (gclient sync, ninja) is serialized by `mkdir ~/Developer/shorebird-wt/tmp/heavy.lock`.
  The scripts take it and release it. Run ninja at most `-j8`; the Mac is shared.
- Use the standalone Dart for tools, never a Dart bundled in another Flutter checkout.
- `bin/internal/engine.version` must name an engine we minted. A stock upstream hash sends
  the tool to upstream storage. Re-pin it when you promote.
- Merge a new upstream Flutter with the base set to the upstream tag the carry was built on
  (`git merge-recursive TAG -- HEAD OLD_BRANCH`), because upstream releases are not always
  ancestors of each other and a plain `git merge` reports many false conflicts.
- Tags and releases are the owner's.

## Disk budget

A tree is about 18 GB without `out/`. A release iOS config is several GB, a host config
about the same. Plan for 25 GB free before a sync or build; the scripts stop below that.
Time Machine local snapshots can make `df` understate free space. Do not delete them; if a
write fails for space, stop and report. Delete unused `out/` configs with `bin/clean`.

## Worktrees to prune

`git -C ~/shorebird-engine/flutter worktree list` shows worktrees whose scratchpad directory
no longer exists (marked prunable). `bin/clean flutter` prints the list and the prune command
but never runs it.
