<!-- cspell:words dartsdk prebuilts bidiff vmcode aot daemonized crashprobe -->

# Handoff — engine improvements (as of 2026-07-30)

**Next up:** [`ENGINE_PARITY_PLAN.md`](ENGINE_PARITY_PLAN.md) — the staged plan
for getting our engine changes onto iOS as well as Android, and for being able to
add the next one without upstream. Start there.
([`FORK_REBUILD.md`](FORK_REBUILD.md) is the earlier scoping it supersedes.)

Working notes for whoever picks this up next. Product documentation lives in
[`ENGINE_IMPROVEMENTS.md`](ENGINE_IMPROVEMENTS.md) (front door),
[`ENGINE_BUILD.md`](ENGINE_BUILD.md) (evidence + constraints) and
[`EXPERIMENTAL_ENGINE.md`](EXPERIMENTAL_ENGINE.md) (roadmap + layer analysis).
This file is the "where to put your hands" version.

## The one thing to internalize first

**`main` and the supported pin are untouched, and must stay that way.** Everything
ships on Shorebird's prebuilt engine. Our own engine exists, is device-verified,
and is deliberately inert: `experimental_hashes.map` is checked in empty, so the
mirror is a pure passthrough cache. Verify before and after any change you make:

```bash
python3 - <<'PY'
import subprocess, yaml
def load(r): return yaml.safe_load(subprocess.run(
    ['git','show',f'{r}:selfhost/compatibility.yaml'],capture_output=True,text=True,check=True).stdout)
m,b = load('main'), load('HEAD')
print('pin identical:', m['shorebird']==b['shorebird'],
      '| independence identical:', m['independence']==b['independence'])
PY
```

Branch: `feat/engine-improvements`, off `main` and now pushed to `fork`
(`mml555/shorebird`) — it is no longer single-copy on one Mac.

## Where each track stands

### Track A — crash reporting

**Done:** ingestion + retention, and retention is now actually wired.

| Piece | Where |
|---|---|
| `crash_reports` table | `code_push_server/lib/src/repository.dart`, migration **8** in `_migrations` |
| `insertCrashReport`, `crashReports` | same file, "Crash reports" section |
| `POST /crashes` (device, unauthenticated) | `lib/src/api.dart` → `_crashesReport` |
| `GET /api/v1/apps/{id}/crashes` (authed) | same file → `_getCrashes` |
| Symbol retention | `shorebird_cli/lib/src/code_push_client_wrapper.dart` → `createPatchSymbolArtifact`, tag `symbolsArch` |
| Symbol **source** | `commands/patch/patcher.dart` → `debugSymbolsDirectory()` |
| Packaging + upload | `patch_command.dart` → `_packageSidecars`, then `publishPatch(sidecars: …)` |

Retention has **no flag of its own**: `--split-debug-info` is the opt-in, since
that is what makes any patcher emit symbols at all. It is uniform across
platforms — Flutter writes symbols there on Android, and the Apple patchers point
gen_snapshot's `--save-debugging-info` at the same directory.

One subtlety worth not re-discovering: the patch command **injects**
`--split-debug-info` itself when it has to enable `--obfuscate` to match the
release, so `debugSymbolsDirectory()` also reads `extraBuildArgs`. Reading
`argResults` alone would retain nothing for obfuscated patches — the ones that
most need symbolication.

Sidecars are **not fatal**: a patch whose symbols could not be packaged is still
a valid patch, so failures warn and degrade to "not retained" rather than
throwing away a completed build.

**Symbolication is done** — `lib/src/symbolication.dart`, surfaced as
`GET /api/v1/apps/{id}/crashes?symbolicate=true` adding a `stack_symbolicated`
field beside the raw `stack`.

An earlier version of this file said Android needs `llvm-symbolizer` and Apple
needs `atos` or a Mac worker. **That was wrong**, and it would have bought a
whole Mac-worker architecture for nothing. What the CLI retains is Dart's own
`--split-debug-info` output, which is what `flutter symbolize` reads via
`package:native_stack_traces` — pure Dart, handling the ELF form (Android) and
the Mach-O form (Apple). One implementation covers every platform inside the
Linux container. `atos` would only matter for native Objective-C/C++ frames out
of a dSYM, and a Dart crash handler does not produce those.

Things worth not re-deciding:

