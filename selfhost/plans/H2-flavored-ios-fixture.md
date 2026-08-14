# H2 — a flavored iOS fixture (unblocks `G4.2`)

> At the end, `--flavor foo` builds a real iOS app in this repo, a release built that way carries `FLUTTER_APP_FLAVOR` all the way into `route_b.json`, and a patch built with the SAME flavor is no longer refused -- none of which is true now.

| field | value |
|---|---|
| status | **NOT BUILT** -- the fixture does not exist; `selfhost/fixtures/airgap_app/ios` has one scheme and no flavor xcconfigs, so no arm of `G4.2` is constructible |
| owns | none exclusive. A **NEW** fixture (`selfhost/fixtures/flavored_app`), so **no `R6`** -- PARITY §16 records that `G4.2`/`G8`/`G9` do not contend on the canonical fixture at all. Optional step 8 takes `R8` `cps-ios` |
| excludes | any other order editing `packages/shorebird_cli/lib/src/commands/patch/ios_patcher.dart` -- the `G4.3` obfuscation work lives at `ios_patcher.dart:152` and `:308`, and step 5 edits `:757`. Source conflict, not scheduling |
| blocked by | nothing. The cell is minted (`4df8f9b6139b67d2cfe9f6aa8212372cade36278`, `ba4e1c02`); no `R3`, no `R1`, no mint |
| unblocks | all five `G4.2`/`G4.3` configuration arms in PARITY.md:3226-3231 -- three of them need a flavor -- and the Android flavor arm's fixture half |
| device needed | none |
| mint needed | no -- nothing here changes the compiler or the engine |
| est. shape | a day of host work: half on the Xcode overlay and its generator, half on the patcher fix plus tests. No hardware, no mint |

**Provenance.** Authored against the tree at `c0619d13` with every path and command checked by its
author, but **the adversarial verification pass did not run** (session limit) — so citations here are
first-draft rather than double-checked. Re-verify a claim before you act on it, and fix it in place
when it is wrong. `PARITY.md:NNNN` anchors move whenever that file is edited: if one looks wrong,
re-locate by grepping the quoted heading. Schema and house rules: [`README.md`](README.md).

## Why this is the piece it is

Block 3 of `c0619d13`'s four is a **prerequisite**, not a failed gate, and it is the only one of the four that costs no device and no engine. Building it is self-contained: an Xcode project shape, a generator, an observable, and one CLI bug that the fixture exposes on its first use.

It deliberately does **not** include: the device arms themselves (they belong to the `G4.2`/`G4.3` device order and want `R1`), the Android device arm (`R2` + `R12`, Linux-only per `accept_android_default.sh:17-19`), and any change to `selfhost/fixtures/airgap_app` -- H2's whole value is that it is a *second* fixture, which is the down payment on `R6` that PARITY §16 asks for.

## Preconditions -- check these before claiming anything

