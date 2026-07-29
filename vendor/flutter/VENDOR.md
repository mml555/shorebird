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

## Verified against a real clone (2026-07-29)

The snapshot has now been compared file-by-file against a fresh
`git clone` of `shorebirdtech/flutter` at `c15ef637` on the build host. **The
first comparison failed**, and the fixes are committed:

- **20 files were missing entirely.** `engine.version` (above) was not the only
  casualty of Flutter's *own* nested `.gitignore` files being vendored along with
  the source. Others were build-relevant:
  - `engine/src/flutter/shell/version/{BUILD.gn,version.cc,version.gni,version.h}`
    — dropped by a bare `version` pattern (`.gitignore:62`), which matches the
    directory. An entire GN target was absent.
  - `engine/src/flutter/third_party/{cpu_features,libjpeg-turbo}/BUILD.gn` —
    dropped by `/*` in `engine/src/flutter/third_party/.gitignore`.
  - `engine/src/flutter/shell/platform/fuchsia/flutter/build/*.py` — dropped by
    `*/**/build/`.
  - plus `.gradle/` fixtures, `Podfile.lock`s, `flutter_logo.png`,
    `GeneratedPluginRegistrant.java`, `dev/docs/lib/opensearch.xml`,
    `third_party/ninja/README.flutter`.

  All 20 are force-added now. **Anything under `vendor/flutter` needs
  `git add -f`** — the nested ignore rules are part of the vendored source and
  will silently drop files on every re-vendor.

- **3 files lose their CRLF line endings** and this is *not* fixed:
  `shell/platform/windows/windowsx_shim.h`,
  `third_party/accessibility/ax/platform/ax_platform_tree_manager.h`, and
  `tools/githooks/windows/pre-push`. The vendored `.gitattributes` declares
  `* text=auto` (line 2), and a `.gitattributes` deeper in the tree beats the
  repo root — so a root-level `vendor/flutter/** -text` exemption cannot take
  effect, and the only way to preserve the bytes would be editing the vendored
  attributes file, which would itself corrupt fidelity. Impact is nil: two
  Windows-only headers (compilers accept LF) and a shell hook that is *better*
  with LF. Recorded so nobody re-litigates it.

Result: **15,723/15,723 upstream files present, 15,720 byte-identical, 3
eol-normalized**, plus this `VENDOR.md`. Re-run after any re-vendor:

```bash
# on the build host, in the clone
git ls-files -z | xargs -0 sha256sum | LC_ALL=C sort -k2 > /tmp/clone.manifest
# here, in vendor/flutter
git ls-files -z | xargs -0 shasum -a 256 | LC_ALL=C sort -k2 > /tmp/snap.manifest
# compare paths AND hashes; beware paths containing spaces (awk/join will lie)
```

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

## What this snapshot cannot do (2026-07-29)

It is **not** a rebuildable engine. `DEPS` pins the Dart VM source to
`git@github.com:shorebirdtech/dart-sdk.git`, which is private — confirmed
anonymously, with an authenticated account, and by Shorebird's own docs ("private
currently"). The pinned sha is not in `dart-lang/sdk`, and the engine's Shorebird
hooks call two Dart APIs (`Dart_SnapshotDataSize`, `Dart_SnapshotInstrSize`) that
vanilla Dart 3.12.2 does not define — so the captured source does not compile
without that fork. Note also that `engine/src/flutter/third_party/dart` is a
gclient dep and was never part of this snapshot.

What the snapshot *is*: the framework, the modified engine C++, Shorebird's build
tooling, and `DEPS` — enough to read, diff, and port their changes, and enough to
rebuild if the fork ever opens. Full analysis and consequences:
`selfhost/ENGINE_BUILD.md`.

## Why this exists

If Shorebird ever closes source or takes down their repos, a license change is
**not retroactive**: this commit stays under its published license forever. This
snapshot means the worst case is "we have the source, we just need to build it"
rather than "we're frozen on whatever binaries we cached." It does NOT by itself
make us engine-from-source independent — building it still needs a build farm
(depot_tools, `gclient sync` of the DEPS-pinned deps, per-platform SDKs). See
`selfhost/ENGINE_BUILD.md`.

Some `third_party` directories are populated by `gclient` from the pinned `DEPS`
revisions rather than living here, so that part of the insurance holds via DEPS
rather than via this snapshot alone. That is fine for the public deps (Skia, ICU,
…) and **not** fine for `third_party/dart`, which DEPS points at a private repo —
see "What this snapshot cannot do" above. (The `BUILD.gn` files for
`cpu_features`, `libjpeg-turbo` and `ninja` *are* tracked here now; they had been
dropped by nested `.gitignore` rules.)

## To update

Re-vendor a newer branch tip, `git add -f bin/internal/engine.version`, bump
`selfhost/compatibility.yaml`, re-vendor `vendor/updater` if `DEPS` changed
`updater_rev`, and re-run the compatibility suite before declaring the new
revision supported.