- **Read-time, not ingest-time.** Ingest must stay unfailable, and symbols are
  routinely uploaded *after* a crash arrives, so an ingest-time attempt would
  permanently miss.
- **Opt-in via `?symbolicate=true`.** Resolving costs a fetch, unzip and DWARF
  parse per distinct patch in the page. Off by default also keeps the response
  byte-identical for existing callers.
- **Never guess the symbol file.** Match the arch by `-<token>.symbols` suffix,
  not `contains`: `arm` is a prefix of `arm64`, so a `contains` match hands
  arm64 symbols to an arm32 crash and resolves every frame to a wrong address —
  a failure that looks like success. With several entries and no arch match the
  code returns null on purpose.
- Parsed symbol sets are cached (bounded, small — a parsed set is large in
  memory), with a negative cache so a broken artifact is not re-parsed per
  request.

**Verified end to end on device, 2026-07-30.** An obfuscated release +
obfuscated patch on Android arm64 (CPH2551), crashed from a patched code path,
reported by `code_push_runtime`, and resolved by
`GET /api/v1/apps/{id}/crashes?symbolicate=true`:

```
raw:  #00 abs 000000775284f067 virt 00000000001a6067 _kDartIsolateSnapshotInstructions+0xcef27
sym:  #0  patchedCrashProbeThrow (…/crashprobe/lib/main.dart:36:3)
      #1  CrashProbeHome.build.<anonymous closure> (…/crashprobe/lib/main.dart:75:32)
```

Two things that make this more than "a name appeared":

- **The line number proves which symbol set was used.** The probe function sat
  at line 27 in the release and line 36 in the patch. The resolved frame says
  **36**, so the server joined on the *patch's* retained symbols — the join the
  whole design rests on — rather than the release's.
- **Arch selection was exercised for real.** The retained zip held all three
  ABIs, and `app.android-x64.symbols` is listed *first*. A first-entry or
  `contains('arm')` match would have resolved every frame against the wrong ABI
  and looked like success. The `-arm64.symbols` suffix match picked correctly.

Reproduce with an app depending on `code_push_runtime`: obfuscated
`shorebird release android --obfuscate --split-debug-info=<dir>`, then plain
`shorebird patch android` (obfuscation and `--split-debug-info` are inherited
automatically), crash from patched code, then read the crashes endpoint with
`?symbolicate=true`. **The crash must happen while a patch is running** —
reporting is deliberately not installed on an unpatched release, so a crash
before the patch applies is not a bug.

**Do not make `POST /crashes` fail.** It always answers `200 {stored: bool}` and
swallows malformed input on purpose — the client is an app that just died, and
making it fight 4xx/5xx is a second failure on top of the first. There is a test
named `garbage never fails the reporter` guarding this.

### Track B — assets in patches

**Done:** the whole CLI half — Android (device-verified end to end) and Apple.

| Piece | Where |
|---|---|
| `POST /patches/assets` (device, unauthenticated, signed URL) | `code_push_server/lib/src/api.dart` → `_patchesAssets` |
| Upload path | `shorebird_cli/.../code_push_client_wrapper.dart` → `createPatchAssetArtifact`, tag `assetsArch` |
| `--assets` flag (opt-in) | `patch_command.dart`, next to `allow-asset-diffs`; getter `includeAssets` |
| Asset source hook | `commands/patch/patcher.dart` → `assetsDirectory()`, `null` by default |
| Android implementation | `android_patcher.dart` → `base/assets/flutter_assets/**` from the AAB cached by `buildPatchArtifact`, via `ArtifactManager.extractAndroidFlutterAssetsFromAab` |
| Apple implementation | `ios_patcher.dart` / `macos_patcher.dart` → `ArtifactManager.findFlutterAssetsDirectory` over the built bundle |
| Packaging + upload | shares Track A's `_packageSidecars` / `publishPatch(sidecars: …)` |

Decisions made while wiring it, so you do not re-litigate them:

- **Full `flutter_assets` overlay, not a delta.** Simpler and correct; the plan
  always allowed "replace the whole tree for patch N". Delta is an optimization,
  and the changed-file detection to drive one already exists if you want it:
  `archive_analysis/archive_differ.dart` → `assetsFileSetDiff()` /
  `containsPotentiallyBreakingAssetDiffs()`, surfaced as
  `DiffStatus.hasAssetChanges` by `patch_diff_checker.dart`.