1. **Tree state.** `git -C /Users/mendell/shorebird log --oneline -1` → `c0619d13`; `git status --porcelain` → empty. Note `git worktree list` returns **four** entries (main plus three detached `shorebird-compat-study*`); PARITY §17's "exactly one" is stale.
2. **Claims table.** `awk '/^### Claims/,/^### Starting a new worker/' selfhost/PARITY.md | grep '^| .R'` → `R8` must read **free** if you intend step 8. Add your own row in the same commit as the work; a write claim reports **TREE HEALTH** (GREEN vs RED/mid-edit), not just ownership.
3. **Code work goes in its own worktree** (§17 rule 3): step 5 touches `packages/`. Stage explicit paths only -- never `-A`, never `commit -a`, never stash/restore/checkout in the shared tree.
4. **The Flutter pin is present.** `grep -n flutter_revision selfhost/compatibility.yaml` → `c15ef6379403a0a55531a058bdb2c8e55bc05c98` (line 11), and `ls ~/.shorebird/bin/cache/flutter/c15ef6379403a0a55531a058bdb2c8e55bc05c98` exists. Every scheme/configuration rule below is read out of that checkout; a different pin invalidates the overlay's baseline sha.
5. **THE CLI UNDER TEST MUST BE THE CLI YOU CHANGED** (`c0619d13`'s promoted precondition d). `git -C ~/.shorebird log --oneline -1` → `ba4e1c02` on branch `selfhost-under-test`, and `grep -n 'supportedRouteBAnalysisVersion' ~/.shorebird/packages/shorebird_cli/lib/src/route_b_coverage.dart` → `= 8`. **After step 5 this is stale**: re-sync with `git -C ~/.shorebird fetch fork <branch> && git -C ~/.shorebird checkout --detach FETCH_HEAD`, then `grep -n '_resolvedFlavor' ~/.shorebird/packages/shorebird_cli/lib/src/commands/patch/ios_patcher.dart` must hit before any patch arm is believed. Release 34 was DISCARDED for exactly this class of mistake.
6. **Only if step 8 runs** -- the three cache preconditions from `mint_route_b_cell.sh:193-222`, all of which fail in the direction that looks like success: (a) **never establish a revision by writing cache stamps** -- delete `bin/cache/{artifacts,dart-sdk,downloads}` and `bin/cache/*.stamp` and verify the CONSUMED bytes; (b) **reload the mirror before any client fetch** and clear `<flutterDir>/bin/cache/downloads`, because the Caddyfile's `order cache before respond` means a cached fallback beats the 404 ownership would return; (c) **warm the cache before the release that matters** -- `isRouteBEngine` (`route_b.dart:29`, called at `ios_releaser.dart:120`) returns false when the `ios_release` Flutter binary does not yet EXIST, which is how release 33 silently took the non-Route-B path and reported success.

## Already satisfied — verified 2026-08-13, do not redo

Steps **5** and **6** are DONE, and re-doing them would look like progress while
changing nothing:

* **step 5, the patch-side flavor.** `ios_patcher.dart:766` defines `_resolvedFlavor`
  and `:774-776` passes it into `RouteBBuildConfig.fromBuildArgs`, mirroring
  `ios_releaser.dart:269`.

  ⚠ **CORRECTED 2026-08-13, and the retracted half is the load-bearing one.** This
  entry first read *"It landed at or before `ba4e1c02`, so the INSTALLED CLI carries
  it too (`git log ba4e1c02..HEAD -- packages/shorebird_cli` is empty) and
  precondition 5's re-sync is not needed for this reason alone."* **Both clauses are
  false, measured:**

  ```
  git log --oneline ba4e1c02..HEAD -- packages/shorebird_cli
    4fb03725 docs(selfhost): say what the screenshot shows, …
    de11eecf test(selfhost): the sole positional argument arrives — release 37, on device
  grep -c _resolvedFlavor ~/.shorebird/…/patch/ios_patcher.dart   ->  0
  ```

  The fix landed **today**, at `de11eecf`/`4fb03725` — *after* `ba4e1c02`, which is
  what `~/.shorebird` is pinned to. **The installed CLI does NOT carry it**, so
  **precondition 5's re-sync is MANDATORY before any flavored patch arm.** Skip it
  and `shorebird patch --flavor foo` against a `--flavor foo` release refuses the
  MATCHING case, reporting `FLUTTER_APP_FLAVOR: "foo" in the release, absent in this
  patch` — a refusal produced by the stale CLI, indistinguishable at the terminal
  from a fixture defect or a real `G4.2` incompatibility. This is release 34's
  failure mode exactly, and it is why "the CLI under test must be the CLI you
  changed" is a promoted precondition rather than advice.
* **step 6, the probe's row 4 — DONE BUT UNCOMMITTED, and that qualification is
  load-bearing.** `g42_flavor_flow.sh` reports **13 passed, 0 failed** and its own
  closing text reads "Rows 4a/4b now pin the fix, so a regression fails here instead
  of on a phone." The prediction of 11/12 described the state before that re-aim.
  **But the re-aim lives only in the working tree**: the last commit touching that
  file is `f8855734`, the original 12-row version that still asserts the gap, and
  `selfhost/evidence/g42_flavored_fixture/g42_flavor_flow.txt` is untracked. It was
  authored outside the session that wrote this note, so it is deliberately left
  unstaged rather than swept into an unrelated commit. **Check `git status` before
  believing this row is pinned** — if those changes are gone, the committed probe
  asserts a bug that no longer exists and will report 11/12 again.

What remains is steps **1-4** and **7**: the fixture sources, the live `flavorState()`
observable, the iOS overlay (schemes, six configurations, flavor xcconfigs, distinct
bundle ids, a sha-gated `project.pbxproj`), `prepare_flavored_fixture.sh`, and the
host proof that `--flavor` reaches the compiler. `selfhost/fixtures/flavored_app` and
`selfhost/scripts/prepare_flavored_fixture.sh` are both ABSENT, so nothing there has
been started.

## Measured against the pin, 2026-08-13 — do not re-derive

The generated tree now exists (`flutter create --platforms=ios,android
--project-name flavored_probe --org dev.selfhost .` under the pinned Flutter), and
these are facts about it rather than predictions:

| fact | value |
|---|---|
| baseline `project.pbxproj` sha256 | `18152845ff6073752b926099b37b738d0415b49575fe11be1bdca3f7c1997387`, recorded at `fixtures/flavored_app/ios_overlay/BASELINE.project.pbxproj.sha256` |
| configuration lists to extend | **three**: `97C146E91CF9000F007C117D` (PBXProject "Runner"), `97C147051CF9000F007C117D` (PBXNativeTarget "Runner"), `331C8087294A63A400263BE5` (PBXNativeTarget "RunnerTests") |
| existing configurations | `Debug`/`Release`/`Profile`, three occurrences each |
| `baseConfigurationReference` present on | only **three** blocks — `:374` (Release.xcconfig), `:554` (Debug.xcconfig), `:577` (Release.xcconfig). The others inherit, so a transform must not assume every block has one |
| `PRODUCT_BUNDLE_IDENTIFIER` occurrences | 6, all one id — which is why two flavors cannot co-install without the overlay |
| RunnerTests | present, and its list needs the flavored configurations too, or a scheme's Test action references a configuration that does not exist |

**DONE and committed:** `ios_overlay/Flutter/{Foo,Bar}.xcconfig` (each `#include
"Generated.xcconfig"` first, then a distinct `PRODUCT_BUNDLE_IDENTIFIER`,
`PRODUCT_NAME`, `DISPLAY_NAME`), and
`ios_overlay/Runner.xcodeproj/xcshareddata/xcschemes/{Foo,Bar}.xcscheme`, derived
from the generated `Runner.xcscheme` by rewriting `buildConfiguration` — verified
as 3 × `Debug-Foo` (Test/Run/Analyze), 1 × `Profile-Foo`, 1 × `Release-Foo`.

**NOT DONE — the single remaining piece of step 3:** the overlay's
`project.pbxproj`. It needs 6 `XCBuildConfiguration` blocks per configuration list
(3 modes × 2 flavors) added to all three lists, each flavored block pointing
`baseConfigurationReference` at the new flavor xcconfig, plus 2 new
`PBXFileReference` entries added to the `Flutter` group. The `xcodeproj` ruby gem
is not importable here, so author it with a text transform, commit the RESULT (the
gate is a sha, not a script), and verify with `xcodebuild -list -project
ios/Runner.xcodeproj` showing schemes `Bar`/`Foo`/`Runner` and the six new
configurations. Until it lands the committed schemes reference configurations that
do not exist, so **the overlay is incomplete and must not be described as green.**

> ### ⚠ CORRECTED 2026-08-13 15:53 — the paragraph above is FALSE, and it is false in the direction that costs a session
>
> **The overlay's `project.pbxproj` landed in the very commit whose message says it
> did not.** `41758dd3`'s diffstat carries
> `ios_overlay/Runner.xcodeproj/project.pbxproj` (1217 lines) and
> `ios_overlay/derive_overlay.py` (164 lines), because both were sitting unstaged in
> the shared tree when that commit staged broadly — §17's 2026-08-11 hazard, second
> instance. Measured at `41758dd3`:
>
> ```
> git show HEAD:…/ios_overlay/Runner.xcodeproj/project.pbxproj | shasum -a 256
>   3681ff26006e10efe0af0fcb1b113fd55115a9532a6ed0e007bbbaf52b2d2296
> …| grep -oE "name = (Debug|Release|Profile)-(Foo|Bar);" | sort | uniq -c
>   3 each of Debug-Foo Debug-Bar Release-Foo Release-Bar Profile-Foo Profile-Bar
> ```
>
> Three occurrences of each name is one per configuration list — project, `Runner`,
> `RunnerTests` — i.e. exactly the 18 blocks the paragraph above asks a next session
> to author. **A session that follows that text writes a second transform over a
> working one.** The derivation is `ios_overlay/derive_overlay.py`, which sha-gates
> its input against the baseline and exits 2 on a mismatch rather than overlaying.
>
> **And Xcode accepts it** — the check that paragraph asks for, run 2026-08-13
> against a scratch copy of `ios/` with the overlay applied, so the shared fixture
> was not touched:
>
> ```
> xcodebuild -list -project Runner.xcodeproj
>   Build Configurations: Debug Release Profile Debug-Foo Debug-Bar
>                         Release-Foo Release-Bar Profile-Foo Profile-Bar
>   Schemes: Bar FlutterFramework FlutterGeneratedPluginSwiftPackage Foo Runner
> ```
>
> `xcodeproj.dart:587-589` names the scheme `sentenceCase(flavor)` = `Foo`, and
> `:590-598` names the configuration `Release-Foo`; both are present, so
> `--flavor foo` can now resolve. **That earns BUILT for the overlay's structural
> validity ONLY.** It is a project-file query, not a build: nothing here shows the
> flavor reaching the compiler, which is step 7's `strings` grep and is still unrun.
>
> **Step 7's paths are now wrong, and this is the load-bearing consequence.** The
> committed xcconfigs set `PRODUCT_NAME = flavored_probe_foo` / `_bar`, and
> `application_package.dart:188-190` builds the artifact path as
> `build/ios/<type>/$_appProductName.app` from exactly that setting. So step 7's
> `build/ios/iphoneos/Runner.app/…` does not exist for a flavored build; the arms
> are at `flavored_probe_foo.app` and `flavored_probe_bar.app`. The **no-token
> `default-flavor` arm lands on the SAME path as the `--flavor foo` arm**, because
> `flutter_command.dart:1503-1505` is `flavor = cliFlavor ?? defaultFlavor` and that
> one value feeds scheme and configuration selection — so arms 1 and 3 differ in
> what they prove, not in what they produce, and **step 7 must record the bundle
> path per arm rather than assume one.** Two flavors also no longer collide at a
> single `Runner.app`, which is the `G10.1 stale-ipa` class of misattribution
> (`c57c6537`) — that is the tradeoff `PRODUCT_NAME` buys, and it is worth its cost;
> the alternative (leave `PRODUCT_NAME` alone, keep the paths stable, accept that
> consecutive flavor builds overwrite each other) was written and then reverted in
> favour of the committed version, which was authored first.

## Steps

1. **Create the fixture's committed sources.** `selfhost/fixtures/flavored_app/{pubspec.yaml, pubspec.lock, lib/main.dart, assets/probe.json, shorebird.yaml.template, README.md, ios_overlay/, android_overlay/}`. Mirror `airgap_app`'s committed/generated split, which `prepare_airgap_fixture.sh:19-25` states explicitly. Depth is identical, so `code_push_runtime`'s `path: ../../../packages/code_push_runtime` (`airgap_app/pubspec.yaml:26-27`) copies unchanged. `pubspec.yaml` carries `version: 1.0.0+1`, `flutter: uses-material-design: true`, `assets: [shorebird.yaml, assets/probe.json]` (the CLI refuses to build without `shorebird.yaml` declared), and **`default-flavor: foo`**. **How you know:** `flutter pub get` resolves and `git status --porcelain selfhost/fixtures/flavored_app` lists only those paths.

2. **Write the observable, on a LIVE path.** `appFlavor` is `const String? appFlavor = String.fromEnvironment('FLUTTER_APP_FLAVOR') != '' ? ... : null` at `flutter/lib/src/services/flavor.dart:9-11`, exported from `services.dart:22`. In `lib/main.dart`:

   ```dart
   const String kReleaseState = 'FLAVORED-FIXTURE-V1';

   @pragma('vm:never-inline')
   @pragma('vm:entry-point')
   String flavorState() => DateTime.now().millisecondsSinceEpoch >= 0
       ? 'V1/${appFlavor ?? "none"}'
       : 'V1/${appFlavor ?? "none"}!';
   ```

   The `DateTime.now()` guard is not decoration: `assert_result_consumed.sh:6-30` records six device runs lost to a constant-folded result. Call it from `initState` alongside the existing `_routeBRead` pattern (`airgap_app/lib/main.dart:263-276`) and add `flavor_state` to the beacon query string (`:316-345`), so the harness asserts on the control plane's request log rather than on pixels. **THE REACHABILITY LESSON FROM BLOCK 2 APPLIES HERE**: do not park this target in a dead branch to keep it retained, the way `tagged(String x)` was (`airgap_app/lib/main.dart:124`, called only at `:179`). Consumption is necessary and not sufficient. **How you know:** `grep -n 'flavorState()' lib/main.dart` shows the definition and an `initState`-reachable call, and the beacon builder names `flavor_state`.

3. **Write the iOS overlay** into `selfhost/fixtures/flavored_app/ios_overlay/`. What a flavor needs is fully determined at the pin, and all of it is currently absent from `airgap_app/ios`:

   | need | rule at the pin | what exists in `airgap_app` today |
   |---|---|---|
   | shared scheme `Foo`, `Bar` | `sentenceCase(flavor ?? 'runner')`, `xcodeproj.dart:587-589`, matched at `:614-622` | `xcshareddata/xcschemes/` holds exactly one file, `Runner.xcscheme` |
   | configurations `Release-Foo`, `Debug-Foo`, `Profile-Foo` (and `-Bar`) | `'$baseConfiguration-$scheme'`, `xcodeproj.dart:590-598`; fallback = unique config containing both `release` and `foo`, `:650-658` + `:670-676` | `project.pbxproj:319-597` defines only `Debug`/`Release`/`Profile` per target |
   | flavor xcconfigs | `baseConfigurationReference` per configuration (`project.pbxproj:554`, `:577`) | `Flutter/Debug.xcconfig` and `Flutter/Release.xcconfig` are each one line, `#include "Generated.xcconfig"` |
   | distinct identity | `PRODUCT_BUNDLE_IDENTIFIER` at `project.pbxproj:386`, `:566`, `:589` -- all `dev.selfhost.airgapProbe` | one bundle id, so two flavors cannot co-install |

   Overlay contents: `Flutter/Foo.xcconfig` and `Flutter/Bar.xcconfig`, each `#include "Generated.xcconfig"` plus `PRODUCT_BUNDLE_IDENTIFIER = dev.selfhost.flavoredProbe.foo` (resp. `.bar`) and `PRODUCT_NAME`/`DISPLAY_NAME` suffixes; `xcshareddata/xcschemes/{Foo,Bar}.xcscheme` copied from `Runner.xcscheme` with every `buildConfiguration = "Release"` → `"Release-Foo"` and `"Debug"` → `"Debug-Foo"`; and a `project.pbxproj` that adds six configurations (three modes x two flavors) on the Runner project and the Runner target, each with its flavor xcconfig as `baseConfigurationReference`. Keep `Runner` as a scheme -- with three schemes `definesCustomSchemes` (`xcodeproj.dart:583`) is true either way, and keeping it preserves an unflavored control build. **The `xcodeproj` ruby gem is not importable here** (`ruby -e "require 'xcodeproj'"` → LoadError; it exists only inside cocoapods' vendored gems), so the overlay is a committed `project.pbxproj` gated by a sha, not scripted surgery. **How you know:** step 7.

4. **Write `selfhost/scripts/prepare_flavored_fixture.sh` -- it does not exist.** `ls selfhost/scripts` shows seven scripts, none flavor-aware, and `airgap_acceptance.sh` passes no `--flavor` at either shorebird invocation (`:263-269`, `:519-521`). Flow, modeled on `prepare_airgap_fixture.sh`: (a) `flutter create --platforms=ios,android --project-name flavored_probe --org dev.selfhost .` if `ios/`/`android/` are absent (`:68-77`); (b) **sha-gate** the generated `ios/Runner.xcodeproj/project.pbxproj` against a baseline recorded for the pinned Flutter -- a mismatch means the overlay was derived from a different generator and must be refused, not overlaid; (c) copy the overlay over the generated tree; (d) re-inject `NSLocalNetworkUsageDescription` + `NSAppTransportSecurity:NSAllowsLocalNetworking` exactly as `:96-110` does, since `ios/` is regenerated; (e) write `.generated/shorebird.<arm>.yaml` and stamp the active one via `--activate` (`:112-175`). **[MUTATES selfhost/fixtures/flavored_app/{ios,android}]** -- generated, gitignored, reproducible.

   The generated `shorebird.yaml` **must map every flavor to the same `app_id`**, with the reason in the file:

   ```yaml
   app_id: <server-generated>
   base_url: http://<mac link-local>:18080
   # foo and bar share ONE app_id on purpose. patch_command.dart:206 resolves
   # appId via getAppId(flavor:) and shorebird_yaml.dart:69-72 returns
   # flavors[flavor] ?? appId, so distinct ids make `patch --flavor bar` query a
   # DIFFERENT app and fail "release not found" before the fingerprint is
   # compared -- a refusal for the wrong reason, which is worse than no arm.
   flavors:
     foo: <same id>
     bar: <same id>
   ```

   **How you know:** run it twice; the second run reports the platform dirs already present and rewrites nothing but the config.

5. **Fix the patch side.** `ios_patcher.dart:757` is `final patchConfig = RouteBBuildConfig.fromBuildArgs(patchArgs);` -- no `flavor:`. Add a `_resolvedFlavor` getter mirroring `ios_releaser.dart:263-272` (`RouteBBuildConfig.resolveFlavor(cliFlavor: flavor, pubspecFlutterSection: shorebirdEnv.getPubspecYaml()?.flutter)`, defined at `route_b_build_config.dart:109-124`) and pass it. **[MUTATES packages/shorebird_cli]** Tests, in the style of the 21-case matrix already at `test/src/route_b_build_config_test.dart:241-343`: release `foo` / patch `foo` **accepts**; release `foo` / patch `bar` **refuses naming the define**; release `foo` / patch with no token but `default-flavor: foo` **accepts**; release unflavored / patch `foo` **refuses**. **How you know:** `cd packages && very_good test -r` green, and the accept case fails before the change.

6. **Re-aim `g42_flavor_flow.sh` row 4, do not delete it.** Lines 108-109 assert `route_b_release_kernels.dart` does **not** mention flavor; `25f8a3b8` added `-DFLUTTER_APP_FLAVOR=$flavor` at `route_b_release_kernels.dart:134` and touched no probe (its diffstat lists five files, none under `probes/`). So the `12/12` in that commit message and in `PARITY.md:2056` describes a **pre-fix** run, and the probe must now report 11/12 and exit 1. Re-point row 4 at `ios_patcher.dart` -- the half that genuinely still lacks it before step 5, and the half whose fix the probe should then pin. **A correction needs evidence exactly as much as the original claim did**: run it and record the count.

7. **Prove the flavor reaches the compiler with no control plane and no device.** From the fixture directory, with the pinned Flutter:

   ```bash
   flutter build ios --release --flavor foo --no-codesign
   strings build/ios/iphoneos/Runner.app/Frameworks/App.framework/App | grep -c 'V1/Foo'
   flutter build ios --release --flavor bar --no-codesign     # then grep V1/Bar
   flutter build ios --release --no-codesign                  # default-flavor -> V1/Foo
   ```

   **CASE CORRECTED 2026-08-14 — this step originally said `grep -c 'V1/foo'`,
   which returns 0 on a WORKING fixture and reads exactly like the failure it is
   meant to detect.** The marker is `V1/Foo`. iOS takes `FLUTTER_APP_FLAVOR` from
   the Xcode CONFIGURATION, not from the token you typed, and returns the
   SCHEME's own casing (`common.dart`'s `_addFlavorToDartDefines`;
   `xcode_project.dart:385-388` returns `schemeName`). Measured:
   `ios/Flutter/Generated.xcconfig` carries `FLAVOR=foo` for the same build whose
   shipped `App` contains `V1/Foo`. That divergence was not only a grep bug — the
   CLI was passing the token to Route B's own kernels, and it is fixed at
   `6ae04dc7` (`XcodeBuild.flavorScheme`). Results in
   `evidence/g42_flavored_fixture/h2_step7_host_arms.txt`.

   Then `selfhost/engine/route_b/probes/assert_result_consumed.sh build/ios/iphoneos/Runner.app` to confirm the call's result is consumed, and `/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' build/ios/iphoneos/Runner.app/Info.plist` to confirm the flavor selected its own configuration. **How you know:** the precommitted table below.

8. **Optional, claims `R8` -- record the provenance.** Re-sync `~/.shorebird` per precondition 5, honour precondition 6, then `shorebird release ios --flavor foo --flutter-version=<pin>` and read `selfhost/fixtures/flavored_app/build/ios/shorebird/route_b.json` (`artifact_manager.dart:545-565` gives the directory, `route_b_provenance.dart:96` the filename). `buildConfig.effectiveDefines['FLUTTER_APP_FLAVOR']` must be `foo` and `buildConfig.flavor` must be `foo` -- the latter is audit-only by design (`route_b_build_config.dart:226-236`).

9. **The Android half, fixture only.** Put `flavorDimensions` + `productFlavors { foo { ... } bar { ... } }` in the same overlay for `android/app/build.gradle.kts`, so the Android order inherits one fixture instead of authoring a second. `ReleasePlatform.ios` and `.android` both report `supportsFlavors` true (`release_platform_extensions.dart:16-20`), so `shorebird_validator.dart:151-168` gates identically on both. **The Android device arm is out of scope here** -- it wants `R2` + `R9` + `R12` and belongs to the `G4.2`/`G4.3` order.

## Precommitted outcomes

Written before step 7 runs, because the favourable-looking outcomes are the dangerous ones. All of these are **producer/host findings**; nothing here is a device finding, and nothing here may be recorded as PROVEN.

| observation | what it MEANS |
|---|---|
| `--flavor foo` builds and `V1/foo` is present in `App` | the overlay is correct and the release program received the define. The prerequisite this order exists to remove is gone |
| `--flavor foo` exits with "The Xcode project does not define custom schemes" (`xcodeproj.dart:626-632`) | the overlay was not applied at all -- the sha gate or the copy failed. Not a flavor finding |
| `--flavor foo` exits with "Flutter expects a build configuration named `Release-Foo` or similar" (`mac.dart:225-234`) | schemes landed, configurations did not. `xcodeproj.dart:590-598` names exactly the missing string |
| build succeeds but `V1/none` is in `App` | **the false green PARITY.md:2064-2072 predicted.** The scheme resolved and the define did not reach Dart. Do not proceed; a device arm on this binary would be an accidental contract |
| build succeeds, `V1/foo` present, `assert_result_consumed.sh` reports the site NOT consumed | the observable is unobservable. Fix the fixture, not the CLI -- and remember block 2's lesson: consumption is necessary and **not** sufficient, reachability is a separate property no byte-level gate sees |
| step 5's accept case fails before the change and passes after | confirms the `ios_patcher.dart:757` defect was real and is closed |
| `patch --flavor bar` fails with "release not found" rather than a defines mismatch | **the arm is INVALID, not passing.** `flavors:` mapped foo and bar to different ids; fix step 4's config and re-run |
| `route_b.json` has no `buildConfig` key at all | the CLI that cut it predates the field -- precondition 5 was violated. This is release 34's failure, and it looks nothing like what it is |

PARITY.md:3226-3231's five-arm table is the authority for the arms themselves and is reused verbatim; three of its five rows need this fixture. Its own rule stands: **a refusal arm that reaches the device has already failed**, so its evidence is the CLI log and the ABSENCE of a container.

## Exit criteria

* **BUILT** -- the fixture exists and is regenerable from committed sources; `--flavor foo`, `--flavor bar` and the no-token `default-flavor` build all produce an `App` carrying the matching `V1/<flavor>`; step 5's matrix is green in `very_good test -r`; `g42_flavor_flow.sh` passes at its new count with row 4 re-aimed. That is the ceiling for this order.
* **PROVEN** -- **not reachable here.** It requires a flavored Route B release plus a same-flavor patch executing on `R1` with the beacon reporting `V2/foo`, which is the `G4.2`/`G4.3` device order's work. Do not upgrade the status because the host arms are clean.
* **NOT RUNNABLE** -- if the pinned Flutter's generated `project.pbxproj` no longer matches the overlay's baseline sha, the overlay is not applicable to this tree and step 3 must be re-derived. That is a different label from unrun, and it must be recorded as one.

## Evidence to record

* `selfhost/fixtures/flavored_app/README.md` -- what is committed vs generated, the arm table, the one-`app_id` reason, and the pinned Flutter revision the overlay's baseline sha was taken at.
* `selfhost/fixtures/flavored_app/ios_overlay/BASELINE.txt` -- `flutter_revision: c15ef6379403a0a55531a058bdb2c8e55bc05c98`, the pre-overlay `project.pbxproj` sha256, the post-overlay sha256, and the scheme + configuration names added.
* `selfhost/evidence/g42_flavored_fixture/host_arms.txt` -- for each of `foo` / `bar` / default: the exact `flutter build` command, its exit code, the `strings | grep -c 'V1/<flavor>'` count, `CFBundleIdentifier`, and the `assert_result_consumed.sh` verdict.
* `selfhost/evidence/g42_flavored_fixture/g42_flavor_flow.txt` -- the probe's output before and after step 6, with both counts.
* If step 8 runs: `selfhost/evidence/g42_flavored_fixture/route_b.json` (copied) plus the release number, and preserve the release's own bytes with `probes/preserve_release_evidence.sh` in the `selfhost/evidence/releases/<n>/` shape (`RECORDED` + `App` + `LC_UUID`, as releases 35 and 36 have).
* Identity facts to carry in every file: cell `4df8f9b6139b67d2cfe9f6aa8212372cade36278`, engine donor `11e5695710275f829ef1e4a45636d39454ca1769`, Flutter `c15ef637…`, `analysisVersion 8`, the commit these were produced at, and the `~/.shorebird` HEAD that ran the CLI.

## Commit shape

Two commits, both from the code worktree for the `packages/` half.

```bash
# 1 -- the fixture and its generator
git add selfhost/fixtures/flavored_app/pubspec.yaml \
        selfhost/fixtures/flavored_app/pubspec.lock \
        selfhost/fixtures/flavored_app/lib/main.dart \
        selfhost/fixtures/flavored_app/assets/probe.json \
        selfhost/fixtures/flavored_app/shorebird.yaml.template \
        selfhost/fixtures/flavored_app/README.md \
        selfhost/fixtures/flavored_app/ios_overlay \
        selfhost/fixtures/flavored_app/android_overlay \
        selfhost/scripts/prepare_flavored_fixture.sh \
        selfhost/evidence/g42_flavored_fixture/host_arms.txt \
        selfhost/PARITY.md
# feat(selfhost): G4.2 -- a flavored iOS fixture, with the flavor observable on a live path

# 2 -- the patch side, and the probe that must stop asserting the old bug
git add packages/shorebird_cli/lib/src/commands/patch/ios_patcher.dart \
        packages/shorebird_cli/test/src/commands/patch/ios_patcher_test.dart \
        selfhost/engine/route_b/probes/g42_flavor_flow.sh \
        selfhost/evidence/g42_flavored_fixture/g42_flavor_flow.txt \
        selfhost/PARITY.md
# fix(selfhost): G4.2 -- the patch side synthesized no flavor, so the matching arm was refused
```

PARITY.md edits that must land in the **same** commits: replace the `⛔ DEVICE GATE BLOCKED -- prerequisite missing: a flavored iOS fixture` row (PARITY.md:2050) with a row naming the fixture path and stating the remaining block is `R1` alone; correct the `12/12` in PARITY.md:2056 to the re-aimed probe's count; add the `ios_patcher.dart:757` defect and its fix to the Flavors table as a `BUILT` row; and add/clear your §17 claims row in the same commit (with TREE HEALTH) if step 8 took `R8`. Never upgrade a status; `BUILT` is the ceiling.

## Do not

* Do not touch `selfhost/fixtures/airgap_app`. Its `R6` claim, its version counter and its `lib/main.dart` belong to whoever holds the canonical leg, and the entire point of H2 is a second fixture.
* Do not give `foo` and `bar` different `app_id`s "for realism". `patch_command.dart:206` + `shorebird_yaml.dart:69-72` turn that into a wrong-reason refusal that reads as a passing mismatch arm.
* Do not let the flavored target be retained by a dead branch. That is exactly what makes `tagged(String x)` unpatchable (`airgap_app/lib/main.dart:124`, called only in `value()`'s dead branch at `:179`) and it is block 2 of the same four.
* Do not add `--dart-define=FLUTTER_APP_FLAVOR=foo` anywhere. `flutter_command.dart:1510-1515` exits on it from `--dart-define`, `--dart-define-from-file` **and** the environment; the config layer synthesizes it instead (`route_b_build_config.dart:57-72`).
* Do not put `flavor` in the fingerprint as its own field. It is one compiler fact -- `effectiveDefines['FLUTTER_APP_FLAVOR']` -- and `route_b_build_config.dart:226-236` records why the separate field is audit-only.
* Do not cut a release from `~/.shorebird` before re-syncing it past step 5, and do not trust a `route_b.json` with no `buildConfig`. Release 34 was discarded for that, and the resulting refusal looks exactly like a `G3.7` failure.
* Do not delete `g42_flavor_flow.sh` row 4 because it fails. Re-aim it -- a probe that stops asserting is worth less than one that asserts the wrong thing loudly.
* Do not run the sealed CDN (`R11`) for any of this. Nothing here needs it, and sealing is host-global.

## Open questions

1. **Committed `project.pbxproj` + sha gate vs scripted surgery.** The gate is verifiable and breaks loudly on a Flutter bump; scripted surgery survives bumps but has no supported interpreter here (`xcodeproj` is only inside cocoapods' vendored gems). The order prescribes the gate; a future Flutter bump is the moment to revisit.
2. **Does the flavored fixture need `code_push_runtime`?** It is what separates `assetsPatchNumber` from `patchNumber` (`airgap_app/pubspec.yaml:19-27`), which the flavor arms do not strictly need. Keeping it costs a path dependency and buys a beacon identical in shape to the canonical fixture's -- worth it only if the device order reuses the airgap harness rather than writing its own.
3. **Whether the device order gets a `--flavor`-aware harness or runs the arms by hand.** `airgap_acceptance.sh` has no flavor token anywhere; teaching it one touches a script the canonical leg depends on, which reintroduces the `R6` coupling H2 exists to avoid.