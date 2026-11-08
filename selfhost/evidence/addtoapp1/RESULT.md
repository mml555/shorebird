<!-- cspell:words addtoapp localsend xcframework xcframeworks codesign precache -->

# ADD-TO-APP-1 — STOPPED at qualification. Four blockers, the first at the first command

2026-09-03. Host only. **No cell minted, no release cut, no patch produced, no
device run, no fail-closed rule loosened, no capability implemented.**

## Verdict

**The frozen self-hosted Route B stack does not work in an iOS Add-to-App host,
and it fails before Route B is reached.** Steps 4–6 of the brief (produce a
patch, physically qualify, establish embedded restart semantics) are
**unreachable** without implementing new capability, which the authorization
explicitly excluded. Reporting rather than proceeding, per the stop condition.

Four independent blockers, in the order the developer workflow hits them:

| # | Blocker | Where | Class |
|---|---|---|---|
| 1 | `flutter build ios-framework` fails: the cell publishes a **device-only** `Flutter.xcframework` | inside `flutter build`, before any Route B release machinery is reached | engine publishing |
| 2 | An add-to-app release **cannot be activated** by the self-hosted control plane | `PATCH /releases/{id}` → 409 | control plane (ours) |
| 3 | **Route B is not implemented** for `ios-framework` | `ios_framework_releaser` / `ios_framework_patcher` | architecture |
| 4 | An `ios-framework` **code** patch requires Shorebird's AOT linker, which this stack does not have | `IosFrameworkPatcher.createPatchArtifacts` | toolchain |

Blocker 1 alone stops step 3 at the first command. Blockers 2–4 were established
independently, so removing 1 would not produce a path this lane could qualify.

**A wording correction, made after review, because the first draft overstated
it.** An earlier version of the table above said blocker 1 lands "before any
Shorebird logic". That is wrong, and the captured log
([`release_ios_framework.log`](release_ios_framework.log)) shows why: Shorebird
fetches the app list, runs `flutter precache`, downloads `aot-tools.dill` and
clears the coherence gate first, and only then invokes `flutter build`. The
defensible statement is that the failure happens **inside `flutter build
ios-framework`, before any Route B release machinery is reached** — which is
what the table now says. The finding itself is unchanged.

## Blocker 1 — the cell publishes a device-only `Flutter.xcframework`

The real developer workflow, run by
[`../../scripts/addtoapp1_workflow.sh`](../../scripts/addtoapp1_workflow.sh):
`flutter create -t module` → the `shorebird init` yaml + asset entry → app
registered on a throwaway control plane → `shorebird release ios-framework
--release-version 1.0.0+1`.

    Building frameworks for dev.selfhost.addtoappModule in release mode...
     ├─Copying Flutter.xcframework...                          50ms
     ├─Building App.xcframework...
    Error: No iOS frameworks found in
      .../flutter/e64eb0af…/bin/cache/artifacts/engine/ios/Flutter.xcframework
    The App.xcframework build failed.

`flutter_tools`' own predicate (`artifacts.dart:970-982`) walks the
xcframework's `ios-*` subdirectories and returns the one matching the requested
`EnvironmentType`; a `-simulator` suffix means simulator. The module's
`App.xcframework` is assembled with **both** slices, and the simulator slice is
built against the **debug** engine (`artifacts/engine/ios/`) — which is why a
`--no-debug --no-profile` release build still needs it.

**The measured difference, against a stock control in the same cache:**

| revision | `engine/ios/Flutter.xcframework` contents |
|---|---|
| stock `309dd657…` | `Info.plist`, `_CodeSignature`, `ios-arm64`, **`ios-arm64_x86_64-simulator`** |
| **frozen cell `cd848320…` (`e64eb0af…`)** | `Info.plist`, `ios-arm64` — **no simulator slice** |

`flutter build ios-framework --help` on the pinned Flutter offers
`--[no-]debug/profile/release`, `--[no-]codesign`, `--[no-]cocoapods`,
`--[no-]plugins`, `--[no-]static` — and **nothing** that skips the simulator
slice. So this is not a flag away.

This is a **product gap in what the Route B cell publishes**, not a harness
fault. A full-app iOS release never needs a simulator slice, which is why every
qualified lane to date has been unaffected.

## Blocker 2 — an add-to-app release cannot be activated

Measured against the shipping API with a **positive control**
([`activation_gate_probe.dart`](activation_gate_probe.dart), output in
[`activation_gate_probe.txt`](activation_gate_probe.txt)):

    ios-framework activation -> 409: Release 1 (ios) is missing artifacts:
                                     ios_supplement, runner, xcarchive
    full-app ios activation  -> 204          <-- the control
    aar activation           -> 409: Release 1 (android) is missing artifacts: aab

`Api._requiredArchs` gates activation on `{xcarchive, runner, ios_supplement}`
for `ios` and `{aab}` for `android`. Per
[`../../PLATFORM_MATRIX.md`](../../PLATFORM_MATRIX.md), add-to-app shares the
`platform` wire value and is distinguished **only by the `arch` string** —
`xcframework` (iOS) and `aar` (Android). Neither is in the required set, so
neither release can ever reach `ready`, and no patch can be built against one.

The gate's own comment says where it came from: *"Derived from every release
this server has accepted (ids 1-6 as of 2026-07-31)"* — every one a full-app
release. The induction was correct for the sample and wrong for add-to-app.

**Not fixed here.** It is a real defect in our control plane and it is small,
but the ruling says bank the failure and bring it back before changing
anything, and fixing it does not unblock the objective.

