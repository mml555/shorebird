<!-- cspell:words dartsdk prebuilts bidiff vmcode aot daemonized -->

# Handoff — engine improvements (as of 2026-07-29)

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

Branch: `feat/engine-improvements`, 25 commits off `main`.

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

**Still unverified:** a real obfuscated trace resolving to real line numbers.
The retained artifact is confirmed to parse (`Dwarf.fromBytes` on the real
1.3 MB file from the e2e run), and arch selection is confirmed against that real
3-ABI zip, but producing an actual resolved frame needs a crash from that exact
build — which needs the app-side crash reporter that does not exist yet.

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
  `Frameworks/App.framework/flutter_assets`, macOS at
  `Contents/Frameworks/App.framework/Resources/flutter_assets`, and it has moved
  between Flutter versions. The search is breadth-first on purpose: a plugin
  framework can vendor its own `flutter_assets`, and the app's own copy is always
  shallower, so a depth-first walk could ship the plugin's.
- Zipped with `Directory.zipToTempFile()` from
  `lib/src/archive/directory_archive.dart`. **Use this, not a new helper** — it
  zips with `includeDirName: false`, so entries are relative to the directory,
  which is what an overlay unpacked over an asset root needs. (I wrote a
  duplicate on `ArtifactManager` before finding it, and removed it.)

**Next: the Dart package** (app-side): read the running patch number via
`shorebird_code_push`, `POST /patches/assets`, download, cache, expose an
`AssetBundle` preferring the bundle and falling back to `rootBundle`. Two
invariants: key the cache by patch number and use it **only** when it matches the
running patch, and discard on rollback — the fetch is not atomic with the code
patch. Note `shorebird_code_push` is a **separate upstream repo**, not in this
monorepo, so this means our own package or a shim.

### Track C — hot restart

**Not started.** Needs the engine build loop, so agree the design before touching
Rust or C++ — a wrong guess costs a multi-hour rebuild to discover.

Shape from `EXPERIMENTAL_ENGINE.md`: updater grows `readyToApply` alongside
`restartRequired`; engine reloads the root isolate from the new `.vmcode`
in-process; cold restart stays the fallback; boot-crash rollback must still hold.
Both halves live in shared code (`shell/common/shorebird/`,
`vendor/updater/library/src/`), so it is iOS-ready by construction even though
iOS cannot run it yet.

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
- **Local containers up:** `code_push_server`, `cdn-cache`, `artifact-proxy`.
- **`PUBLIC_BASE_URL=http://localhost:18080`** in `packages/code_push_server/.env`
  (was the LAN IP), plus an `adb reverse tcp:18080 tcp:8080` mapping and a
  daemonized ssh reverse tunnel. Revert to a LAN IP for normal device testing.
- The Mac's vended Flutter `engine.version` **has been reverted** to Shorebird's
  `69f9831c`. Confirm it stayed that way.

## Loose ends

- Release `1.0.1+2` is stranded in `draft` on the local server from a failed
  upload — harmless, but clean it up.
- `overlay_publish.sh`'s host-toolchain path is written but **never executed**;
  those artifacts were published by hand for the verified run.
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
