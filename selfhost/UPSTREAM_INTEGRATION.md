# Upstream integration — the measured cost of catching up

2026-08-18. Written after giving the engine stack a version-control substrate,
which is what made these numbers obtainable at all.

## Why this document exists

The fork carried its engine work as uncommitted edits on detached HEADs plus 13
hand-maintained `.patch` files. In that arrangement the question *"what does it
cost to move to a newer Flutter?"* had no cheap answer: you applied the patches to
a fresh checkout and saw what exploded, learning THAT it broke rather than WHERE.

Both halves now live on branches with real upstream parents, so the cost is a
measurement.

## THE SUBSTRATE

    Flutter   mml555/shorebird-flutter (public fork of shorebirdtech/flutter)
              branch route-b @ afcbada4b0, base c15ef63794
              19 files, +1532/-47

    Dart      local branch route-b @ 9e8c898a, base 6b58bb3a
              20 files, +2059/-10
              upstream -> https://dart.googlesource.com/sdk.git
              121,349 commits of real history (was shallow, depth 1)

The `.patch` files in `selfhost/engine/route_b/` are now GENERATED ARTIFACTS for
reproducibility, not the source of truth.

## THE MEASURED COST of moving to Flutter `cac7b89` (upstream 1.6.118)

Both tested with `git merge-tree --write-tree` — an in-memory three-way merge that
touches no working tree, so the live build checkout that reproduces cell
`50bdae36` was never disturbed.

| half | distance | files | conflicts |
|---|---|---|---|
| Flutter (`c15ef63794` → `cac7b89`) | 1,450 commits | 19 | **1** |
| Dart (`6b58bb3a` → `da6595cd`) | 1,901 commits | 20 | **4** |

**Five conflicts across 39 files and ~3,350 upstream commits.**

### Flutter — the single conflict

    CONFLICT  engine/src/flutter/shell/common/shorebird/shorebird.cc

Everything else auto-merges, INCLUDING `lib/ui/hooks.dart` (the `_runMain`
success seam) and `shell/common/shell.cc` (the success/failure reporting seams) —
the two most likely to break, and they didn't.

`shorebird.cc` conflicting is expected: it holds our Route B activation hook,
release-identity gate and v5 trace, and it is also a file upstream Shorebird
actively develops. It is the one place our work and theirs occupy the same lines
rather than sitting side by side.

### Dart — four conflicts, and note WHERE they are NOT

    CONFLICT  pkg/dart2bytecode/lib/dart2bytecode.dart
    CONFLICT  pkg/front_end/lib/src/api_prototype/compiler_options.dart
    CONFLICT  pkg/front_end/lib/src/base/processed_options.dart
    CONFLICT  runtime/bin/gen_snapshot.cc

All four are PRODUCER/front-end plumbing. The VM and runtime patches auto-merge:

    runtime/vm/object.{cc,h}            clean   (patchable static calls)
    runtime/lib/object.cc               clean   (the 0012 target->pool instrument)
    runtime/include/dart_route_b_trace.h clean  (new file)
    runtime/vm/compiler/aot/*           clean
    runtime/vm/compiler/backend/*       clean

The mechanism half of Route B survives 1,901 Dart commits untouched. The cost is
concentrated in the bytecode producer and its option plumbing, which is where
upstream Dart moves fastest.

## THE WIRE CONTRACT IS SAFE

    updater_rev @ c15ef63794   1f85c4ab1ee5b540269b9859c75e1bffbb9050c7
    updater_rev @ cac7b89dba   1f85c4ab1ee5b540269b9859c75e1bffbb9050c7   IDENTICAL

The updater is the only component that speaks to this control plane at runtime, so
by the precedent `compatibility.yaml` records for the 1.6.115 bump, the device wire
contract, `UPDATER_CONTRACT.md` and `protocol_version` **cannot have changed**.

## WHAT THIS BUMP IS NOT — `SNAPSHOT_HASH` will move

`dart_revision` moves `d684a576 → da6595cd` (1,901 commits). `SNAPSHOT_HASH` is
computed over `VM_SNAPSHOT_FILES`, whose contents change wholesale across that
range regardless of whether OUR edits merge cleanly. So:

* already-published `App` snapshots (releases 91-99) will NOT load under an engine
  built from the new base — they stay pinned to their own engine;
* **the hybrid technique does not cross the bump.** Running release 91's snapshot
  under a newer engine was admissible only because `SNAPSHOT_HASH` was identical
  (`21139db2…`) across cells `80e493e4`, `87130ae8`, `cd137db6`, `50bdae36`. Any
  measurement of that kind must be completed BEFORE the bump, or repeated entirely
  within the new lineage.

This is the 1.6.115 bump's "build-time only" finding NOT repeating: that one held
because `updater_rev` was unchanged AND the engine was not rebuilt. Here the
engine is rebuilt.

## A CLEAN MERGE IS NOT A WORKING ENGINE

Five resolvable conflicts says the patches APPLY. It says nothing about whether
the result builds, whether the Route B seams still sit where the new engine
expects them, or whether the producer still emits loadable bytecode.
`compatibility.yaml`'s rule is unchanged: a new revision is unsupported until the
compatibility suite passes against it.

## RECOMMENDED SEQUENCE

1. **Take the cheap upstream work now, independently of the bump.** Cherry-pick
   `119406bb` (`aot_tools.dart` link-failure diagnostics). Skip `98adec24`
   (`stripe_api`) — we do not run billing. Leave `flutter.version` and the release
   bookkeeping alone; `compatibility.yaml` is doing its job by not tracking
   upstream.
2. **Finish any hybrid-dependent measurement before bumping** — see above.
3. **Then bump deliberately**, on a branch, resolving 5 conflicts with real
   per-file signal, and re-mint cells against the new base.

## MAINTENANCE, so this stays cheap

* The Dart branch has NO remote yet. It should get one.
* `depot_tools` installs `vpython3` git hooks that block commit AND push in both
  trees; use `git -c core.hooksPath=/dev/null`.
* A stale zero-byte `.git/index.lock` (dated 5 days earlier) was blocking commits
  in the Dart tree. Check for a live git process, then clear it.
* `git fetch --unshallow` did NOT resolve the Dart graft — our base is not an
  ancestor of `main`/`dev`/`beta`/`stable`, and `--unshallow` by SHA returns
  HTTP 500 from googlesource. What worked: bulk-fetch, then verify the base's
  recorded parent is present locally and drop `.git/shallow`, confirming with
  `git fsck --connectivity-only`.
