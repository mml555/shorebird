<!-- cspell:words rollforward -->
# Upstream parity matrix

Every upstream Shorebird feature, classified for this self-hosted fork. Read on 2026-11-12 against
`fork/main` at `04343bad9` (after #134 to #143), and updated on 2026-11-13 at `daa66429` (after #155) for the
scripted iPhone run and the full Android run on the pinned cell `82fc78a8`. The current state of the work is in
[`STATUS.md`](STATUS.md); this file is only the feature-by-feature verdict. It is not
[`PARITY.md`](PARITY.md), which is an unrelated historical log.

| Status | Meaning here |
|---|---|
| **working** | Seen running on a real device or a real release build, on the engine named in the row, with the date and whether by hand or in CI. |
| **partial** | Some links proven, a named link not. Anything proven only on the older 3.44 Route B stack ("carried forward" in [`WORKFLOW_CERTIFICATION.md`](WORKFLOW_CERTIFICATION.md)) is here, with that gap stated. |
| **unsupported** | Refused by design, or the CLI calls a server route that does not exist (checked in the code, not run). |
| **untested** | No run recorded either way. Not a claim that it works. |

## The evidence that carries most rows

- **CI-ANDROID**: [run 43377806371](https://github.com/mml555/shorebird/actions/runs/43377806371), 2026-11-13,
  the `selfhost_android_e2e` full scenarios, green, on the #146 branch, which `main` now holds: shorebird-flutter
  `f6bbc8a0`, cell `82fc78a8` over engine `2c4b0718`. The earlier full run cited here,
  [43300439389](https://github.com/mml555/shorebird/actions/runs/43300439389) (2026-11-12, `d12e29ec`), had scenarios 1
  to 8; #145 added 8a, 9 and 10. The nightly run on `main`
  ([43416336995](https://github.com/mml555/shorebird/actions/runs/43416336995), 2026-11-13) is the quick scenario only
  (release, patch 1 boots). The pool served an **x86_64 emulator**, not a
  physical phone (the job is named "pool phone"; [`PROMOTION_d12e29ec.md`](evidence/r12-linux-ci/PROMOTION_d12e29ec.md)
  records that qa-1 to qa-3 are emulators). It builds real release APKs with this checkout's CLI against a throwaway
  `code_push_server` (SQLite). Scenarios, from the log's `ok:` lines: patch 1 boots; a real Dart change; consecutive
  patch 2; rollback of patch 2 restores patch 1; rollback of patch 1 returns to the release; rollback of the only patch;
  release-version targeting (0.1.0+1 patch not offered to 0.2.0+2); a patch signed with the release's key boots with
  verification on; a patch signed with another key is refused by the CLI before publication; a native change is refused
  and nothing is published; a patched app boots with the server down, and the restarted server serves again; the
  server restarts on its data dir with nothing lost (8a); staged rollout at 40%, 41% and 100% against the phone's
  bucket (9); backup, wipe and restore, then a new patch reaches the phone (10).
- **IOS-E2E**: [`ios-e2e-82fc78a8/RESULT.md`](engine/route_b/evidence/ios-e2e-82fc78a8/RESULT.md), 2026-11-13, merged
  in #155. iPhone 7 (iOS 15.8.8), cell `82fc78a8`, CLI `357bc24f` (on `main`), a self-hosted `code_push_server`, every
  artifact fetched through a recording origin. Run by a script, `selfhost/ci/ios_device_e2e.sh`, not by hand, except
  one Local Network "OK" tap per install. It is Android's scenario list on iOS: base release; patch 1 (a real Dart
  change); consecutive patch 2; CLI rollback of patch 2, then of patch 1, then of a release's only patch; two releases
  targeted separately; signing (a good-key patch boots with verification on, another key is refused by the CLI); server
  restart on its data dir; server down; staged rollout at 84%, 85% and 100%; backup and restore. 31 launches, 0 launch
  disappearances. Took six invocations (script bugs, a lost signing key, a USB debug-service fault); `RESULT.md` lists
  each and says which scenario was run as a reduced check.
- **IOS-HAND** (superseded by IOS-E2E): iPhone 7 (iOS 15.8.8), engine `2c4b0718`, 2026-11-11, by hand, with a fork CLI built from `main` plus an
  unpushed local merge of #111 (`flutter.version` = shorebird-flutter `efe3162e`, head of #12), a local server and the
  ci-build mirror. Details in [`STATUS.md`](STATUS.md#ios-code-push-on-2c4b0718-route-b) and
  [shorebird-flutter#12](https://github.com/mml555/shorebird-flutter/pull/12#issuecomment-6800938572).
- **ANDROID-PHONE-HAND**: OnePlus CPH2551, engine `7806e0fb`, 2026-11-10, by hand, CLI from the #111 branch. An older
  engine than `main`'s pin. See [`STATUS.md`](STATUS.md#device-runs-on-7806e0fb).
- **R12**: [`PROMOTION_d12e29ec.md`](evidence/r12-linux-ci/PROMOTION_d12e29ec.md), 2026-11-12, two arms on ci-build
  (Linux builder, cold sealed mirror) with the CLI at `5b555d66` (contains #131): release and patch are published, no
  device involved.
- **AUG-OLD**: the P6 certification of Aug to Sep 2026 on the 3.44 Route B stack, mostly iOS, on hardware, "carried
  forward" and not re-run on `2c4b0718`. Cited per row from [`WORKFLOW_CERTIFICATION.md`](WORKFLOW_CERTIFICATION.md).

## 1. Platforms and release types

| Feature | Status | Evidence | What is missing |
|---|---|---|---|
| Android release + patch (apk), emulator | **working** | CI-ANDROID: engine `2c4b0718`, 2026-11-12, in CI | x86_64 emulator only; aab, other ABIs and a real build of a user's app are not in the run |
| Android release + patch, physical phone | **partial** | ANDROID-PHONE-HAND: release 1.0.0+1 and a patch shown after two restarts | Engine `7806e0fb`, not `main`'s `2c4b0718`; by hand; not repeated on a phone since the pin moved |
| Android debug / profile (`flutter run`) | **untested** | [`STATUS.md`](STATUS.md#in-flight) (#134 line); [`PROMOTION_d12e29ec.md`](evidence/r12-linux-ci/PROMOTION_d12e29ec.md) | No debug or profile engine of ours for `2c4b0718`; stock bytes (9 of 10 from Shorebird's own bucket) stand in, never run on a device |
| Android add-to-app (`release aar`) | **untested** | [`WORKFLOW_CERTIFICATION.md`](WORKFLOW_CERTIFICATION.md) row 10 "NOT ASSESSED" | Wire shape documented in [`PLATFORM_MATRIX.md`](PLATFORM_MATRIX.md), never run |
| iOS release (ipa) on a device | **working** | IOS-E2E: two releases (1.0.0+1 unsigned, 2.1.0+3 signed) installed and ran | One old device, resign mode, not in CI; needs `SHOREBIRD_ARTIFACT_ORIGIN`; one Local Network "OK" tap per install |
| iOS patch on a device (Route B, not upstream's linker) | **working** (one device, not in CI) | IOS-E2E: V's patches 1 to 3 and W's 1 to 6 downloaded and booted ("ROUTEB: applied N/N targets", "Launch success for patch N"), rollbacks restored the earlier patch or the release; cell `82fc78a8` is the device-qualified cell in [`SUPPORTED_STATE.yaml`](engine/route_b/SUPPORTED_STATE.yaml) | One iPhone 7. The patches are small changes to existing members. Logs do not show which calls ran in the interpreter, and its speed is not measured. Supersedes IOS-HAND, whose CLI was an unpushed local merge |
| iOS patch: arbitrary Dart changes | **partial** | [`ROUTE_B.md`](ROUTE_B.md); [`producer_demand_2.md`](engine/route_b/evidence/producer_demand_2.md) | Route B refuses many change kinds at `shorebird patch` time. Only 3.44-era numbers exist (50% of observed method changes accepted in Wonderous, 92.7% in LocalSend); the owner chose not to re-measure on 3.47. Foldable-constant patches attach and do nothing. Patched functions run in an interpreter, speed not measured |
| iOS release or patch in CI | **untested** | [`STATUS.md`](STATUS.md) stable baseline row 8: "iOS: none" | IOS-E2E's script is ready for it; needs a Mac runner with the phone attached, and a tap after each fresh install |
| iOS on older engines `255fd850`, `7806e0fb` | **unsupported** | [`STATUS.md`](STATUS.md#device-runs-on-7806e0fb): `shorebird patch ios` refuses | Superseded by `2c4b0718`; releases run, patches do not |
| iOS add-to-app (`release ios-framework`) | **untested** | [`evidence/addtoapp1/RESULT.md`](evidence/addtoapp1/RESULT.md) (2026-09-03): stopped at qualification | Four blockers, the first being that the engine publishes a device-only `Flutter.xcframework`; nothing refuses it, it is a build gap, and Route B is not implemented for it. [`DESKTOP_PLATFORMS.md`](DESKTOP_PLATFORMS.md) calls these artifacts "device-verified", which contradicts `RESULT.md` and `WORKFLOW_CERTIFICATION.md` row 10 ("NOT ASSESSED"); I trust the run log |
| macOS release / patch | **untested** | [`DESKTOP_PLATFORMS.md`](DESKTOP_PLATFORMS.md) | Server is platform-agnostic by code audit only (`DESKTOP_PLATFORMS.md`, which also conflicts with `RESULT.md`, see the iOS add-to-app row); macOS engine host side built, no macOS app release or patch recorded |
| Windows release / patch | **untested** | [`DESKTOP_PLATFORMS.md`](DESKTOP_PLATFORMS.md) | No Windows engine built, no Windows host |
| Linux desktop release / patch | **untested** | [`DESKTOP_PLATFORMS.md`](DESKTOP_PLATFORMS.md) | Linux is only the CI build host for Android today (R12); no Linux desktop app released or patched |

## 2. CLI workflow

| Feature | Status | Evidence | What is missing |
|---|---|---|---|
| `release android` / `patch android` with an API key (`SHOREBIRD_TOKEN`) against the self-hosted server | **working** | CI-ANDROID | Android only; the iOS equivalent is IOS-E2E |
| `patch --release-version`, release targeting | **working** | CI-ANDROID: patch for 0.1.0+1 not offered to 0.2.0+2; IOS-E2E 5b and 5c: the same on iOS | |
| Non-interactive patch refuses to guess the release (#131) | **working** | R12 arms A and B: exit 64 naming "Which release would you like to patch?", `--json` exit 0 | Engine `2c4b0718`; a Linux builder, no device; `SUPPORTED_STATE.yaml`'s `ci_noninteractive` text is stale against #131 |
| `patches rollback` (restores the previous patch, #138) | **working** | CI-ANDROID and IOS-E2E: the CLI command, three scenarios each, device log shows the old patch (or the release) again | Android on an emulator; iOS on one phone, by script |
| `patches rollforward` | **unsupported** | `api.dart` answers 501 by design; [`upstream/ADOPTION-1.6.123.md`](upstream/ADOPTION-1.6.123.md) s3 | A rolled-back patch is withdrawn for good |
| Native-change guard on patch, Android | **working** | CI-ANDROID: exit 70 "Not publishing: native code changed", nothing published | |
| Native-change guard on patch, iOS | **partial** (same as upstream) | IOS-E2E 7a: a Podfile.lock change is refused (exit 70) and nothing is published; a Swift-only change is published | Upstream's `apple_patcher_mixin.dart` passes `confirmNativeChanges: false`, so only a Podfile.lock hash change is refused. Flutter 3.46 apps use Swift Package Manager by default and have no Podfile.lock, so for them no native change is refused at all. A gap shared with upstream, not a fork regression |
| `patches promote` / `set-track` (release-scoped since #139) | **partial** | `set-track` calls `POST /apps/{id}/patches/promote`, which the server serves; AUG-OLD row 8, [`p6-tracks`](evidence/p6-tracks/VERDICT.md) (device A/B) | Device proof is Aug, 3.44, iOS; the #139 release-scoping has server tests but no device run; not in CI-ANDROID |
| `doctor --fix` | **working** | CI-ANDROID run 43300439389 (2026-11-12, d12e29ec / 2c4b0718): `android_pool_e2e.sh` runs `doctor --fix` and asserts it added the Android INTERNET permission | Emulator, CI only |
| `init`, `create`, browser `login` | **untested** | Routes served (`/login`, `/token`, `/diagnostics/*`, `POST /apps`) | No dedicated run recorded; CI-ANDROID authenticates with an API key |
| `login:ci` | **unsupported** (removed upstream too) | `LoginCiCommand.run()` says it "has been replaced by API keys", points to service-account keys and exits 64; the file is identical to upstream's | Not a fork gap. The fork's CI path is an API key (`SHOREBIRD_TOKEN`); service-account keys have no route here (below), so the message's advice does not apply |
| `--flavor` | **partial** | AUG-OLD row 2: iOS device and Android [`g42-flavor`](evidence/g42_flavored_fixture) | Aug, 3.44 stack, carried forward |
| `--dart-define`, `--dart-define-from-file` | **partial** | AUG-OLD row 3 | Carried forward |
| `--target` | **partial** | AUG-OLD row 4 | Carried forward |
| `--obfuscate` / `--split-debug-info` | **partial** | AUG-OLD row 5, [`p6-obfuscation`](evidence/p6-obfuscation/VERDICT.md): iOS device | Aug, 3.44 stack, iOS only; no Android device run cited |
| `releases list/info/delete`, `get-apks` | **untested** | Routes served (`GET`/`DELETE` releases, artifacts) | `releases list` is called in R12 but its output is not asserted |
| `patches list/info` | **untested** | `GET /apps/{id}/releases/{id}/patches` served | No run |
| `channels create/list/delete` | **untested** | Routes served | Exercised only inside the Aug track runs |
| `preview` | **untested** | None | |
| `flutter versions list/use` | **untested** | None | The fork pins its own Flutter; the mirror is not a version source |
| `cache clean`, `upgrade` | **untested** | None | `upgrade`'s `git checkout stable` hint would install an old CLI |
| `--json` output | **untested** | R12 arms check `--json` exit 0 on `patch` only | |
| `whoami`, `metrics *`, `patches stats` (#133) | **partial** | `/plan` and `/apps/{id}/metrics/*` are now served; server tests in `api_test.dart` | No CLI-to-server run recorded |

## 3. Tracks, rollout, delivery

| Feature | Status | Evidence | What is missing |
|---|---|---|---|
| Tracks / channels: server routing | **partial** | AUG-OLD row 8; [`p6-tracks`](evidence/p6-tracks/VERDICT.md): two devices on alpha and beta, promote flips the same client | Aug, iOS, 3.44; not re-run |
| Client chooses its track (`channel:` in the checked-in shorebird.yaml) | **partial** | [`p6-auto-channel`](evidence/p6-auto-channel/VERDICT.md) | Needed a Flutter patch to `compileShorebirdYaml`, checked on an older pin only |
| Updater API `checkForUpdate(track:)` | **partial** | [`p6-manual-api`](evidence/p6-manual-api/VERDICT.md) | Aug, iOS, not re-run |
| Percentage (staged) rollout | **partial** | Device runs: CI-ANDROID scenario 9 (not offered at 40% for bucket 4072, offered at 41%, taken at 100%) and IOS-E2E scenario 9 (84%, 85%, 100% for bucket 8423), both through `POST /admin/apps/{id}/patches/{id}/rollout`; [`g6-tracks-server`](evidence/g6-tracks-server/rollout_surface.md) | Works on devices, but only through the admin API. The server accepts a percentage on `POST /apps/{id}/patches/promote` (`rollout` in the body, 0 to 100) as well as on the admin route, but `patches set-track` sends no `rollout` and no CLI flag exists; no server route for the protocol's `SetPatchRolloutRequest` |
| Patched app boots with the server unreachable | **working** | CI-ANDROID scenario 8; IOS-E2E scenario 8 ("Update failed: Network request failed", the patched boot stays up) | Android on an emulator; iOS on one phone |
| Server restart mid-flow | **working** | CI-ANDROID and IOS-E2E scenario 8a: a patch published before the restart reaches the device after it | SQLite data dir; Postgres not run |
| Patch download / install events | **partial** | `__patch_download__` and `__patch_install__` seen on the phone in ANDROID-PHONE-HAND | Engine `7806e0fb`; CI-ANDROID does not assert events |
| Crash reports | **partial** | Server routes and symbolication (`/crashes`, `symbolication.dart`) | No device-sent crash report recorded |
| First-activation "launch disappearance" | **partial** | AUG-OLD: 3 occurrences on iOS. IOS-E2E: 0 in 31 launches on cell `82fc78a8`, each patch's first activation among them | Not fixed, only not seen again; the cause of the August ones is unknown, so 31 launches do not rule it out |

## 4. Security

| Feature | Status | Evidence | What is missing |
|---|---|---|---|
| Patch signing (`--public-key-path`, `--private-key-path`), iOS | **working** | IOS-E2E scenario 6: W's bundled shorebird.yaml carries `patch_public_key`, V's does not; "Patch signature is valid" and the signed patch boots; another key is refused by the CLI with exit 70 | One phone. The device refusing a wrongly signed patch at boot is still only AUG-OLD |
| Patch signing (`--public-key-path`, `--private-key-path`), Android | **working** | CI-ANDROID scenario 6: release carries `patch_public_key`; signed patch boots with verification; wrong-key patch refused by the CLI before publication | Emulator. The device refusing a wrongly signed patch at boot was shown only in AUG-OLD (iOS, [`p6-signing`](evidence/p6-signing/ARM_C_DEVICE_SIGNATURE.md)) |
| Signing on by default | **partial** | [`PROMOTION_d12e29ec.md`](evidence/r12-linux-ci/PROMOTION_d12e29ec.md): updater `87c198d3` defaults `patch_verification` to `install_only`; unsigned is the default | Same as upstream (opt-in), but the "loud opt-in warning" is still owed ([`SIGNING.md`](SIGNING.md)) |
| Server-managed (enterprise) signing key | **untested** | `GET /apps/{id}/signing-key` is served | No run |
| App Store acceptance of Route B | **untested** | [`APPSTORE_COMPLIANCE.md`](APPSTORE_COMPLIANCE.md) OPEN-1 | Technical audit only |

## 5. Accounts, orgs and server routes

Checked against `_dispatch` in `packages/code_push_server/lib/src/api.dart` and the calls in
`packages/shorebird_code_push_client/lib/src/code_push_client.dart`. "No route" means the CLI gets a 404. This is
read from code, not run.

| Feature | Status | Evidence | What is missing |
|---|---|---|---|
| Apps, releases, patches, artifacts, uploads API | **working** | CI-ANDROID against a real `code_push_server` | SQLite only; Postgres and S3 not in this run |
| API-key auth | **working** | CI-ANDROID uses an API key | |
| OIDC / Google / Microsoft sign-in | **untested** | [`IDP_SETUP.md`](IDP_SETUP.md); `oauth.dart` | No real IdP run read; `IDP_ISSUER` must be set before the next deploy (#93) |
| `orgs list`, app rename, app transfer, invitation accept | **untested** | `GET /organizations`, `PATCH /apps/{id}`, `POST /organizations/{id}/apps`, `POST /invitations/{id}/accept` exist | No run |
| `apps delete` | **unsupported** | No `DELETE /apps/{id}` route | |
| `orgs create/update`, `members *`, org `invitations`, `GET` org apps | **unsupported** | No `/organizations/{id}/users`, `/invitations`, `/apps` route; the server's `/admin/orgs/...` routes have different paths | Reachable only through the console / `/admin` API |
| `invitations list / decline` | **unsupported** | Only `POST /invitations/{id}/accept` exists | |
| `audit-log`, `usage` | **unsupported** | CLI calls `/organizations/{id}/audit-logs` and `/usage`; the server's log is `/admin/audit` | |
| `service-accounts *` (keys, trust rules) | **unsupported** | No route | |
| `enterprises *`, billing | **unsupported** | No route | SaaS features; only the `patch_signing_required` flag was synced (#79) |
| `account update`, `account notifications` | **unsupported** | No `PATCH /users/me`, no `/users/me/notification_preferences` | |
| `tokens list` | **unsupported** | With a login credential the CLI calls `api/api-keys`; no such route. With an API key it skips the call and opens the console page | `tokens create/delete` only open a console page. Not exhaustive: `orgs get` (no `GET /organizations/{id}`) and `account sessions` (`api/sessions`) also have no route; `apps list`, `account apps`, `auth status` and `auth token` were not run |

## 6. Running it yourself (fork-only, but it decides whether you can replace upstream)

| Feature | Status | Evidence | What is missing |
|---|---|---|---|
| Engine and artifact mirror, release closure (replaces `download.shorebird.dev`) | **working** | R12 on a cold sealed mirror (38 overlay hits per arm, 0 `/gcs/`). CI-ANDROID uses it by the script's default `SHOREBIRD_ARTIFACT_ORIGIN` (`http://127.0.0.1:8085`); the run log has no mirror line, so that is read from the script | Plain HTTP in CI-ANDROID and production (R12 used a run-minted CA over HTTPS); one host (ci-build); Gradle needs `isAllowInsecureProtocol`; TLS step is the owner's |
| Mirror, Android debug/profile closure | **partial** | [`PROMOTION_d12e29ec.md`](evidence/r12-linux-ci/PROMOTION_d12e29ec.md) | 9 of 10 imports come from Shorebird's own bucket (`38855c84`) through the mirror's `/gcs/` passthrough, so a clean machine still depends on Shorebird-owned artifacts; open against the owner's mission goal, not run on a device |
| Backup and restore | **partial** | [`backup_restore/CERTIFICATION.md`](backup_restore/CERTIFICATION.md); CI-ANDROID and IOS-E2E scenario 10: back up, wipe, restore, then a new patch reaches the device | Throwaway servers (SQLite), not a production restore; off-server copy of `PATCH_SIGNING_KEY_SECRET` unconfirmed (STATUS row 9) |
| Publish durability | **partial** | [`evidence/publish-durability-1.4.0/`](evidence/publish-durability-1.4.0/README.md): 447 releases, 445 patches, 0 lost | API driver only; the 2026-08 loss was never explained |
| arm64 server image | **untested** | [`STATUS.md`](STATUS.md) open item 10 | Not built: releases are amd64 only, nothing refuses arm64 |

## Biggest gaps, by impact on someone replacing upstream

1. **iOS patches cover a subset of Dart.** Route B refuses many change kinds and has only 3.44-era acceptance numbers.
   The full release, patch, rollback, signing, rollout and restore list now passes by script on one iPhone 7
   (IOS-E2E), but not in CI. This decides whether iOS code push is usable at all.
2. **No desktop code push and no add-to-app.** macOS, Windows and Linux are untested; `aar` is untested and
   `ios-framework` is unsupported.
3. **Android on a physical phone is not shown on `main`'s pin.** CI proves Android on an emulator; the phone run is on
   `7806e0fb`. Debug and profile builds use stock engine bytes that have never run on a device.
4. **Team and account commands fail against the server**: `orgs create/update`, `members`, `service-accounts`,
   `enterprises`, `audit-log`, `usage`, `tokens list`, `apps delete`, `account update`. Members, invitations and the
   audit log have `/admin` routes and console pages instead (`selfhost/API_REFERENCE.md`); service accounts,
   enterprises, usage and account updates have no equivalent at all.
5. **Rollout has no CLI flag.** The server takes a percentage on promote and on an admin route, and both device runs
   used the admin route, but `set-track` sends none. Tracks, flavors, defines, targets and obfuscation rest on Aug 2026
   runs of an older stack.
6. **Signing is opt-in and not warned about**, and the managed-key flow is untested.
7. **The mirror is single-host plain HTTP**, and engine origins must be set by the developer on a LAN.
8. **A first-activation "launch disappearance" defect** (3 iOS occurrences, Aug) is not fixed; IOS-E2E saw none in
   31 launches.
9. **iOS native changes are barely guarded**, as upstream: only a Podfile.lock change is refused, and Swift Package
   Manager apps (Flutter's default) have none.

## Not verified

- Whether `init`, browser login, `preview`, `flutter versions`, `--json` and the org commands that do have
  routes work end to end: no run was found.
- Whether CI-ANDROID's emulator result holds on a physical phone, or on `main` itself rather than the #142 branch.
- Anything on a real IdP, Postgres or S3.
- The "no route" rows are code reads. They were not run against a live server.
