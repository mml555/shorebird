# Engine build + publish toolkit (Path 2)

Turn-key automation for building the Shorebird engine **from the captured source**
(`vendor/flutter`) and publishing it to **our own object store** so builds consume
our engine instead of `download.shorebird.dev`. This is the last rung of the
independence ladder (see `selfhost/ENGINE_BUILD.md`).

> **Status — grounded, not yet executed here.** These scripts are built directly
> on top of Shorebird's *own* vendored CI (`vendor/flutter/shorebird/ci/`), which
> is the real, authoritative build process. They have **not** been run in this
> environment because the engine build needs a build farm (depot_tools, ~150 GB
> disk, per-OS hosts) that isn't present. Treat the first real run as a
> bring-up: expect to adjust toolchain paths for your farm.

## How it works (the key insight)

We do **not** re-author the engine build. Shorebird ships their exact build in
the fork we captured:

- `vendor/flutter/shorebird/ci/{mac,linux,win}_build_and_upload.sh` — entrypoints
- `vendor/flutter/shorebird/ci/internal/*_setup.sh` / `*_build.sh` — real steps
- `vendor/flutter/shorebird/ci/internal/generate_manifest.sh` — the manifest
- `vendor/flutter/shorebird/docs/BUILDING.md` — their build notes

The only Shorebird-specific thing those scripts do that we must change is the
**upload target**: their `*_upload.sh` does `gsutil cp … gs://download.shorebird.dev/…`.
We keep their *build* verbatim and swap in our own *publish* to our object store,
preserving the exact key layout the CLI/updater expect.

The updater no longer needs a separate build step — it's compiled *inside* the
GN build via `//flutter/shell/common/shorebird:build_rust_updater` (only the
standalone `patch` CLI is built with cargo, which the vendored scripts already do).

## Storage layout (must be preserved exactly)

The CLI's `FLUTTER_STORAGE_BASE_URL` / `SHOREBIRD_STORAGE_BASE_URL` (already
patched into `cache.dart` / `shorebird_process.dart`) resolve artifacts under two
roots. We publish to the same two paths in our bucket:

```
<bucket>/flutter_infra_release/flutter/<engineHash>/…   # dart-sdk, gen_snapshot, frameworks, artifacts.zip
<bucket>/shorebird/<engineHash>/…                       # patch-<plat>.zip + artifacts_manifest.yaml
```

`artifacts_manifest.yaml` lists every artifact the proxy will serve — anything
not in it is ignored, so the manifest and the uploads must agree.

## One-time farm prerequisites

- **depot_tools** on `PATH` (`gclient`, `gn`, `ninja`), Rust/cargo, and the
  platform toolchains (Android NDK; Xcode on macOS). See `ENGINE_BUILD.md` BOM.
- `~150 GB` free disk. A `gclient sync` of the DEPS-pinned dependencies.
- **`mc`** (MinIO client) or `aws` CLI configured for your object store, for the
  publish step.
- You build on the **target OS family** — macOS for iOS/macOS, Linux for
  Android/Linux, Windows for Windows. No cross-OS engine builds.

## Usage

```bash
# 0. one-time: gclient checkout + sync of vendor/flutter (see .gclient.template
#    and Flutter's engine setup docs). build.sh checks this is done.

# 1. build (delegates to Shorebird's vendored ci/internal/<host>_build.sh)
selfhost/engine/build.sh            # auto-detects host os; reads pins from compatibility.yaml

# 2. publish the built artifacts to OUR object store (retargeted upload)
S3_ENDPOINT=https://minio.yourco.com S3_BUCKET=engine-artifacts \
  selfhost/engine/publish_to_store.sh <engineHash>

# 3. point the CLI at our engine store (instead of the CDN passthrough mirror)
export FLUTTER_STORAGE_BASE_URL=https://engine.yourco.com
export SHOREBIRD_STORAGE_BASE_URL=https://engine.yourco.com
export SHOREBIRD_STORAGE_BUCKET=engine-artifacts
# now `shorebird release` builds against YOUR engine.
```

## Relationship to the CDN mirror

- **Mirror (`selfhost/cdn`)** = passthrough cache of Shorebird's *prebuilt* engine.
  Build-time independent for a pinned revision, cheap, recommended default.
- **This toolkit** = you *produce* the engine, so you no longer depend on
  Shorebird having published binaries at all. Only needed if you must modify the
  engine or support a Flutter version Shorebird hasn't shipped (the decision
  triggers in `ENGINE_BUILD.md`).

Both publish to the same key layout, so the CLI env overrides are identical —
you're just changing whether the bytes originate from Shorebird's GCS (mirror) or
your own build (this toolkit).