- **The AAB is the source, not a build intermediate.** Those are the bytes the
  release would have shipped, already through Flutter's asset pipeline; an
  intermediate directory can hold another variant's assets.
- **Apple's location is searched, not hardcoded.** iOS keeps it at
  `Frameworks/App.framework/flutter_assets`; macOS, verified against a real
  build, at
  `Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets` —
  **not** `App.framework/Resources/...`, which is only a symlink to it. (The
  unit test originally asserted the symlink path and passed without that path
  existing; building for real is what caught it.) The search is breadth-first so
  a plugin framework vendoring its own `flutter_assets` cannot win over the
  app's shallower copy, and it does **not follow symlinks** — a macOS framework
  is a web of them, and a cycle in any embedded framework would otherwise hang
  `shorebird patch` with no output.
- Zipped with `Directory.zipToTempFile()` from
  `lib/src/archive/directory_archive.dart`. **Use this, not a new helper** — it
  zips with `includeDirName: false`, so entries are relative to the directory,
  which is what an overlay unpacked over an asset root needs. (I wrote a
  duplicate on `ArtifactManager` before finding it, and removed it.)

**The app-side package is done**: [`packages/code_push_runtime`](../packages/code_push_runtime).
It reads the running patch number via `shorebird_code_push` (depended on from
pub, since the source is a separate upstream repo), fetches `POST
/patches/assets`, caches, and exposes a `PatchAssetBundle` preferring the bundle
and falling back to `rootBundle`. It also carries the **crash reporter**, since it
needed the same two things — the patch number and an HTTP client to this control
plane — and without it nothing fed symbolication.

**Crash reporting is deliberately scoped to patches.** The handlers are not
installed at all on an unpatched release. This is not a crash reporting product
and must not grow into one: an app on a plain release already has whatever
reporter it chose, and a report from one could never be symbolicated here anyway,
because symbols are retained per patch. The question it answers is the narrow one
code push creates — "did the patch I shipped break something?" Resist the
temptation to "complete" this by retaining release symbols; that was considered
and rejected as scope, not overlooked.

Standalone package, **not a workspace member**, for the same reason as
`code_push_server`: the workspace root resolves with the Dart SDK, and adding a
Flutter package would force every package to resolve through Flutter. Test with
`cd packages/code_push_runtime && flutter test`.

Invariants it exists to enforce, all tested:

- **Cache keyed by patch number, served only for the running patch**, and every
  other patch's bundle deleted as soon as a different one runs. Eviction is
  unconditional, so a rollback to a patch with *no* assets still drops the newer
  bundle.
- **Published only when complete** — staging dir, completion marker, one rename.
  A payload that is not a zip decodes to an *empty* archive rather than throwing,
  so zero extracted files is treated as failure; without that check a corrupt
  download became a cached bundle that looked complete and was never retried.
  (A test caught exactly this.)
- **Overlay, not replacement.** A key the bundle lacks falls back to the
  compiled-in asset.
- **Chained error handlers.** `FlutterError.onError` and
  `PlatformDispatcher.onError` wrap whatever was there, so Crashlytics and
  debug's red screen both survive, and the previous handled-verdict is preserved
  rather than defaulted.
- **Release version is injected** (`readReleaseVersion`). Flutter does not bundle
  the app version anywhere reachable on every platform — `version.json` is *not*
  in `flutter_assets`, which I checked against a real AAB — and taking a
  platform-channel dependency to find it would make the package untestable.

### Track D — engine-level patch assets (Route B) — PROVEN, fonts included

Device-verified 2026-07-30 on Android arm64. **All three engine-only cases changed
in a single launch**, which is the complete claim:

| Case | From APK | From overlay |
|---|---|---|
| `rootBundle` (no `DefaultAssetBundle`) | `APK-baked` | `ENGINE-OVERLAY-patch-1` |
| Declared font (`family: Probe`) | Courier New | Comic Sans |
| Declared shader (`shaders/probe.frag`) | blue | red |

Fonts and shaders never pass through an app-side `AssetBundle`, so those two are
what Route A structurally cannot reach at any price.

