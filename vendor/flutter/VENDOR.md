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
- Branch tip captured: `flutter_release/3.44.7` (also `shorebird/dev`, HEAD)
- Pinned commit: `309dd6573a9fe716410489284cd325a34b950375`
  ("chore: bump engine to e1eaecb")
- Captured: 2026-07-24, shallow depth-1 (single snapshot; no history). The nested
  `.git` was removed — this is a flat source snapshot, not a working clone.

## Consistency (all three pins line up — see selfhost/compatibility.yaml)

| Pin | Value | Where |
|---|---|---|
| flutter_revision | `309dd657…` | this snapshot's HEAD |
| engine_revision  | `e1eaecbc…` | `bin/internal/engine.version` here |
| updater_revision | `1f85c4ab…` | `DEPS` (`updater_rev`) == `vendor/updater` |

## Why this exists

If Shorebird ever closes source or takes down their repos, a license change is
**not retroactive**: this commit stays under its published license forever. This
snapshot means the worst case is "we have the source, we just need to build it"
rather than "we're frozen on whatever binaries we cached." It does NOT by itself
make us engine-from-source independent — building it still needs a build farm
(depot_tools, `gclient sync` of the DEPS-pinned deps, per-platform SDKs). See
`selfhost/ENGINE_BUILD.md`.

## To update

Re-vendor a newer branch tip, bump `selfhost/compatibility.yaml`, re-vendor
`vendor/updater` if `DEPS` changed `updater_rev`, and re-run the compatibility
suite before declaring the new revision supported.
