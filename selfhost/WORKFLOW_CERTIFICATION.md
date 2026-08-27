<!-- cspell:words noninteractive precommitted -->

# Workflow certification — P6

**What this document is.** One row per workflow this fork claims to support, each
proving the seam that workflow *uniquely* exercises. It exists because "the
command exited 0" is not certification, and because coverage of an adjacent
workflow is not coverage of this one.

**The question every row answers:**

> Can a user exercise this workflow and still get the exact release → patch →
> delivery → execution behaviour this fork promises, with the P4 and P5
> protections remaining active?

**Status vocabulary, and it is deliberately not a boolean:**

| status | meaning |
|---|---|
| `CERTIFIED` | the unique seam is proven, with a negative control, on evidence cited here |
| `PARTIAL` | some links proven, a named link not; the row says which |
| `UNCERTIFIED` | supported in principle, never proven. **Not a claim that it works** |
| `BLOCKED` | cannot be run here, with the missing prerequisite named |
| `UNSUPPORTED` | refused by design |
| `NOT ASSESSED` | no evidence, no claim, not yet examined |

**P6 may close with rows unsupported or deferred.** A truthful support boundary
is the deliverable; ten green rows are not.

**THIS PASS FROZE THE ROWS AND ASSEMBLED CITED EVIDENCE.** Where a row says
`prior evidence`, the run happened earlier and was not repeated here — that is
stated rather than blurred into a fresh certification.

---

## 0 · iOS device prerequisite — Local Network permission

**Promoted out of the flavor arm, because it is not a flavor detail.**

> For a LAN-hosted self-host control plane, **iOS Local Network permission must
> be granted before any transport-dependent device certification.** Absence
> presents as a silent baseline-only app with **no request reaching the server**.

Measured 2026-08-26: with a patch `ready`/`stable`/`active` at 100 % rollout, a
correct device-reachable `base_url`, and two by-hand launches, the app kept
rendering its baseline and the server log contained only this workstation's own
requests. The app declares `NSLocalNetworkUsageDescription`, so iOS gates LAN
access behind a user grant and an ungranted app fails silently. Once granted, the
very next launch produced `POST /api/v1/patches/check -> 200`.

**Nothing on the host can see this.** Release fine, patch fine, rollout 100 %,
app shows its baseline for ever. Every device row below inherits this
prerequisite.

**Scoped separately, deliberately:** the `localhost` base-URL guard is a NARROWER
claim and is *not* part of this invariant. `localhost` is device-unreachable over
Wi-Fi and may be perfectly valid with USB forwarding — see
`evidence/p6-flavor-ios/VERDICT.md`.

---

## 1 · baseline — `CERTIFIED`

| field | value |
|---|---|
| scope | standalone Flutter iOS app, no flavor, no defines, default target |
| release | `shorebird release ios` on `fixtures/privatestate_app` |
| patch | `shorebird patch ios` |
| unique seam | the whole chain end to end, as the control every other row is read against |
| evidence | `fixtures/privatestate_app/evidence/VERDICT.md` (release, patch, rollback all OBSERVED on iPhone 7 / iOS 15.8.8), `P2_VERDICT.md` |
| negative control | rollback observed returning the pre-patch value; and the P1 `_withheld` member refused by name |
| cell | `93a3756…` at the time of the run |
| re-certify when | the updater revision, the engine cell's runtime artifacts, or the container format changes |

## 2 · flavor — `CERTIFIED`