**Shader gotcha:** anything under `shaders:` is compiled to `iplr` at build time.
The replacement must ALSO be declared under `shaders:`; shipping it as a plain
asset means swapping raw GLSL over compiled bytes, which reads as "shaders do not
work" rather than "the test was wrong". Sizes give it away (243 vs 1220 bytes). Engine hash
`fc184af6509a93eaf6fc068c6820639b324175a8` (rebuild of `dabf1837…` plus the
resolver), published to the local overlay and served by the mirror.

| Piece | Where |
|---|---|
| `Settings::shorebird_patch_assets_path` | `engine/src/flutter/common/settings.h` |
| Path derivation | `shell/common/shorebird/shorebird.cc` → `PatchAssetsPathForPatch()` |
| **The hook that matters** | `shell/platform/android/android_shell_holder.cc`, registered BEFORE the APK provider |
| Embedder-generic hook (unused on Android) | `shell/common/run_configuration.cc` |

Three traps, all of which cost real time:

1. **Android does not call `RunConfiguration::InferFromSettings`.** A resolver
   added there does nothing. LTO strips the function and the log string vanishes
   from `libflutter.so`, which is the only reason it was caught.
2. **The Android patch dir has no app id**:
   `<files>/shorebird_updater/patches/<N>/`. Derive from the patch file's
   dirname, never rebuild the path from `app_storage_path`.
3. **Gradle refuses the HTTP mirror.** See the mirror note below; this blocks any
   release built against the mirror, not just experimental engines.

`FML_LOG(INFO)` does **not** appear in logcat on a release build, so do not rely
on it to confirm the hook. Grep the linked `libflutter.so` for the literal, and
prove the behavior on device.

#### Reproducing the Route B rig

Assembling this was most of the work. The pieces and why each is needed:

1. **Build on the box, publish to the Mac.** `build.sh --cell android-arm64`, then
   `overlay_publish.sh --hash <sha> --root <staged>`. The Mac holds the mirror, so
   either stage the built zips there (128 MB) or run publish where the mirror is
   reachable. Host artifacts (`dart-sdk-*.zip`, `flutter_patched_sdk_product.zip`,
   `linux-x64/artifacts.zip`) can be reused from a previous hash **only** if the
   change is engine-C++-only; they are VM-coupled otherwise.
2. **`overlay_publish.sh` does not publish everything.** It omits
   `linux-x64/artifacts.zip` (gen_snapshot, impellerc) and the Maven
   `maven-metadata.xml`. Add both by hand; the known-good set is 17 files.
3. **Releases must run on Linux.** Our `gen_snapshot` is linux-x64 only, and the
   mirror 404s (deliberately) on host artifacts we did not build, so a release
   from the Mac cannot work. Use `release_on_box.sh` / `release_routeb.sh`.
4. **Tunnels.** The box reaches the Mac's control plane and mirror over `ssh -R`.
   Watch for stale forwards: one was still pointing at an old server and produced
   a confusing "Could not find app with id".
5. **One URL must satisfy box and device.** `PUBLIC_BASE_URL` is embedded
   absolutely in upload/download URLs, so the port the box uses must also be the
   port the device reaches via `adb reverse`.
6. **The upstream CLI on the box has neither `--no-confirm` nor
   `--flutter-version` on `patch`.** Pipe `yes` instead.
7. **Getting an overlay onto the device.** A release build is not debuggable, so
   `adb run-as` cannot write into app-private storage. The app writes its own
   overlay instead (Phase 2 replaces this with real delivery).
8. **The Android patch dir has no app-id component**
   (`<files>/shorebird_updater/patches/<N>/`), while the desktop API inserts one
   (`.../shorebird_updater/<app_id>/patches/<N>/`). Derive from the patch file's
   dirname; never rebuild the path from `app_storage_path`.

### Track C — hot restart

**Not started.** Needs the engine build loop, so agree the design before touching
Rust or C++ — a wrong guess costs a multi-hour rebuild to discover.

Shape from `EXPERIMENTAL_ENGINE.md`: updater grows `readyToApply` alongside
`restartRequired`; engine reloads the root isolate from the new `.vmcode`
in-process; cold restart stays the fallback; boot-crash rollback must still hold.
Both halves live in shared code (`shell/common/shorebird/`,
`vendor/updater/library/src/`), so it is iOS-ready by construction even though
iOS cannot run it yet.

## The mirror cannot serve a release over plain HTTP any more

