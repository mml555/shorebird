# Engine build + publish toolkit (Path 2)

Turn-key automation for building the Shorebird engine **from the captured source**
(`vendor/flutter`) and publishing it to **our own object store** so builds consume
our engine instead of `download.shorebird.dev`. This is the last rung of the
independence ladder (see `selfhost/ENGINE_BUILD.md`).

> **Status — corrected for the monorepo layout; the build itself is not yet run
> here.** These scripts sit on top of Shorebird's *own* vendored CI
> (`vendor/flutter/shorebird/ci/`), which is the real, authoritative build
> process. The engine build needs a farm (depot_tools, ~150 GB disk, per-OS
> hosts) that this machine does not have, so treat the first real run as a
> bring-up.
>
> The gclient bootstrap documented below was **wrong** until it was checked
> against this revision's `DEPS`: the solution name is `"."` at the checkout
> root (not `flutter` in its parent), `gclient sync` runs from the checkout root
> (not `engine/src`), the sync marker lives under `engine/src/flutter/third_party`
> (not `engine/src/third_party`), and the Dart SDK dep needs an SSH remote or a
> rewrite. Argument handling, prereq checks and the `--cell` path have been
> exercised; the ninja build has not.

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

- **depot_tools** on `PATH` (`gclient`, `gn`, `ninja`), Rust/cargo with the
  target triple installed (`rustup target add aarch64-linux-android` for Android
  arm64). The **NDK and Android SDK come from `gclient`**, not the host —
  `download_android_deps` defaults to true on linux-x64 and mac. `cargo-ndk` is
  *not* needed: `build_rust_updater.py` drives cargo itself and sets
  `CC`/`AR`/`CARGO_TARGET_*_LINKER` from the gclient NDK. (The comment in
  `shorebird/ci/internal/linux_setup.sh` predates that script.)
- `~150 GB` free disk for a full shard; ~100 GB for a single cell. `gclient sync`
  alone is ~40–60 GB.
- **A real git checkout.** `vendor/flutter` is a history-less snapshot with its
  `.git` removed; gclient, `content_aware_hash.sh` and `update_engine_version.sh`
  all need git. On a farm, clone the pinned revision and pass `--root`.
- For the object-store publish path: **`mc`** (MinIO client) or `aws` CLI.
- You build on the **target OS family** — macOS for iOS/macOS, Linux for
  Android/Linux, Windows for Windows. No cross-OS engine builds.

### gclient bootstrap (the part that is easy to get wrong)

Flutter's `DEPS` does not set `use_relative_paths` and its entries are
`engine/src/flutter/third_party/...` — relative to the **gclient root**. So the
solution name is `"."` and `.gclient` lives at the **root of the Flutter
checkout**, and `gclient sync` runs from there (not from `engine/src`). See
`.gclient.template`, or copy the checkout's own
`engine/scripts/standard.gclient` and change the `url`.

`DEPS` also clones the Dart SDK fork over **SSH**
(`dart_sdk_git = git@github.com:shorebirdtech/dart-sdk.git`). Either put a GitHub
key on the build host or rewrite the remote:

```bash
git config --global url."https://github.com/".insteadOf git@github.com:
```

On a host shared with other services, redirect git's "global" config (and the
whole toolchain) into the work tree first, so `--global` writes there and not to
`~/.gitconfig`:

```bash
export GIT_CONFIG_GLOBAL=/data/shorebird-engine/gitconfig   # git >= 2.32
export CARGO_HOME=/data/shorebird-engine/cargo
export RUSTUP_HOME=/data/shorebird-engine/rustup
```

## Usage

```bash
# 0. one-time: clone the pinned revision, .gclient at its root, gclient sync
#    (see "gclient bootstrap" above). build.sh checks this is done.

# 1a. minimal experimental cell — just Android arm64 release (Linux host)
selfhost/engine/build.sh --cell android-arm64 --root /path/to/checkout --jobs 3

# 1b. or the full vendored CI shard for this host
selfhost/engine/build.sh --root /path/to/checkout

# 2a. publish an experimental engine into the CDN mirror's overlay, under its
#     own hash, falling back to the pinned revision for what it didn't build
selfhost/engine/overlay_publish.sh --hash <expHash> --root /path/to/checkout

# 2b. or publish a full artifact set to an object store
S3_ENDPOINT=https://minio.yourco.com S3_BUCKET=engine-artifacts \
  selfhost/engine/publish_to_store.sh <engineHash>

# 3. point the CLI at whichever store (mirror for 2a, object store for 2b)
export FLUTTER_STORAGE_BASE_URL=https://engine.yourco.com
export SHOREBIRD_STORAGE_BASE_URL=https://engine.yourco.com
export SHOREBIRD_STORAGE_BUCKET=engine-artifacts
# now `shorebird release` builds against YOUR engine.
```

## Minimal cell vs full shard

`--cell android-arm64` builds the one configuration that carries an engine change
to an Android arm64 device:

```
gn --no-rbe --no-enable-unittests --android --android-cpu=arm64 --runtime-mode=release
ninja -C out/android_release_arm64 default gen_snapshot
```

`libflutter.so` lands in both `android-arm64-release/artifacts.zip` and the Maven
`arm64_v8a_release` jar — and since Gradle resolves the Maven artifact, **that jar
is what actually puts your engine in the APK**.

The full Linux shard additionally builds arm32, x64, `host_debug`, and
`host_release` with `--no-prebuilt-dart-sdk` (i.e. all of Dart from source). None
of that is needed to prove an arm64 device loop, and on a small shared host the
Dart build dominates the wall clock.

**The trade:** a cell build is published as a *mixed* set — your arm64 binaries
plus the pinned revision's everything-else. That is sound only while
`dart_sdk_revision` in `DEPS` is untouched and the snapshot/patch contract is
unchanged, because `gen_snapshot`, `aot-tools.dill` and the `patch` CLI all come
from the pinned revision. Work that changes the Dart SDK or the snapshot format
must graduate to the full shard.

**It is also not optional for a Mac-driven build.** A `shorebird release android`
run from macOS fetches `android-arm64-release/darwin-x64.zip` — the *host*
`gen_snapshot`, a Mac binary. No Linux build can produce it, so even the full
Linux shard leaves that artifact stock until you add a macOS build host.

There is **no `shorebird_runtime` GN arg** at this revision; the Shorebird hooks
are unconditional, gated in GN by `shorebird_updater_supported`.
`shorebird/docs/BUILDING.md`'s iOS example still passes it — don't copy that.

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
