<!-- cspell:words jewgo rustc passwordless libfreetype dosbox androideabi modversion freetype armv dartsdk googlesource rebuildable embedders prebuilts -->

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
`vendor/flutter/VENDOR.md`. What remains is *building* it — and as of 2026-07-29
that is **blocked, not merely expensive**: the build needs Shorebird's private
Dart VM fork. See "BLOCKER" below before planning any engine work.

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

## BLOCKER: the engine source cannot be compiled — the Dart VM fork is private

Found 2026-07-29 on the first real `gclient sync`, which failed after 8 seconds.

`DEPS` pins the Dart VM **source** to a private repo:

```
"dart_sdk_git": "git@github.com:shorebirdtech/dart-sdk.git",
"dart_sdk_revision": "db98bdaa9d8f8e2250ff83d24abcaf775807244c",
'engine/src/flutter/third_party/dart': Var('dart_sdk_git') + '@' + Var('dart_sdk_revision'),
```

Evidence it is genuinely unavailable, not a misconfiguration on our side:

| Probe | Result |
|---|---|
| `https://github.com/shorebirdtech/dart-sdk` anonymously | 404 (`flutter` and `updater` return 200) |
| Same via an authenticated GitHub account | 404 |
| Name variants `dart-sdk`/`dart_sdk`/`sdk`/`dartsdk`/`dart` via API (follows renames) | 404 |
| The org's 34 public repos | no Dart fork among them |
| `git fetch dart-lang/sdk db98bdaa…` | `upload-pack: not our ref` |
| `gs://shorebird-dart-sdk-prebuilt` (the macos-arm64 prebuilt) | 401, anonymous listing denied |

Shorebird's own docs confirm it, and say it is meant to open eventually:

> "Shorebird's Dart SDK fork is private currently. It will likely be public in
> the future, and there are plans to upstream many changes as the team grows and
> the product matures." — <https://docs.shorebird.dev/code-push/system-architecture/>

This is **not** a 3.44.8 regression: the previous supported pin `309dd657` names
the same private fork at the same revision.

### Substituting vanilla Dart does not work

Vanilla Flutter 3.44.8 pins `third_party/dart` at
`dart.googlesource.com/sdk@d684a576` — "Version 3.12.2", the same Dart version
`compatibility.yaml` records for this pin, and it fetches fine. But the Shorebird
engine hooks call two Dart APIs that **do not exist anywhere in vanilla Dart
3.12.2**:

- `Dart_SnapshotDataSize` and `Dart_SnapshotInstrSize`
  (`shell/common/shorebird/snapshots_data_handle.cc:10,17`)

They size the four blobs — `vm_data`, `iso_data`, `vm_instructions`,
`iso_instructions` — that the updater's bipatch state machine treats as one
contiguous stream. So a vanilla-Dart tree fails at compile time, cheaply and
unambiguously.

Two further considerations before anyone attempts to reimplement them:

- Those two are the *only* Dart APIs the Shorebird engine hooks use, and the
  fork's documented purpose (an interpreter for patched code) is the **iOS**
  mechanism — our own Android patcher never touches the linker
  (`aotTools`/`linkPercentage` appear only in the Apple patchers). So an
  Android-only path plausibly needs just those accessors.
- But the mixed artifact set assumes our `libflutter.so` can load snapshots
  produced by **Shorebird's** pinned `gen_snapshot`. Dart version-locks snapshots
  against a hash of the VM sources, so a VM that isn't their fork may simply
  refuse them. That risk is unmeasurable without the fork.

### How much of this could we build ourselves?

Measured, not guessed. Shorebird's **public** delta over vanilla Flutter 3.44.8
(`git diff 3.44.8 c15ef637`) is **144 files, +8,132/−1,110**, of which the engine
is **56 files, +3,053/−38** — almost entirely *new* files under
`shell/common/shorebird/` and `runtime/shorebird/`, plus small hooks in the
platform embedders, `runtime/dart_snapshot.cc` (29 lines) and
`lib/snapshot/BUILD.gn`. We already have all of it.

What their private Dart fork must provide, and what vanilla 3.12.2 already has:

| Their addition | Vanilla status | Cost to us |
|---|---|---|
| `Dart_SnapshotDataSize` / `Dart_SnapshotInstrSize` | No public C API, but the internals exist: `Snapshot::length()` (`runtime/vm/snapshot.h:57`) and `Image`'s `ImageSize` header field (`runtime/vm/image_snapshot.h:45`) | Thin wrappers — tens of lines |
| `analyze_snapshot --dump_blobs` | `analyze_snapshot.cc` present, no blob dumping | Moderate; only needed to *create* patches locally |
| `pkg/aot_tools` — the linker (`link`, `link_metadata`, `dump_blobs`), emits `.vmcode` + `linkPercentage` | Absent | Large. Their real IP — **and iOS-only** (`useLinker` appears only in the Apple patchers) |
| VM execution of patched code via an interpreter | **Present upstream**: `runtime/vm/interpreter.cc` (4,567 lines) + `bytecode_reader.cc` (3,120), behind `DART_DYNAMIC_MODULES`, ©2024 — plus a `--dart-dynamic-modules` GN flag (`tools/gn:685`) and Flutter CI builders for it | Their fork predates this; upstream is now a viable substrate |

So the work splits by platform, and the split is favorable:

- **Android — small.** Android patches ship real machine code; the linker is never
  invoked. The engine's only Dart-fork dependency is the two accessors. So "our own
  fork" is vanilla Dart 3.12.2 plus ~50 lines. Build our own `gen_snapshot` from
  the same VM and drive the release from Linux, and the artifact set is
  self-consistent — which also removes the snapshot version-lock risk of mixing our
  VM with their prebuilt `gen_snapshot`. Realistic: a day of code, a week to a
  patched app on device including build iterations. Rebasing a 50-line patch per
  Dart version is *less* maintenance than tracking their fork.