`FLUTTER_STORAGE_BASE_URL=http://…` makes Flutter's Gradle plugin add an `http`
Maven repository, and Gradle 8+ refuses insecure repositories without an explicit
opt-in. The failure is `:app:mergeReleaseAssets` → "Using insecure protocols with
repositories, without explicit opt-in, is unsupported", before any Flutter
artifact is fetched.

**This is not specific to experimental engines** — it applies to the documented
CDN-mirror setup with a current Flutter/AGP, so it will bite ordinary mirror users.

**Fixed, and verified:** [`cdn/tls/`](cdn/tls) adds an optional HTTPS listener.

```bash
selfhost/cdn/tls/generate.sh localhost          # local CA + SAN'd server cert
# point tls_listen.conf at listen-enabled.conf in docker-compose.cdn.yaml
docker compose -f selfhost/cdn/docker-compose.cdn.yaml up -d --force-recreate cdn-cache
selfhost/cdn/tls/trust.sh                        # on every machine that BUILDS
export FLUTTER_STORAGE_BASE_URL=https://localhost:8443
```

`trust.sh` installs into **two** stores, and missing either gives a misleading
error rather than a clear one: Gradle runs on the JVM and reads the JDK's
`cacerts` (`PKIX path building failed`), while Dart/Flutter tooling reads the OS
store (`CERTIFICATE_VERIFY_FAILED`).

Verified on the Linux build host with the `FlutterPlugin.kt` insecure-protocol
patch **reverted**: a release built over https succeeded. Off by default, so an
existing deployment is unaffected until it opts in.

The escape hatch remains if TLS is impractical: patch the vended
`packages/flutter_tools/gradle/src/main/kotlin/FlutterPlugin.kt` to set
`isAllowInsecureProtocol = true`. That has to be redone on every build host and
after every Flutter bump, which is why HTTPS is the real fix.

## Invariants that cost real debugging time

Do not re-learn these:

1. **Snapshot and kernel formats are welded to the tree that produced them.**
   `VM_SNAPSHOT_FILES` in Dart's `tools/make_version.py` includes two of the three
   files our fork patches. A mixed artifact set installs fine and then dies at
   launch with `Wrong full snapshot version`. The whole host toolchain must come
   from our tree.
2. **Clearing an artifact cache swaps the Dart under an already-compiled tool
   snapshot**, which then fails as `Wrong full snapshot version` *on the host* —
   looks like an engine fault, is not. Recompile the CLI/flutter tool snapshots.