| field | value |
|---|---|
| scope | `--flavor foo` on release and patch |
| unique seam | the flavor must reach the COMPILER (`FLUTTER_APP_FLAVOR`), not just Xcode |
| proven | host: `probes/g42_flavor_flow.sh` **13/13**; Android device: release `--flavor bar` → matching patch → `FLAVORPROBE-V3 → V4`, taken from the REGISTERED artifact (`evidence/android/g42-flavor/POSTFIX_DEVICE_ARM.txt`) |
| negative control | wrong-flavor patch refused before any build begins, `BUILD_CONFIG_MISMATCH`, asserted on the CODE (P5) |
| iOS release, clean CLI | **PROVEN 2026-08-26.** Release **113** (`1.1.0+1`, flavor `foo`) on the P6 device epoch cell `8e659812…`, cut through the real CLI on a dedicated app (`flavoredprobe-p6`), with the complete P4/P5 release shape verified from the SERVER-fetched supplement — 14 fields, four against independently computed digests, and the flavor compared against the SHIPPED program (`V1/Foo`). `evidence/p6-flavor-ios/P6_DEVICE_EPOCH.md` |
| iOS device arm | **PROVEN 2026-08-26.** Release 115 (`1.3.0+1`, `foo`, development-signed) on epoch cell `8e659812…`; patch 79 through the real producer; by-hand taps only. Baseline `V1/Foo` → patched **`V2/Foo`**, with `release:` and `asset:` controls unmoved. Corroborated off-screen by `patches/1/dlc.vmcode.routeb` on the device and `POST /api/v1/patches/check -> 200` on the server. `evidence/p6-flavor-ios/VERDICT.md` |
| what it cost | three defects, none about flavors: replacements did not inherit the target library's imports (Route B, fixed); a device-unreachable `base_url` that failed silently (fixture, guarded); and iOS **Local Network permission** gating the whole transport invisibly — a prerequisite for EVERY device row on this rig |
| evidence | `evidence/g42_flavored_fixture/`, `evidence/android/g42-flavor/` |
| re-certify when | CLI argument parsing changes, or the flavor resolution order changes |

## 3 · Dart defines — `CERTIFIED`

| field | value |
|---|---|
| scope | `--dart-define`, `--dart-define-from-file`, and the six defines Flutter injects |
| unique seam | `const String.fromEnvironment` resolves at COMPILE time, so a patch with different defines bakes a different constant and ships |
| proven | `probes/g41b_define_from_file.sh` **18/18** against Flutter's own resolution; `g41c_injected_defines.sh` **5/5**; `g41d_injected_define_patch.sh` **10/10** — link 1 (ANALYSIS) byte-identical to Flutter's kernel |
| link 2, REPLACEMENT | **PROVEN 2026-08-26.** Release 117 (`1.5.0+1`, `P6_DEFINE=ALPHA73`) on epoch cell `8e659812…`, patch 80. The patch body reads the define INSIDE the replacement; the device rendered **`V2/ALPHA73`** with all three controls unmoved. A release-side value would have proven nothing — `V2` proves the replacement ran, `ALPHA73` proves its own compile got the define, and `defaultValue: 'MISSING'` made a dropped define unmistakable. `evidence/p6-defines/VERDICT.md` |
| what it cost | the precommitted body shape could not publish: a change confined to a canonicalised constant is invisible to coverage and is refused as inert. Fails closed — a capability boundary, not a hole. `evidence/p6-defines/CONSTANT_BLINDNESS.md` |
| negative control | `BUILD_CONFIG_MISMATCH` on differing effective defines; and a define expansion that disagrees with Flutter's own declines patchability at release time |
| evidence | `evidence/g41-define-from-file/`, `evidence/g41-injected-defines/` |
| re-certify when | Flutter's injected-define set changes, or `Generated.xcconfig` stops being the seam |

## 4 · custom target — `CERTIFIED`

| field | value |
|---|---|
| scope | `--target lib/main_b.dart` on release and patch |
| unique seam | which entry point is compiled, and therefore which program the patch is compiled inside |
| the WORKFLOW | **PROVEN 2026-08-26.** Release `1.9.0+1` cut with `--target lib/main_b.dart`, patch 1 built with the same `--target`. Device: `CUSTOM-TARGET-V1` → **`CUSTOM-TARGET-V2`**, controls `TARGET-B` and `CT-RELEASE-1` unmoved. `evidence/p6-custom-target/VERDICT.md` |
| the control that makes it evidence | the release's shipped AOT contains **none** of `main.dart`'s markers (`FLAVORED-FIXTURE-V1`, `BAKED-INTO-RELEASE`, `obf` all 0) because `main.dart` is unreachable from `main_b`. A default-target build would show the opposite set, so this separates "the custom target took effect" from "a patch landed on the usual program" |
| open | **P5-TARGET stays OPEN, deliberately.** The host exploit attempt (`engine/route_b/evidence/p5_target_arm_a.md`) found **no** exploit: a body referring to a member outside the retained libraries is refused as an `added` member with the CORRECT target too, and a mechanism control (retain `package:dep_probe/`, target held constant → the same patch **accepts**) shows retention scope is what decides, not the target. So no target-identity gate was earned and none was invented. `--target` remains logged provenance, and this row certifies the WORKFLOW, not the safety of a mismatched target |
| not claimed | that a *wrong* `--target` is safe. That was never tested on the phone and never will be — it is a host question, answered on the host |
| re-certify when | the retention policy for non-app libraries changes, or `--target` becomes part of the build-semantics authority |