- **iOS — large.** Requires reimplementing the linker: diff two AOT snapshots,
  decide what can reuse original instructions, emit `.vmcode`. Months, and the part
  most likely to churn per Dart version.
- **Improving on their interpreter — research-grade but newly tractable**, because
  upstream's dynamic-modules interpreter is public and wired into the engine's GN.
  Building on that beats replicating a 2022-era fork.

Caveat: this bounds the dependency by what the *public* engine calls. If their fork
also alters snapshot layout in ways Android patch *application* assumes, we would
only discover it on device — but building both sides ourselves keeps us
self-consistent, so the risk lands on interop with *their* prebuilts, which the
experimental cell does not need.

### Device result (2026-07-29): GREEN — full release/patch/rollback cycle

`engine_from_source` is proven on hardware. Engine `dabf1837` (our Dart VM
`4bd36869` = vanilla 3.12.2 + 57 lines), release `1.0.2+3` built on the Linux box,
physical CPH2551:

| Step | Evidence |
|---|---|
| APK carries our engine | `lib/arm64-v8a/libflutter.so` sha256 `0da873a2…` == our build |
| Boots | process alive, `[shorebird] Reporting successful launch`, Impeller/Vulkan up |
| Patch delivered | patch 1, arm64 66.93 KB, downloaded from this control plane |
| Patch applied | `output_written=3146640b` — exactly `libapp.so`'s size |
| Patched code runs | our marker printed from code absent from the installed APK |
| Rollback | `rolled_back_patch_numbers: [1]`, marker gone on the next launch |

Note the rollback timing: the launch that *learns* about the rollback still runs
the patch, and the revert takes effect on the launch after. That matches
`UPDATER_CONTRACT.md` and is not a bug.

**What it took beyond the minimal cell** — the whole host toolchain from our tree
(`out/host_release` for `dart_sdk` + `flutter_patched_sdk_product`, `out/host_debug`
for `linux-x64/artifacts.zip` = `frontend_server`), releases driven from Linux, and
`--no-tree-shake-icons`. Details in `compatibility.yaml`'s
`experimental.build_host_constraints`.

### How it failed first (2026-07-29): a mixed set cannot boot

Engine `dabf1837` was built, published, and consumed by a real
`shorebird release android`. The APK's `lib/arm64-v8a/libflutter.so` is
byte-identical to our build (`sha256 0da873a2…`, 13,840,240 B), and on device the
Shorebird plumbing came alive — the updater reached this control plane and got a
real answer. Then the app died at launch:

```
[FATAL:flutter/runtime/dart_vm_initializer.cc(88)] Error while initializing the
Dart VM: Wrong full snapshot version, expected '8889ac39…' found '839937dd…'
```

**Why, exactly:** `tools/make_version.py` computes the snapshot version as an MD5
over `VM_SNAPSHOT_FILES`, and that list contains `dart_api_impl.cc` and
`image_snapshot.h` — two of the three files our 57-line patch touches. So our VM
refuses any snapshot not produced by a `gen_snapshot` built from *our* tree.

The consequence is structural, not a bug to fix:

- There is **no** way to be snapshot-compatible with Shorebird's prebuilt
  `gen_snapshot` while running a non-Shorebird VM. Their `libflutter.so` and their
  `gen_snapshot` share their VM; ours must share ours.
- Therefore an experimental engine needs a **matching host toolchain from the same
  tree**: `gen_snapshot`, `flutter_patched_sdk_product`, `dart-sdk-<host>`, and
  `aot-tools.dill` — not just `libflutter.so`.
- And since we build on Linux, releases must be **driven from Linux**: a macOS host
  fetches `android-arm64-release/darwin-x64.zip` for `gen_snapshot`, which only a
  macOS engine build can produce.

`selfhost/cdn/nginx.conf` now treats all of those as overlay-owned, so a missing
one 404s during the build instead of yielding an app that installs and then
crashes. Two further corrections came out of the same run: nginx must reach GCS
through a **variable** upstream host (a literal hostname is resolved once at
startup including AAAA records, so a container without IPv6 egress intermittently
502s), and Maven modules **cannot** be hash-rewritten by a proxy at all, because
Gradle validates the version inside the `.pom` body — every module must be
materialized locally under our hash, including ABIs we did not build.

**So the minimal cell was enough to prove compile + link + publish + serve, and is
not enough to boot.** Reaching a green device test means building the
`host_release` targets too (`dart_sdk`, `flutter_patched_sdk`), which is the
from-source Dart build the minimal cell was chosen to avoid — i.e. this work
graduates to the full shard, exactly where this document said it would.

### What this does and does not put at risk

| Capability | Contingent on Shorebird? |
|---|---|
| Runtime code push (device → this control plane) | **No.** The updater is public and vendored; the protocol is ours; device-verified. |
| Building releases/patches on the current pin | **No.** The mirror holds the full `69f9831c` set on local disk. |
| Adopting a *newer* Flutter version | Yes — on them continuing to publish prebuilt engines (which they do, publicly). Not on source. |
| Building a **modified** engine (this whole backlog) | **Yes — blocked today.** |
| Surviving Shorebird disappearing | **Partially blocked.** We hold the engine C++ and the updater, but not the Dart VM fork needed to compile them. |

So the self-hosted control plane is not at risk. What is affected is the
*insurance* claim below and the experimental-engine ambition. Adjust expectations
accordingly: `vendor/flutter` is real insurance for **the framework and the engine
C++**, and a starting point for a port, but it is not a rebuildable engine.

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
