# Vendored: shorebirdtech/flutter (framework + engine source)

Pinned snapshot of Shorebird's Flutter monorepo fork — captured as **source
insurance**. Because Flutter merged the engine into the framework monorepo, this
one fork contains everything Shorebird-specific and irreplaceable:

- the **Flutter framework** fork (`packages/`, `bin/`, `dev/`, …),
- the **modified Flutter engine C++ source** (`engine/src/flutter/`) — this is
  what compiles into the prebuilt engine we otherwise consume,
- Shorebird's own tooling (`shorebird/`),
- `DEPS` — pins every third-party dependency revision (Skia, dart-sdk, …) and the
  updater commit.

## Provenance

- Upstream: https://github.com/shorebirdtech/flutter
- Branch tip captured: `flutter_release/3.44.8` (also `flutter_release_ex/3.44.8-rc0`,
  `shorebird/dev`, HEAD)
- Pinned commit: `c15ef6379403a0a55531a058bdb2c8e55bc05c98`
  ("chore: bump engine to 69f9831")
- Captured: 2026-07-29, shallow depth-1 (single snapshot; no history). The nested
  `.git` was removed — this is a flat source snapshot, not a working clone.

## Consistency (all three pins line up — see selfhost/compatibility.yaml)

| Pin | Value | Where |
|---|---|---|
| flutter_revision | `c15ef637…` | this snapshot's HEAD |
| engine_revision  | `69f9831c…` | `bin/internal/engine.version` here |
| updater_revision | `1f85c4ab…` | `DEPS` (`updater_rev`) == `vendor/updater` |

`bin/internal/engine.version` is **force-added** to git. Flutter's own
`.gitignore` (vendored with the snapshot, line 42) excludes it, so a plain
`git add` silently dropped it — which meant the one file naming the engine this
source builds was absent from a fresh clone of this repo, and the pin survived
only in `selfhost/compatibility.yaml` and in the upstream commit subject. Since
upstream disappearing is the exact scenario this snapshot insures against,
depending on upstream to recover the pin defeated the purpose. Keep the `-f` on
any future re-vendor.

## Previous capture

`309dd657…` (Flutter `flutter_release/3.44.7`, engine `e1eaecbc…`), captured
2026-07-24. Retained in git history; `selfhost/compatibility.yaml` keeps it under
`previous:` as the rollback target.

The net delta over the tracked snapshot was 15 files — small because 3.44.7 →
3.44.8 is a patch bump plus an engine revision. `DEPS` is byte-identical between
the two, so no `vendor/updater` re-vendor was needed (`updater_rev` did not
move). Note that GitHub's `309dd657...c15ef637` compare reports ~153 files: that
is three-dot, merge-base semantics across two release branches, not the net
difference between the commits.

## Why this exists

If Shorebird ever closes source or takes down their repos, a license change is
**not retroactive**: this commit stays under its published license forever. This
snapshot means the worst case is "we have the source, we just need to build it"
rather than "we're frozen on whatever binaries we cached." It does NOT by itself
make us engine-from-source independent — building it still needs a build farm
(depot_tools, `gclient sync` of the DEPS-pinned deps, per-platform SDKs). See
`selfhost/ENGINE_BUILD.md`.

Some `third_party` directories (`cpu_features`, `libjpeg-turbo`, `ninja`) are
excluded by Flutter's `.gitignore` because `gclient` fetches them. They are
recoverable from the pinned `DEPS` revisions, so the insurance still holds — but
it holds via DEPS, not via this snapshot alone.

## To update

Re-vendor a newer branch tip, `git add -f bin/internal/engine.version`, bump
`selfhost/compatibility.yaml`, re-vendor `vendor/updater` if `DEPS` changed
`updater_rev`, and re-run the compatibility suite before declaring the new
revision supported.