## 5 · obfuscation — `CERTIFIED`

| field | value |
|---|---|
| scope | obfuscated release, patch built with the same configuration |
| unique seam | Route B binds by NAME at run time, so obfuscation could in principle remove the very identity a patch resolves |
| proven | `probes/g43_obfuscation_semantics.sh` — obfuscation changes the stripped program, `--split-debug-info` does not; and the P4.1 arm measured that **names the dynamic interface retains SURVIVE obfuscation** (3,371 of 5,095 renamed, interface-named members preserved) with the three-way partition unchanged |
| the WORKFLOW | **PROVEN 2026-08-26.** Release 119 (`1.7.0+1`, `--obfuscate`) on cell `ca7d2c0d…`, patch 81, target a method on a PRIVATE class. Device: `OBF-V1` → **`OBF-V2-FLD`**, controls unmoved. 16,255 of 17,988 names renamed while `_FooState`/`target`/`_field` stayed preserved in the same map — the control that separates "workflow works" from "flag ignored". `evidence/p6-obfuscation/VERDICT.md` |
| what it cost | two defects: P4.1 refused every member of a private class (failed closed, but silently narrowed a capability P1 had certified), and obfuscated patches died on an unregistered scope ref. Both fixed, both mutation-checked |
| negative control | patch built unobfuscated against an obfuscated release → `BUILD_CONFIG_MISMATCH` (P5) |
| evidence | `engine/route_b/evidence/p41_measurement_note.md`, `probes/g43_obfuscation_semantics.sh` |
| re-certify when | `gen_snapshot`'s obfuscation behaviour changes, or the dynamic interface's retention model changes |

## 6 · CI / noninteractive — `BLOCKED`

| field | value |
|---|---|
| scope | release + patch with no prompts, explicit credentials, deterministic exit codes |
| unique seam | a workflow that must never WAIT for input — the failure mode is a silent hang, not an error |
| proven | `scripts/ci_noninteractive.sh` exists (355 lines); a CI-shaped patch log and a device V3→V4 pair are banked; `airgap_acceptance.sh` documents why `patch` needs `--release-version` (`--no-confirm` does not answer release selection) |
| **blocked on** | **R12, a Linux builder.** The decisive arms are not runnable on this host, which is a missing prerequisite rather than a failed gate |
| negative control | the one that matters is an accidental prompt causing a HANG rather than a non-zero exit; a `stdin` chardev check is banked |
| evidence | `evidence/g10.2-noninteractive/` |
| re-certify when | any prompt is added to a release or patch path |

## 7 · signing — `UNCERTIFIED`

> **Cryptographic verification boundary PROVEN; execution identity RESOLVED
> (no security defect); launch-attribution defect FIXED AND PINNED IN SOURCE,
> NOT YET PROVEN ON HARDWARE.**
>
> Nothing about the fix has run on a device. The bytes on the phone are still the
> old cell. One rejection launch plus one recovery launch on a rebuilt cell is
> the whole remaining gap.

