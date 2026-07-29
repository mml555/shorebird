<!-- cspell:words jewgo rustc passwordless libfreetype dosbox androideabi modversion freetype armv -->

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

**Requirements (not present on this workstation — see "The build host we
actually use" below for the farm):**
- `depot_tools` (`gclient`, `fetch`, `gn`, `ninja`) — MISSING here.
- ~100 GB+ free disk (this machine had ~52 GB); `gclient sync` alone pulls
  ~30–50 GB of engine dependencies.
- Platform SDKs/toolchains: Android NDK, Xcode (iOS/macOS), and per-OS build
  hosts (you cannot build the Windows/Linux engine from macOS).
- Build time: ~1–4+ hours per platform/arch/mode on a strong machine.

**Flow (once infra exists):**
1. Build from a **git clone** of the pinned `flutter_revision` c15ef637 (whose
   `bin/internal/engine.version` is the pinned `engine_revision` 69f9831c, and
   whose `DEPS` `updater_rev` equals `vendor/updater`'s `1f85c4ab`).
   `vendor/flutter` is the same source but with `.git` removed, and gclient,
   `content_aware_hash.sh` and `update_engine_version.sh` all need real git —
   so the snapshot is the insurance copy, not the build tree. Compare the two
   file-by-file to prove the insurance is real — doing so on 2026-07-29 found 20
   files missing from the snapshot, since fixed (`vendor/flutter/VENDOR.md`).
2. `gclient sync` to fetch engine deps — `.gclient` with solution name `"."` at
   the checkout root, run from there. `DEPS` clones the Dart SDK fork over SSH,
   so either provide a key or add the `insteadOf` rewrite (scoped via
   `GIT_CONFIG_GLOBAL` on a shared host — see below).
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

## The build host we actually use (Hermes VPS, shared)

Azure `20.120.104.70`. **Co-tenant with a live Hermes deployment** — treat that
as a hard constraint, not a preference.

| Resource | Finding (audited 2026-07-29) | Implication |
|---|---|---|
| `/` | 29 GB total, ~17 GB free | Do **not** put the engine tree on root or `$HOME` |
| `/data` (`nvme0n2`) | 503 GB, ~410 GB free | All Shorebird work under `/data/shorebird-engine/` |
| Spare `nvme1n1` | 220 GB ext4, **unmounted** | Leave alone unless explicitly approved |
| RAM | 82 GiB, ~71 GiB available | Comfortable |
| CPU | **4 vCPU** | Cap ninja at `-j2`/`-j3`; prefer off-peak |
| Hermes | `hermes-gateway` active, `/data/hermes`, ~21 GiB RSS | Never touch |
| Present | Flutter 3.44.4, NDK 28.2, Java 17, Android SDK under `/data/android`, Docker, git 2.43, python3, unzip, curl | The engine build brings its *own* NDK/SDK via gclient; do **not** overwrite `/data/android/flutter` |
| Present | **Rust 1.96 at `~/.cargo`**, with `aarch64-linux-android`, `armv7-linux-androideabi`, `x86_64-linux-android` already added | Only visible in a **login** shell: the `. "$HOME/.cargo/env"` line lives in `~/.profile`/`~/.bashrc`, so `ssh host 'cargo --version'` reports it missing while `ssh host 'bash -lc ...'` finds it. Don't conclude a tool is absent from a non-interactive probe. |
| Was missing | `pkg-config`, `zip`, `libfreetype6-dev` | Installed 2026-07-29 with consent (`pkg-config --modversion freetype2` → 26.1.20) |
| Missing | depot_tools, engine checkout | Install only under `/data/shorebird-engine/` |
| sudo | passwordless | Available, but system packages are a shared-host change — get consent, don't install as a side effect |

**Keep the toolchain out of the shared account.** Rust and depot_tools install
without sudo into the work tree, and git's SSH rewrite can be scoped to a
throwaway config file, so nothing leaks into `~` where Hermes' own tooling lives:

```bash
# /data/shorebird-engine/env.sh — source this, never add it to ~/.profile
export CARGO_HOME=/data/shorebird-engine/cargo
export RUSTUP_HOME=/data/shorebird-engine/rustup
export GIT_CONFIG_GLOBAL=/data/shorebird-engine/gitconfig   # git >= 2.32
export PATH="/data/shorebird-engine/depot_tools:$CARGO_HOME/bin:$PATH"
```

`GIT_CONFIG_GLOBAL` **redirects** `git config --global` at that file, so:

```bash
source /data/shorebird-engine/env.sh
git config --global url."https://github.com/".insteadOf git@github.com:
```

writes the rewrite `gclient` needs for the Dart SDK dep into
`/data/shorebird-engine/gitconfig` and leaves `~/.gitconfig` untouched. (Plain
`git config` without `--global` fails with "not in a git directory" — it targets
a repo, not the redirected file.)

The flip side: the isolated file *replaces* `~/.gitconfig` for that shell, so the
account's `gh` credential helper is not available there. Fine for public repos;
if `shorebirdtech/dart-sdk` turns out to be private, the credential has to be
added to the isolated config too.

`pkg-config` / `libfreetype6-dev` come from Flutter's
`install-build-deps-linux-desktop.sh`; `zip` is used by `publish_to_store.sh`
(the cell + overlay path doesn't need it — ninja produces `zip_archives/`
itself). All three are installed on this host now.

**Rust: use ours, not the account's.** The account already has 1.96 with the
Android targets, but the build shell puts `$CARGO_HOME/bin` first so the
work-tree toolchain (1.97.1, installed with `--no-modify-path`) wins. That keeps
our builds independent of a toolchain Hermes may change underneath us. If a
newer rustc ever breaks the updater build, dropping `$CARGO_HOME/bin` from `PATH`
falls back to the account's 1.96 — one line in `env.sh`.

### Bootstrap state (2026-07-29)

Done on the host, all under `/data/shorebird-engine/`, all `rm -rf` reversible:

| Item | State |
|---|---|
| `env.sh` | isolated `CARGO_HOME` / `RUSTUP_HOME` / `GIT_CONFIG_GLOBAL` + `PATH` |
| `gitconfig` | `insteadOf` rewrite for the Dart SDK SSH remote; `~/.gitconfig` untouched |
| `depot_tools` | cloned (104 MB) |
| Rust | 1.97.1 in-tree with `aarch64-linux-android` (`--no-modify-path`) |
| `src/flutter` | `shorebirdtech/flutter` @ `c15ef637`, single-branch (195 MB + 362 MB `.git`), `engine.version` = `69f9831c` |
| `.gclient` | at the checkout root, solution `"."`, url → the Shorebird fork |
| apt | `pkg-config`, `zip`, `libfreetype6-dev` installed |
| Insurance test | run — found and fixed 20 files missing from `vendor/flutter` (see its `VENDOR.md`) |
| `hermes-gateway` | `active` after every step |

**Not started — the long step.** `gclient sync` (~40–60 GB, hours):

```bash
source /data/shorebird-engine/env.sh
cd /data/shorebird-engine/src/flutter
nice -n 10 gclient sync --no-history 2>&1 | tee /data/shorebird-engine/logs/sync.log
```

**Parallelism, measured.** At the time of the audit the host was already running
`dosbox-x` at ~96% of one core plus a `qemu-system-x86` (load ~1.15 of 4). `-j3`
would saturate the box; check `uptime` and pick `-j2` when Hermes is busy.

Linux host → Android (and Linux) engines only. iOS/macOS still need a Mac.

**Co-tenancy rules.** No edits to `/data/hermes`, `/data/ter`, Hermes systemd
units, or Docker/noVNC state. `depot_tools` goes on `PATH` via a *sourced* env
file, not `~/.profile` — the account is shared. After every invasive step,
`systemctl --user is-active hermes-gateway` must still print `active`.

## Experimental engines vs the supported pin

An engine we build gets its **own 40-hex hash** (convention: the git sha of the
engine branch it was built from), so it can never be confused with or overwrite
the revision in `compatibility.yaml`. Only the Android arm64 binaries actually
differ from that pin, so the mirror serves a mixed set — see
`selfhost/cdn/README.md` and `selfhost/engine/overlay_publish.sh`. Artifacts the
build owns 404 if unpublished rather than silently resolving to Shorebird's
stock bytes.

Two facts that shape what a minimal build can host:

- `gen_snapshot`, `aot-tools.dill` and the `patch` CLI come from the pinned
  revision, so a mixed set is only valid while `dart_sdk_revision` in `DEPS` is
  untouched and the snapshot/patch contract is unchanged.
- The engine links the updater from `engine/src/flutter/third_party/updater`
  @ `1f85c4ab`, fetched by **gclient** — *not* from `vendor/updater`. Changing
  the updater means pointing that dep at a fork, which is Phase 2 work, kept out
  of the first build so a device failure is unambiguous.

There is no `shorebird_runtime` GN arg at this revision (the hooks are
unconditional via `shorebird_updater_supported`), despite
`vendor/flutter/shorebird/docs/BUILDING.md` still passing it in its iOS example.

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
