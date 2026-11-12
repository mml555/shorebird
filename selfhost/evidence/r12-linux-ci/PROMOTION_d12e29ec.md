# Flutter 3.47 (d12e29ec) promotion: the frozen chain and two-arm R12, run on ci-build

Date 2026-11-12. Chain: `selfhost/TOOLCHAIN_PROMOTION.md`. Supersedes the 9056dae9 run
(`PROMOTION_9056dae9.md`, PR #111): the owner chose `d12e29ec` because `9056dae9` has no Route B
iOS engine. CLI commit under test for the bootstrap and both R12 arms:
`5b555d66447abaeb9513dfb75d9fa09cf8006a60`, which contains PR #131 (merge `8b6e6107`).

    flutter_revision   d12e29eccfd56355cebdfb40ef0cb2dc674d65f8   shorebird-flutter shorebird/dev
    engine.version     2c4b071817c52c27142b35ff789749951e5b4d22
    updater_revision   87c198d30f875a3da317d70935e1025dc13064dd   (the updater_rev in that pin's DEPS)
    release candidate  flutter-3.47-candidate.0, Dart 3.13.7
    CLI                1.6.138+selfhost.1

Everything ran on ci-build in `/srv/ci-cache/shorebird-engine/promo-d12e`. Small evidence
files are copied to `promotion-d12e29ec/`; the ledgers are `bootstrap_closure.tsv`,
`proxy_mapping.tsv` and `release_patch_closure.tsv` in this directory (rows appended).

## Setup

- Cold sealed mirror `r12-cdn-sealed` (compose project `r12cold`): production Caddyfile and
  overlay read-only, sealed, its own empty cache volume, recreated per run; origin read
  from `X-Overlay: hit`. The warm production mirror was not restarted or reconfigured.
- Owned Flutter mirror: bare clone of `mml555/shorebird-flutter` (`shorebird/dev` = `d12e29ec`)
  served over `git://` by `r12-flutter-git`.
- Control plane: throwaway `code-push-server:1.4.0`, fresh volume, fixture app id renamed in sqlite.
- Builder `r12-builder:substrate`. HTTPS CA minted for the run, because the checked-in CA's
  name constraints are rejected by Dart's TLS (fix: PR #132, pending owner OK). The mirror's
  https port is the same on the host and in the container (`R12_HOST_CDN`) with
  `CURL_CA_BUNDLE`; the harness scripts require `R12_FLUTTER_REVISION` and `R12_FLUTTER_REF`.
- All of `overlay-2c4b0718` (64 files) was re-compared with the release tar (sha256
  `8a195890e499117eb725aceb50ad3d66a0d53f8119db73d1f3247eae7c211783`): byte-identical.

## Gates

| # | Gate | Result | Evidence |
|---|---|---|---|
| 1 | candidate exists in the owned Flutter mirror | PASS: `d12e29ec` is the head of `shorebird/dev` | `promotion-d12e29ec/guard_candidate.log` |
| 2 | exact `engine.version` | PASS: `2c4b071817c52c27142b35ff789749951e5b4d22` | same |
| 3 | SEALED + COLD bootstrap discovery | PASS, 0 additions: `dart-sdk-linux-x64.zip` and `engine_stamp.json`, both overlay hits | `promotion-d12e29ec/bootstrap_discovery.log` |
| 4 | bootstrap manifest banked | PASS: 2 rows (dart-sdk 214926677 bytes sha `0bfaf194...`, engine_stamp 231 bytes sha `e5fee100...`), manifest digest `52ab7e8f...` | `bootstrap_closure.tsv`, `proxy_mapping.tsv` |
| 5 | `bootstrap_closure_guard.sh` | PASS: `CLOSURE OK`, 2 artifacts size + SHA-256 verified, proxy mapping pinned (`52ab7e8f...` -> `2c4b0718`); run on the candidate and again on the final `compatibility.yaml` | `promotion-d12e29ec/guard_candidate.log`, `guard_final.log` |
| 6 | fresh sealed cold bootstrap | PASS: `launch.sh` bootstrap-only, fresh container, exit 0; 5 overlay hits, 0 `/gcs/`, 0 non-overlay 200s; one 502 for `GET /` (the harness's CA probe) | `promotion-d12e29ec/fresh_bootstrap_launch.log`, `boot1_access.txt` |
| 7 | sealed release/patch artifact discovery | PASS for the closure: 10 imports in 11 iterations, the last refused nothing. The discovery harness's own verdict was FAIL, not applicable (one release in its control plane, so arm 3's chooser legitimately used it); arm 3 is decided by R12 arms A and B, not here | `release_patch_closure_2c4b0718.tsv`, `release_patch_discovery.log` |
| 8 | fresh Linux release/patch smoke | PASS: R12 arms A and B below | `arms/arm-A`, `arms/arm-B`, `armA_access.txt`, `armB_access.txt` |

Gate 7 note: `release_patch_discovery.log` ends `STOP - harness failed`, `EXIT=1`. Its arm 3 got
exit 0 ("Using release 0.8.11+11") because the discovery harness leaves exactly one release in
the control plane, and the chooser legitimately uses the only release. No PASS is claimed for
that arm: it is harness FAIL, not applicable (one release). It is not a #131 defect and not a
closure finding (iteration 11 refused nothing). Arm 3 is decided by R12 arms A and B below,
which have two or more releases.

### What was imported (gate 7)

Ledger `release_patch_closure.tsv`, keyed by the CLIENT path, paired with the 302 that
produced it, size verified, never overwriting a differing file. Non-engine-bound files
(fonts, gradle wrapper, the 38855c84 manifest) were already in the overlay.

- **Stock engine bytes, not built from 2c4b0718** (10 files, under the 2c4b0718 client path):
  `android-{arm,arm64,x64}-profile/linux-x64.zip`, `android-{arm,arm64,x64}/artifacts.zip` (debug)
  and `android-{arm,arm64,x64}-profile/artifacts.zip`. **Nine of the ten were fetched from
  Shorebird's own bucket**, `storage.googleapis.com/download.shorebird.dev/flutter_infra_release/flutter/38855c84.../`
  (the proxy's remap), so they ARE Shorebird-owned artifacts, which bears on the mission's
  "no Shorebird-owned artifacts" rule. Only `android-x86/artifacts.zip` is from
  `storage.googleapis.com/flutter_infra_release/flutter/89c39edf...` (Google's stock). Sources are in the
  ledger's `source` column.

The 2c4b0718 bytes the bootstrap needs are ours (`dart-sdk-linux-x64.zip`, `engine_stamp.json`).

## R12 two-arm recertification: DONE, PASS

The CLI under test contains #131: with no `--release-version`, non-interactive
`shorebird patch` goes to the release chooser and refuses with exit 64 naming "Which release
would you like to patch?" (when several releases exist). The harness is the repo's own: `ci_noninteractive.sh` as committed at `5b555d66`
(last changed in `f93afff58`, sha256 `8864db7a18d8c8b3a13ac7b0c9df958750e8db7bffb3d108af829d413cf13bd5`),
run by the r12 scripts, which were byte-identical to `selfhost/ci/r12/` at `5b555d66` (PR #112, merged;
last changed in `203eca614`). sha256: launch.sh `8b2b70c1...`, run_arm.sh `2d71bc1d...`, mirror_service.sh `174ed406...`,
mirror_cdn_artifact.sh `d743a940...`, discover_release_closure.sh `4362718d...`, bootstrap_closure_guard.sh `6dd3813c...`.
The scripts' own defaults still name the 3.44.8 pin and ref; the run set `R12_FLUTTER_REVISION`
and `R12_FLUTTER_REF` in the environment. Nothing in them was edited for this run.

| Arm | Fixture | Detector self-test | release / patch | `--json` | arm 3 | Verdict |
|---|---|---|---|---|---|---|
| A (`arms/arm-A`) | 1.0.0+1 | exit 64 / 64 | published | exit 0, 0 prompt hits | exit 64, names "Which release would you like to patch?" | PASS |
| B (`arms/arm-B`) | 1.0.1+1 | exit 64 / 64 | published | exit 0, 0 prompt hits | exit 64, same text | PASS |

Each arm: fresh container, fresh cold mirror cache. Arm A container 08:19-08:30, arm B
08:32-08:43, both exit 0; each 38 overlay hits, 0 non-overlay 200s, 0 `/gcs/`, 2 502s
(both `GET /`, the harness's TLS probe). The detector's "outcome 11" (the good failure) is arm 3.

## Debug and profile engines (`flutter run`)

Built from 2c4b0718 and in the overlay (per its PROVENANCE.txt): iOS, ios-profile,
ios-release (Route B on), darwin debug/profile/release, linux-x64 host, android-*-release,
`flutter_patched_sdk`, `sky_engine`, `flutter_gpu`. No engines were built for this task.

- iOS and macOS debug/profile: our 2c4b0718 builds (Route B off). A simulator debug run
  is recorded in STATUS.md.
- Android debug and profile: NOT built for 2c4b0718. A probe of the warm mirror returned a
  302 to `/gcs/download.shorebird.dev/flutter_infra_release/flutter/38855c84.../<path>`. So
  `flutter run` debug/profile on Android pulls Shorebird's own 38855c84 stock-engine bytes
  (9 of 10 imports; only android-x86 is Google's, from 89c39edf) under the d12e29ec 3.47
  framework. That is Shorebird-owned artifacts in the closure, which the mission's "no
  Shorebird-owned artifacts" rule does not allow once the bytes are not ours.
- Whether that combination works on a device or emulator is UNTESTED here. No device or
  emulator run was done for this PR; do not read this as "works".

## Open

- SUPPORTED_STATE.yaml: this pin is recorded under `flutter_3_47_pin` as NOT QUALIFIED as a
  Route B cell (no v2 manifest for 2c4b0718, no cell member verification, compiler and
  analyzer digests unrecorded, producer lineage not durable). `lineage` still describes cell f85251f3.
- Its `ci_noninteractive.deterministic_selection.release` text is stale against #131's chooser semantics.
- Updater: `87c198d30f87` has been in PolicyEpoch.b's eligible revisions since 2026-11-07
  (repository.dart, MEASUREMENT_MODE.md), so nothing changes there. This updater defaults
  `patch_verification` to `install_only` (yaml.rs at 87c198d3; af6e842c defaulted to `strict`):
  a release built without an explicit setting verifies the patch signature at install
  time only, not on each boot.
- Route B iOS: main moves off the qualified v2 cell f85251f3 (selector 5b180d22) to engine
  2c4b0718, which has no v2 manifest. The CLI's lookup of `cell-manifests/2c4b0718....v2` 404s
  and falls back to the v1 rule (`route_b_compiler_cache.dart:165`).
- Coverage: the bootstrap and release/patch closures were discovered on Linux x64 only (no
  macOS or Windows host closure). R12 arm 1 ran with patch signing off.
- `verify_supported_state.sh`: updated in this PR (see PR comment); `packages/shorebird_cli`'s
  HEAD tree no longer equals the qualified product tree, which was already so on main before this PR
  and is not relaxed here.
- TLS CA name-constraints fix: PR #132, pending owner OK (this run used a CA without them).
- Android debug/profile engines: stock bytes stand in (above), unrun on a device.
- `sky_engine` and `flutter_gpu` are UNPROTECTED in `@must_be_local` (accepted, known).
- `flutter --version` prints `3.46.0-1.0.pre-849`: it comes from `git describe` against the mirror's tags.
