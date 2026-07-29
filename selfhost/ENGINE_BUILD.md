# Building the native stack from source (Level 2)

Shorebird's two native components are the **Rust updater** (checks/downloads/
applies patches; embedded in the engine) and the **modified Flutter engine**
(loads patches at runtime). Owning them from source — rather than consuming
Shorebird's prebuilt artifacts — is the deepest level of independence. This doc
records what's done and precisely what the rest requires.

## Updater — DONE (vendored + builds from source)

- Vendored at `vendor/updater/` (pinned commit `1f85c4ab`; see `VENDOR.md` +
  `compatibility.yaml`).
- **Host build verified:** `cargo build --release -p updater` produces
  `libupdater.a` (staticlib), `libupdater.dylib` (cdylib), and `libupdater.rlib`
  — crate-type `["lib","cdylib","staticlib"]`. This is the linkable artifact the
  engine consumes.
- **Cross-compilation** for device targets: the Rust targets are installed
  (`aarch64-apple-ios`, `aarch64-linux-android`, `x86_64-apple-ios`, …). Each
  needs its platform C toolchain wired (the updater has C via `cc-rs`):
  - Android: install the NDK and set `CC_aarch64-linux-android` +
    `CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER` to the NDK's
    `aarch64-linux-android<api>-clang`, then
    `cargo build --release -p updater --target aarch64-linux-android`.
  - iOS: `cargo build --release -p updater --target aarch64-apple-ios` (Xcode CLT
    provides clang); combine per-arch with `lipo` as needed.
  (Host build already proves the Rust compiles; cross builds are a toolchain-
  configuration step, not new engineering.)

## Engine — SOURCE CAPTURED; BUILD infra-blocked in this environment

**Source is now vendored** (insurance against upstream going closed-source): the
Shorebird Flutter monorepo fork is snapshotted at `vendor/flutter/` — pinned
commit `c15ef637` (branch `flutter_release/3.44.8`). Because Flutter merged the
engine into the monorepo, that one fork contains the **framework**, the
**modified engine C++ source** (`engine/src/flutter/`), Shorebird's `shorebird/`
tooling, and `DEPS` (which pins every third-party revision and the updater commit
`1f85c4ab`, matching `vendor/updater`). A license change is not retroactive, so
this commit stays usable regardless of what upstream does later. See
`vendor/flutter/VENDOR.md`. What remains is *building* it, which is the large,
ongoing piece — essentially Shorebird's core operation.

**Requirements (not present here):**
- `depot_tools` (`gclient`, `fetch`, `gn`, `ninja`) — all currently MISSING.
- ~100 GB+ free disk (this machine had ~52 GB); `gclient sync` alone pulls
  ~30–50 GB of engine dependencies.
- Platform SDKs/toolchains: Android NDK, Xcode (iOS/macOS), and per-OS build
  hosts (you cannot build the Windows/Linux engine from macOS).
- Build time: ~1–4+ hours per platform/arch/mode on a strong machine.

**Flow (once infra exists):**
1. Use the captured monorepo source at `vendor/flutter` (pinned
   `flutter_revision` c15ef637; its `bin/internal/engine.version` is the pinned
   `engine_revision` 69f9831c, and its `DEPS` `updater_rev` equals
   `vendor/updater`'s `1f85c4ab`). No re-checkout needed — the source is already
   local.
2. `gclient sync` to fetch engine deps.
3. Build the engine with GN/Ninja for each `(platform, arch, mode)`, linking in
   our built `libupdater`.
4. Produce the artifact set + `artifacts_manifest.yaml` exactly as
   `download.shorebird.dev/shorebird/<engineRev>/…` serves them.
5. Publish those artifacts to our object store and point the CLI at them via
   `FLUTTER_STORAGE_BASE_URL` + `SHOREBIRD_STORAGE_BASE_URL` (the env overrides
   we already patched into `cache.dart` / `shorebird_process.dart`). At that
   point builds consume OUR engine, and the `selfhost/cdn` mirror is no longer
   even a passthrough to GCS.

**Automation:** `selfhost/engine/` provides turn-key scripts for exactly this
flow — `build.sh` delegates to Shorebird's own vendored CI build scripts
(`vendor/flutter/shorebird/ci/`), and `publish_to_store.sh` retargets their
upload from `gs://download.shorebird.dev` to our object store, preserving the
key layout. See `selfhost/engine/README.md`. (Grounded in the real build
scripts; runnable on a farm — not yet executed here for lack of build infra.)

## Bill of materials (what the build farm needs)

You cannot build every target from one machine — the engine must be built on
each target OS family. Minimum realistic setup:

| Resource | Spec / note |
|---|---|
| **Linux build host** | Primary host — builds Android + Linux engines. Many cores (build time scales with them), 16–32 GB RAM, **~150 GB free disk** (`gclient sync` alone pulls ~30–50 GB of deps). |
| **macOS build host** | Required for iOS + macOS engines (Xcode-only toolchain). Similar disk/RAM. |
| **Windows build host** | Required for the Windows engine. |
| `depot_tools` | `gclient`, `fetch`, `gn`, `ninja` — currently MISSING in this env. |
| Android NDK | For the Android engine and the updater cross-compile (`vendor/updater`). |
| Xcode + CLT | iOS/macOS engine + updater. |
| Build time | ~1–4+ hours **per (platform, arch, mode)** on a strong machine; the full matrix is many such builds. |
| CI (optional but wanted) | To make rebuilds repeatable and cache deps — a from-scratch matrix by hand is a lot of babysitting. |

## Build matrix

One engine artifact set per `(platform, arch, mode)`. Rough shape of the full
matrix you'd reproduce to match `download.shorebird.dev/shorebird/<engineRev>/`:

- **platforms/archs:** android (arm, arm64, x64), ios (arm64 + simulator),
  macos (arm64, x64), linux (x64, arm64), windows (x64).
- **modes:** release + profile (debug uses the local engine, not code-push).

You only need the cells for the platforms you actually ship — start with the one
or two you care about, not the whole grid.

## Ongoing cost: maintaining the fork (the part that never finishes)

Building once is finite; *staying current* is not. To move to a newer Flutter
version you would:

1. Re-vendor `vendor/flutter` at Shorebird's newer fork tip (or, if they've
   stopped, rebase their engine patches onto the new upstream Flutter yourself —
   Rust + C++ + build-config work).
2. Re-vendor `vendor/updater` if `DEPS` bumped `updater_rev`.
3. Rebuild the whole matrix.
4. Re-run the CLI-contract + native-updater compatibility suites
   (`selfhost/BEHAVIORAL_FINDINGS.md`) and only then bump
   `selfhost/compatibility.yaml`.

This cadence is the real cost of engine independence — budget it as an ongoing
engineering commitment, not a one-time project.

## Decision guide — build the engine only if:

- You need to **modify** the engine (custom behavior), **or**
- You need a Flutter version Shorebird **hasn't shipped** an engine for, **or**
- Shorebird has actually **gone closed / disappeared** and you must move forward
  from the captured `vendor/flutter` source.

Otherwise, **keep consuming the prebuilt engine via the mirror** (`selfhost/cdn`)
— it's already fully build-time-independent for a pinned revision at a fraction
of the cost, and the captured source (`vendor/flutter`) is your insurance for the
day one of the triggers above actually fires. Stand up the build only when it
does, on dedicated build infrastructure.