## Blocker 3 — Route B is not implemented for `ios-framework`

`grep -c 'routeB\|RouteB'`:

    lib/src/commands/patch/ios_patcher.dart              78
    lib/src/commands/release/ios_releaser.dart           42
    lib/src/commands/patch/patch_command.dart            16
    lib/src/commands/release/releaser.dart                1   (a generic build-config recorder)
    lib/src/commands/patch/ios_framework_patcher.dart     0
    lib/src/commands/release/ios_framework_releaser.dart  0
    lib/src/commands/patch/apple_patcher_mixin.dart       0
    lib/src/commands/release/apple_releaser_mixin.dart    0

`IosFrameworkPatcher extends Patcher with ApplePatcherMixin` — and neither
carries Route B. `_declareRetention` and `_recordRouteBProvenance` are called
only from `ios_releaser.dart`, so an `ios-framework` release writes no
`route_b.json`, no `dynamic_interface`, no capability manifest.

The consequence is quiet rather than loud: `patch_command`'s Route B gates are
**platform-neutral** — they key on `hasRouteBReleaseProvenance(supplementDir)`,
not on `ReleaseType` — so with no provenance present, the engine-identity check,
the retention-interface flag and the build-config check all simply do not run.
An `ios-framework` patch is produced the way upstream produces one.

*(One fork guard does reach this path: the toolchain-coherence gate refused the
build with `COHERENCE_UNDETERMINABLE` until `SHOREBIRD_PUBLISHED_IOS_ENGINE_DIR`
was pointed at the cell's overlay — behaving exactly as
`SUPPORTED_STATE.yaml` documents. So the guards generalise; the capability does
not.)*

## Blocker 4 — the linker an `ios-framework` code patch needs does not exist here

`ios_framework_patcher.dart:167`:

    final useLinker = !assetsOnly && AotTools.usesLinker(shorebirdEnv.flutterRevision);

with the fork's own comment two lines above:

> Skipping it also removes the only use of `aot-tools.dill` — Shorebird's AOT
> linker, **which we cannot build** — so this is the one iOS patch shape that
> works without their toolchain.

* The pinned revision `e64eb0af…` is **not** in `_preLinkerFlutterRevisions`, so
  `usesLinker` returns **true**: a code patch takes the linker path.
* The frozen engine's `gen_snapshot_arm64` (ios-release) advertises **0** of the
  six fork-private `--base_{ct,dt,ft,op}_link_data` / `--patch_{ct,op}_link_data`
  flags and contains **0** occurrences of the string `shorebird`. It is stock
  Dart. (This is the premise of [`../../AOT_LINKER_FEASIBILITY.md`](../../AOT_LINKER_FEASIBILITY.md)
  and the reason Route B exists.)

So the only `ios-framework` patch shape available on this stack is
`--assets-only`, which carries **no code** and is not Route B.

## Step 6 (embedded restart semantics) — not measurable, and why that matters

The brief asked what "restart" means when Flutter is embedded — host-process
restart, engine recreation, or something else — and required proving it rather
than importing the standalone assumption. **That question cannot be answered
without a patch to activate**, and no patch can be produced. It is not carried
forward on an argument; it is recorded as unmeasured.

## Two harness faults corrected before any of the above was trusted

Both were mine, and each would have produced a wrong first-failure:

1. **The harness wrote `shorebird.yaml` but not its `pubspec.yaml` asset entry**,
   which `shorebird init` does. The first run failed on
   `ShorebirdYamlAssetValidator` — the harness bypassing the developer workflow,
   which the brief warned against. Fixed by
   [`../../scripts/lib/add_shorebird_asset.py`](../../scripts/lib/add_shorebird_asset.py).
2. **An ambiguous code-signing identity** — two identical
   `Apple Development: …` certificates in this Mac's login keychain — failed the
   build with `Unable to codesign Flutter.xcframework`. An environment fault, not
   an Add-to-App finding. Passed `-- --no-codesign`, which is also the correct
   product behaviour: an Add-to-App module's frameworks are signed by the **host**
   app at its own build time.

Neither is reported as a blocker.

## What would be needed, if this is ever authorized

Sequenced, and each is a decision rather than a task:

1. **Publish a simulator slice** in the cell's `Flutter.xcframework` (all three
   modes, or at least `ios`). Changes what a cell IS, so it needs a new cell and
   re-qualification of the addressing/audit chain — which this lane was told not
   to do.
2. **Teach the control plane the add-to-app artifact sets** — per release *kind*,
   not per platform, since `xcframework`/`aar` share a platform with
   `xcarchive`/`aab`. Small; ours; the natural first increment.
3. **Implement Route B for `ios-framework`** — or decide Add-to-App is
   assets-only on this stack and say so in the compatibility record.

Nothing in 1–3 was started.

## Provenance

| thing | value |
|---|---|
| repo revision | `167168e9` (clean) |
| CLI | `/Volumes/build/route-b/shorebird-candidate/bin/shorebird` (the qualified checkout) |
| Flutter / cell | `e64eb0af52e1c43c3b21a39556d789538d0df9b3` / `cd848320d605ff8af5060cabf9a8d1b35853f752` |
| coherence authority | `selfhost/cdn/overlay/flutter_infra_release/flutter/cd848320…` |
| control plane | throwaway sqlite/file instance on a free port; `cps-ios` and `cps-android` untouched |
| module | `flutter create -t module`, `dev.selfhost.addtoapp_module` |
| suite | `code_push_server` 370 pass (unchanged) |