3. **`--no-tree-shake-icons` is mandatory** on a self-built engine. `const_finder`
   is a kernel snapshot stamped with its builder's SDK hash. Shorebird hit this
   too: `font_subset` is commented out of their own `linux_build.sh`
   (flutter#164531).
4. **Maven POMs cannot be proxy-rewritten.** Gradle validates the version inside
   the `.pom` body, so every module must be materialized locally under the
   experimental hash — including ABIs we did not build.
5. **`PUBLIC_BASE_URL` is embedded absolutely** in upload/download URLs. One URL
   must satisfy both the build host and the device; `http://localhost:18080` plus
   an ssh reverse tunnel (box) and `adb reverse` (device) does.
6. **`arch` is free-form end to end.** It has now absorbed three artifact kinds
   (code, `assets`, `symbols`) with no schema, protocol, or client change. Reach
   for it before adding columns.
7. **Anything under `vendor/flutter` needs `git add -f`.** Flutter's own nested
   `.gitignore` files silently drop tracked files — that is how 20 files,
   including a whole GN target, went missing from the snapshot.

## Live environment (may need reverting)

- **Build host:** Hermes VPS `20.120.104.70`, everything under
  `/data/shorebird-engine/` — never touch `/data/hermes`, and check
  `systemctl --user is-active hermes-gateway` after anything invasive. Contains
  the engine checkout, our Dart fork, `out/{android_release_arm64,host_release,host_debug}`,
  a patched CLI at v1.6.115, and the test app.
- **Local containers up:** `code_push_server` (1.2.0, host 8080), `cdn-cache`,
  `artifact-proxy`, and **`cps-phase4`** — the 1.3.0 image on host 18080 with its
  data under the session scratchpad, which is the rig the Phase 4 verification
  ran against. `cps-e2e` was stopped to free port 18080; restart it if you want
  the older asset-patch rig back. Device access is
  `adb reverse tcp:18080 tcp:18080`, so `PUBLIC_BASE_URL=http://localhost:18080`
  is one URL that satisfies both the Mac and the phone.
- **`PUBLIC_BASE_URL=http://localhost:18080`** in `packages/code_push_server/.env`
  (was the LAN IP), plus an `adb reverse tcp:18080 tcp:8080` mapping and a
  daemonized ssh reverse tunnel. Revert to a LAN IP for normal device testing.
- The Mac's vended Flutter `engine.version` **has been reverted** to Shorebird's
  `69f9831c`. Confirm it stayed that way.

## Pending actions (things that are prepared but NOT done)

- ~~`code_push_server` 1.3.0 is prepped but unpublished.~~ **Published
  2026-07-30** from tag `code_push_server-v1.3.0`: multi-arch (amd64 + arm64)
  at `ghcr.io/mml555/code-push-server:1.3.0`, pulled and booted healthy, and it
  is the image the Phase 4 verification above ran against. Both compose pins
  resolve. Note the tag points at `feat/engine-improvements`, not `main`, so a
  later merge should not re-cut it.
- **State left on the build box** (deliberately, so the rig reproduces): the CDN
  mirror's CA is trusted in its JDK `cacerts` and OS store, and
  `FlutterPlugin.kt` is reverted to stock (correct now that HTTPS works). Undo
  commands are printed by `cdn/tls/trust.sh`.
- Two scratch test apps are installed on the Android device, and their sources
  live under `/data/shorebird-engine/` on the build box. Nothing depends on them.

## Loose ends

- Release `1.0.1+2` is stranded in `draft` on the local server from a failed
  upload — harmless, but clean it up.
- `overlay_publish.sh` now **has** run end to end (exit 0, 2026-07-30). One gap:
  it re-fetches the Maven modules for the ABIs we did not build from
  `--mirror` (default `localhost:8085`), so it must run somewhere the CDN mirror
  is reachable. From the build box that needs a reverse tunnel to the Mac; without
  it those modules are skipped and the mirror will 404 on them (deliberately, per
  `$overlay_owned` in nginx.conf). The Mac's overlay already holds them for
  `dabf1837…` from the original hand-publish.
- **The overlay is backed up locally but not yet off-machine.**
  `~/shorebird-backups/engine-overlay-dabf1837-fc184af6.tar` (775 MB, sha256
  `b5fc5633c509f64660701e4654d8dfcd839ce023667f7d9dce7125b0420d9b5f`) holds both
  device-verified engines. That protects against a stray `git clean -xfd` in the
  repo, not against losing the disk — and given the next point, losing it means
  re-proving every Route B claim on device. Get a copy off this machine.
- **The engine build is not reproducible.** Rebuilding the identical source
  (`HEAD` = `dabf1837…`, no code change) produced a different `libflutter.so`:
  same size to the byte (171,860,472) and an identical `.data.rel.ro`, but a
  different `.text` (7,566,324 bytes both, different hash) and `.rodata`. Same
  sizes throughout point to non-deterministic layout rather than a different
  build, but that is inference, not proof. Consequence for engine work: **you
  cannot validate an engine change by diffing against the known-good artifact.**
  Every change needs its own device test, so batch changes rather than iterating.
  The device-verified artifact in `selfhost/cdn/overlay` was deliberately left in
  place rather than overwritten with an unverified rebuild.
- The self-built APK is **arm64-only in practice** — arm/x64 slices pair our
  `libapp.so` with the stock engine.
- A dev API key was printed into a session transcript. Rotate via `setup.sh` if
  that bothers you.
- Branches `feat/experimental-engine-farm` and `feat/asset-patches` are fully
  merged into this one and can be deleted.

## Verifying your work

```bash
cd packages/code_push_server && dart analyze && dart test -x integration   # expect 251 pass
cd packages/shorebird_cli   && dart test test/src/code_push_client_wrapper_test.dart
cd packages/shorebird_cli   && dart analyze lib test                       # expect 86 issues
npx cspell --no-progress --no-summary selfhost packages/code_push_server/lib
```

`shorebird_cli`'s **86 analyzer infos are pre-existing on `main`** — that is the
baseline, so compare against it rather than trying to reach zero. Repo
conventions: semantic-commit PR titles, inline `cspell:words` for one or two
files and the global config beyond that, prefer new commits over amending.
