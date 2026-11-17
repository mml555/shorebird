<!-- cspell:words prebuilts gclient ninja caffeinate APFS symlinks symlinked -->

# Working on the Flutter fork

The Flutter fork is `mml555/shorebird-flutter`. It holds the framework, flutter_tools and
the engine in one tree, with our changes on top of upstream Shorebird's Flutter branch.
The Dart SDK changes live in `mml555/dart-sdk-shorebird-lineage`. The updater is pinned by
revision in the fork's `DEPS`.

## Setting up the build Mac

The scripts are versioned here, in [`flutter_fork/`](flutter_fork/):

| File | Purpose |
|---|---|
| `flutter_fork/bin/` | `new-branch`, `sync`, `build`, `promote`, `clean`, `lib.sh`, a README |
| `flutter_fork/env.sh` | Source it before any git, gclient or ninja work. Keeps git, rust and depot_tools state inside `~/shorebird-engine`. |
| `flutter_fork/bootstrap.sh` | One-time setup: depot_tools, Rust, the `flutter` tree at the frozen revision, `gclient sync`, SDK links. |
| `flutter_fork/install.sh` | Symlinks the files above into `~/shorebird-engine` (`bin/`, `env.sh`, `bootstrap.sh`). |

To set up or update a machine, run `selfhost/flutter_fork/install.sh` from a checkout of
`main` (`--dry-run` shows the links). Each link is renamed into place, so a script that is
running is never broken. Re-run it if you move the checkout. On a fresh machine run
`~/shorebird-engine/bootstrap.sh` after installing.

`bootstrap.sh` checks out the frozen revision, `d0714887dd95d2990e0185fe1893523f3d600cc5`
(the `engine_revision` in `compatibility.yaml`). Earlier it pinned `3a565f27`, an older
engine commit; that was stale for the frozen tree and is fixed. `REV=<sha>` overrides it
for a deliberate re-bootstrap.

## Layout on the build Mac

All of it is under `~/shorebird-engine`.

| Path | What it is |
|---|---|
| `flutter/` (alias `347`) | The Flutter 3.47 tree, frozen at `d0714887`, the supported cell's engine. Never check out anything else here and never modify it. Its `engine/src/out` holds the supported cell's builds and other configs; treat all of it as read-only. |
| `flutter-350/` (alias `350`) | The Flutter 3.50.0 port, branch `selfhost/3.50`. An APFS clone of `flutter/` without `out/`. |
| `flutter-NAME/` | Further engine trees, made by `bin/new-branch NAME --engine`. |
| `bin/`, `env.sh` | Symlinks to `selfhost/flutter_fork/` (see above). |
| `logs/` | Sync and build logs, and `build.pid` while a build runs. |
| `~/Developer/shorebird-wt/` | Worktrees for framework-only work (`fl-NAME`), doc worktrees, and `tmp/heavy.lock`. |

An optional checkout of the Dart fork (`dart-sdk-lineage`) can sit beside them; a tree's own
`engine/src/flutter/third_party/dart` is what the build uses.

A tree is cloned with `cp -Rc` (APFS copy-on-write) one top-level entry at a time, skipping
`engine/src/out`. That costs almost no disk until files diverge.

## Scripts

Each prints its plan first. Run with `--dry-run` first to see the plan without changing
anything (`new-branch`, `sync`, `build` and `clean` take it; `build` also has `--gn-only`;
`promote` is read-only and has no such flag). They run with `set -euo pipefail` and are safe
to re-run, but "safe" is not "no-op": `sync` rewrites `.gclient` and runs `gclient sync` again.

- `bin/new-branch NAME [--from REF] [--engine]`: a worktree for framework work, or a cloned
  tree for engine work. The tree it copies from is `350` by default; it refuses the frozen
  tree, because a worktree there writes into its `.git`. Push the result to `origin`
  (`git push origin NAME`), never to the `flutter` remote, which is upstream Flutter.
- `bin/sync [TREE] [--dart-rev SHA|none]`: fetch, set the Dart revision in `.gclient`,
  `gclient sync`, check the Dart checkout, relink the Xcode SDKs. Refuses the frozen tree.
- `bin/build TREE CONFIG... [-j N]`: gn and ninja for `ios_release`, `ios_release_rb`,
  `host_release_arm64`, `host_release_arm64_ddm`. Refuses the frozen tree and refuses a
  placeholder Dart revision. Its `--allow-frozen` flag is owner-only: gn regenerates
  `ios_release` and the other supported-cell configs in place, which is the supported
  cell's own output.
- `bin/promote TREE [--repo DIR]`: read-only checks for a minted candidate (the pushed head,
  `engine.version`, the Dart and updater pins, then this repo's `bootstrap_closure_guard.sh`
  and `r12_revision_guard.sh`). It prints the `compatibility.yaml` change and never applies it.
- `bin/clean [TREE] [--configs a,b]`: list `out/` by size and age and delete only the configs
  you name. On the frozen tree it is **list-only**; it refuses `--configs` there. Configs
  named like the supported cell's (`ios_release`, `ios_release_rb`, `ios_release_rb_gen`,
  `host_release_arm64_ddm`, `host_release_arm64`, `engine_stamp.json`) are protected in any
  tree unless `--include-supported`. `--allow-frozen` is owner-only.

## Rules

- Heavy work (gclient sync, ninja) is serialized by `mkdir ~/Developer/shorebird-wt/tmp/heavy.lock`.
  The scripts take it and release it, and wait while it is held. A lock with no live
  `logs/build.pid` and no running sync is probably stale; ask before removing it.
  Run ninja at most `-j8`; the Mac is shared.
- Use the standalone Dart for tools, never a Dart bundled in another Flutter checkout.
- `bin/internal/engine.version` must name an engine we minted. A stock upstream hash sends
  the tool to upstream storage. `flutter-350` currently holds the stock 3.50.0 hash
  (`371f7720...`), so `bin/promote 350` fails on that check until the 3.50 engine is minted.
  That is expected; do not "fix" it by editing the check.
- Merge a new upstream Flutter with the base set to the upstream tag the carry was built on,
  because upstream releases are not always ancestors of each other and a plain `git merge`
  reports many false conflicts:
  `git merge-recursive TAG -- HEAD OLD_BRANCH`, resolve the conflicts, then `git commit`
  (the plumbing command leaves the result uncommitted and sets no `MERGE_HEAD`; write
  `.git/MERGE_HEAD` with the old branch's sha first if you want a two-parent merge).

## Owner-only steps

The whole promotion chain belongs to the owner, not only tags and releases: the
`compatibility.yaml` edit, the sealed cold bootstrap and release/patch discovery, the Linux
smoke, and any tag or branch for a cell (`selfhost-flutter-cell-*`, `selfhost/3.47-cell-*`
branches). A developer stops at a minted candidate that `bin/promote` passes and hands it
over. Nothing in this guide pushes a tag.

## Disk budget

A tree is about 18 GB without `out/`, 23 GB after a sync. A release iOS config is several GB,
a host config about the same. `sync` and `build` stop below 20 GB free, and
`new-branch --engine` below 10 GB. Time Machine local snapshots can make `df` understate
free space. Do not delete them; if a write fails for space, stop and report. Delete unused
`out/` configs with `bin/clean` (never on the frozen tree).

## Worktrees to prune

`git -C ~/shorebird-engine/flutter worktree list` shows worktrees whose scratchpad directory
no longer exists (marked prunable). `bin/clean flutter` prints the list and the prune command
but never runs it.
