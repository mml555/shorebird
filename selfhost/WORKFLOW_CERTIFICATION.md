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

| field | value |
|---|---|
| scope | the real iOS/Android signing path, and that patching does not alter signing assumptions |
| unique seam | artifact-and-signature verification, NOT App Store policy |
| proven | a source-determined classification only: `evidence/g7-signing/verification_path.md` states plainly *"No device, no run, no release"* |
| owed | release signed as expected; the patch workflow shown not to alter app-signing assumptions; final IPA/APK/AAB verification; no new entitlement or profile behaviour |
| boundary | technical signing-path certification is **not** App Store policy approval. `APPSTORE_COMPLIANCE.md` OPEN-1 remains the distribution-signing arm |
| re-certify when | the signing pipeline changes |

## 8 · tracks — `UNCERTIFIED`

| field | value |
|---|---|
| scope | patch published to a track reaches exactly the devices that track selects |
| unique seam | control-plane eligibility, proven on server/wire evidence rather than screenshots |
| proven | nothing end to end. `fixtures/trackprobe_app` exists and is shaped so the negative is falsifiable |
| known gap | **progressive rollout has no client surface at all** — a source-determined classification, so booking a run would produce a meaningless green (`evidence/g6-tracks-server/rollout_surface.md`) |
| owed | patch on track A delivered to an eligible client; a client on track B NOT served it; promotion/move if supported; rollback still track-correct |
| re-certify when | control-plane track logic or eligibility changes |

## 9 · manual updater API — `UNCERTIFIED`

| field | value |
|---|---|
| scope | `checkForUpdate(track:)` / `update(track:)` with `auto_update: false` |
| unique seam | the app drives the update, so the automatic updater path is bypassed — a device is required by construction |
| proven | nothing. `evidence/g8-manual-api/host_reachability.md` records that the host arm as specified is **not runnable and the fixture would have proved nothing** |
| owed | check → download → next-launch/apply semantics → an execution marker → rollback if the API exposes it. Lifecycle itself is already closed, so only the API seam is owed |
| design note | the fixture records the patch number BEFORE `update()` and shows both, so the assertion is that the number changed across a call the app made — `readCurrentPatch` alone is a named false green |
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

- `CERTIFIED`: 5 (baseline, flavor, Dart defines, obfuscation, custom target)
- `P6_DEVICE_EPOCH_READY = true` — cell `8e659812…`, release 113, inherited by every later device row rather than re-established per row
- `BLOCKED`: 1 (CI, on a Linux builder)
- `UNCERTIFIED`: 3 (signing, tracks, manual updater API)
- `NOT ASSESSED`: 1 (Add-to-App)

**The recurring shape of the gap is the same in the three remaining rows: the
host half is proven and the device half is not.** That is worth stating as one fact rather
than four, because it means the outstanding work is mostly rig time, not design.