| field | value |
|---|---|
| scope | the real iOS/Android signing path, and that patching does not alter signing assumptions |
| unique seam | artifact-and-signature verification, NOT App Store policy |
| **proven — Dart→Rust seam** | the CLI's own signature and base64-DER public key, from all four surfaces (`--public-key-path`, `--private-key-path`, `--public-key-cmd`, `--sign-cmd` driving real OpenSSL), accepted by the **unchanged production Rust verifier**; mutated signature and wrong message both rejected. `evidence/p6-signing/ARM_A_DART_RUST_SEAM.md` |
| **proven — package signing** | publishing a patch left the server-fetched **iOS** release byte-identical with `codesign` PASS, profile and normalized entitlements unchanged; and the server-fetched **Android** AAB byte-identical with `jarsigner` PASS and its non-debug release certificate unchanged. `ARM_B_PACKAGE_SIGNING.md` |
| **proven — device signature refusal** | the shipped release carries `strict` + DER(K1); a K1-signed patch was verified (*"Patch signature is valid"*) and executed; a patch correctly signed by **K2** was downloaded, installed, and refused at boot as exactly `Bad{ValidationFailed}`, skipped thereafter, and its marker **never rendered**. `ARM_C_DEVICE_SIGNATURE.md` |
| **diagnosed — launch attribution** | **proven, not hypothesised.** `report_launch_start` records `next_boot_patch` before validation; validation then rejects it and nothing corrects `currently_booting_patch`, so `Launch success for patch 2` was logged while patch 1's artifact ran. `last_booted_patch` became **2**, `cleanup_older_than(2)` deleted patch 1, and a later launch dropped to the base release. Root cause found in the engine, not inferred: iOS's `SetBaseSnapshot()` resolves the base isolate snapshot and so reached `ResolveIsolateData()` — which reported launch start — **one line before** `ValidateNextBootPatch()` ran |
| **FIXED IN SOURCE — launch attribution** | one call, `Updater::PrepareNextBootPatch()` → `shorebird_prepare_next_boot_patch()` → `UpdaterState::prepare_next_boot()`: validate, select, attribute in a single state transition, so `currently_booting_patch` == the patch number of the returned path **by construction**. The two old accessors are REMOVED from the C++ interface so the sequence cannot be reassembled. Retention unchanged and no exception needed. Five prepare rows + the load-bearing regression, mutation-tested (old ordering fails 3 of 5 while both happy-path rows still pass — the defect's survival mechanism). Also fixed a vacuity found on the way: `updater_unittests.cc` had **never executed**, because its only target does not link on this host build. `ATTRIBUTION_FIX.md` |
| **RESOLVED — execution identity** | the rejected patch **never executed**. On the rejection boot the engine's `active path:` was `patches/1/dlc.vmcode`, digest `296b9880…` = **P1**, not P2. Validation rejects before selection and selection falls back correctly, so a `Bad{ValidationFailed}` artifact is never handed to the VM. **No security defect.** `ARM_C_EXECUTION_IDENTITY.md` |
| owed to certify | **hardware only.** Rebuild + republish the iOS cell on updater `af6e842ccf87`, activate it through `activate_cell.sh`, then one K2 rejection launch and one recovery launch: patch 1 must continue, not the base release. Arm A, Arm B, the shipped-K1 proof, K1 positive acceptance and host K2 verification are NOT repeated — nothing in this fix touches them |
| blocked on a decision | the revision bump collides with `MEASUREMENT_MODE.md`. Whether the telemetry epoch continues across `f729f958e9be` → `af6e842ccf87`, and whether the new revision joins `eligibleUpdaterRevisions`, are open. Neither blocks the device tail; both block calling the measurement continuous |
| boundary | technical signing-path certification is **not** App Store policy approval. `APPSTORE_COMPLIANCE.md` OPEN-1 remains the distribution-signing arm |
| re-certify when | the signing pipeline or the boot-selection/attribution path changes |

## 8 · tracks — `CERTIFIED` (server-side routing)

| field | value |
|---|---|
| scope | patch published to a track reaches exactly the devices that track selects |
| unique seam | control-plane eligibility, proven on server/wire evidence rather than screenshots |
| the WORKFLOW | **PROVEN 2026-08-26.** Release `1.10.0+1`, ONE patch, rollout 100, two independent clients on `alpha`/`beta`. Deployed to alpha only: A got `patch_available: true` → download+install → `TRACK-V2`; B sent `channel: "beta"`, got `false` twice and produced **zero** events, holding `TRACK-V1`. `evidence/p6-tracks/VERDICT.md` |
| what makes the negative causal | promoting the **unchanged** patch to beta, with no rebuild or reinstall, flipped the **same** `client_id` from `false` to `true` for the **same** patch. Transport, signing, stale release, bad artifact, broken updater, wrong app id and "B cannot update" are each excluded, because every one would have kept B on V1 after the promotion too |
| asserted on | `deployments`, never the singular `channel` field — which after Phase 2 read `'beta'` alone and would have reported the patch as having MOVED off alpha, inverting the multi-track claim. Both tracks were `status=active, rolled_back=False, rollout=100`, and A stayed on V2 |
| config path — **CLOSED, and re-proven from the owned pin** | client-side track selection via supported config was an open defect when this row was certified: the updater read `channel:` from the bundled `shorebird.yaml` while the CLI's parser rejected the key. **Fixed 2026-08-26** in two places — `ShorebirdYaml` + its generated parser (this repo) and `compileShorebirdYaml` (`selfhost/flutter/0001-shorebird-yaml-carry-channel.patch`), the second because the CLI fix alone left the key accepted but silently dropped from the shipped bundle. Verified end to end on device, then **re-demonstrated from the owned Flutter pin** (`a4a3c0d1b1…` on `refs/heads/selfhost/3.44.8`) after a clean bootstrap with a coherence-verified cell activation: `evidence/p6-auto-channel/VERDICT.md` |
| deviation recorded | the two clients are NOT byte-identical bundles: cut from one build, differing in bundle id, display name, bundled channel and executable UUID, with the **AOT payload** verified identical (signature stripped) |
| known gap | **progressive rollout has no client surface at all** — deliberately excluded here, so this result stays a clean test of deterministic track routing (`evidence/g6-tracks-server/rollout_surface.md`) |
| re-certify when | control-plane track logic or eligibility changes |

## 9 · manual updater API — `CERTIFIED`

| field | value |
|---|---|
| scope | `checkForUpdate(track:)` / `update(track:)` with `auto_update: false` |
| unique seam | the app drives the update, so the automatic updater path is bypassed — a device is required by construction |
| the WORKFLOW | **PROVEN 2026-08-26.** Own fixture `manual_api_app`, own app `393fb814-…`, release `3.1.0+1`, one patch on **beta** with **stable empty**. `check(beta)` → `outdated` with nothing downloaded; `update(beta)` → download, `next patch: 1`, `current` still `none`; force-quit + relaunch → **`MANUAL-V2`**, `current patch: 1`. `evidence/p6-manual-api/VERDICT.md` |
| the load-bearing negative | `update(stable)` pressed **seconds after** `check(beta)` reported `outdated` downloaded nothing — and the client log shows it issued its request on `channel=stable`, its own argument. Causal pair 90s apart, only the argument differing: `stable` → no download, `beta` → download. So `update(track:)` does not consume a preceding check's cached eligibility |
| `auto_update: false` proven behaviourally | two by-hand launches with patch 1 live on beta produced **zero** checks and zero events. It is an engine property with no Dart introspection, so absence is the only proof — and it is meaningful because the same client later put a real 200 on the server. Asserted in the **shipped** bundle, not the source |
| relationship to automatic clients | this row proves **application code** can select a track, and deliberately claimed nothing about automatic clients. That separate gap was closed afterwards by supporting `channel:` in configuration (`evidence/p6-auto-channel/VERDICT.md`); the two remain distinct surfaces — this one needs no config, that one needs no Dart |
| second constant-blindness instance | the fixture's first shape used a top-level `const` as the target and the patch was **correctly refused** as a no-op. Release 122 is left unpatched as the record; marker moved into a function body and the release re-cut. **The refusal is right; the diagnosis is missing** |
| re-certify when | the updater API surface or `auto_update` handling changes |

## 10 · Add-to-App — `NOT ASSESSED`

| field | value |
|---|---|
| scope | Flutter embedded in an existing native app |
| unique seam | engine initialisation, host lifecycle and packaging all differ from a standalone app — the highest chance of being genuinely different |
| proven | nothing, and nothing examined |
| position | deliberately last, and **explicitly not a blocker** for the rest of P6 |
| re-certify when | engine initialisation changes |

---

## What this matrix says overall

Six rows are certification of machinery that already exists and mostly works;
four are where new findings should be expected. Nothing here is claimed green to
satisfy a checklist:

- `CERTIFIED`: 7 (baseline, flavor, Dart defines, obfuscation, custom target, tracks — scoped to server-side routing — and manual updater API)
- `P6_DEVICE_EPOCH_READY = true` — cell `8e659812…`, release 113, inherited by every later device row rather than re-established per row
- `BLOCKED`: 1 (CI, on a Linux builder)
- `UNCERTIFIED`: 1 (signing)
- `NOT ASSESSED`: 1 (Add-to-App)

**Signing is the one remaining uncertified row.** Its three arms are proven and
its one real defect — false launch attribution destroying the last-known-good
patch — is now fixed in source and mutation-tested. What is outstanding is a cell
rebuild plus two by-hand launches, and one cross-lane decision about the
telemetry epoch (`MEASUREMENT_MODE.md`). No design work remains.
