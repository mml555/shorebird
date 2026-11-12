<!-- cspell:words rollforward -->
# Upstream parity matrix

Every upstream Shorebird feature, classified for this self-hosted fork. Read on 2026-11-12 against
`fork/main` at `04343bad9` (after #134 to #143). The current state of the work is in
[`STATUS.md`](STATUS.md); this file is only the feature-by-feature verdict. It is not
[`PARITY.md`](PARITY.md), which is an unrelated historical log.

| Status | Meaning here |
|---|---|
| **working** | Seen running on a real device or a real release build, on the engine named in the row, with the date and whether by hand or in CI. |
| **partial** | Some links proven, a named link not. Anything proven only on the older 3.44 Route B stack ("carried forward" in [`WORKFLOW_CERTIFICATION.md`](WORKFLOW_CERTIFICATION.md)) is here, with that gap stated. |
| **unsupported** | Refused by design, or the CLI calls a server route that does not exist (checked in the code, not run). |
| **untested** | No run recorded either way. Not a claim that it works. |

## The evidence that carries most rows

- **CI-ANDROID**: [run 43300439389](https://github.com/mml555/shorebird/actions/runs/43300439389), 2026-11-12,
  the `selfhost_android_e2e` full scenarios, green. It ran on the #142 branch (main plus that test's own change),
  with `main`'s pin: shorebird-flutter `d12e29ec`, engine `2c4b0718`. The pool served an **x86_64 emulator**, not a
  physical phone (the job is named "pool phone"; [`PROMOTION_d12e29ec.md`](evidence/r12-linux-ci/PROMOTION_d12e29ec.md)
  records that qa-1 to qa-3 are emulators). It builds real release APKs with this checkout's CLI against a throwaway
  `code_push_server` (SQLite). Scenarios, from the log's `ok:` lines: patch 1 boots; a real Dart change; consecutive
  patch 2; rollback of patch 2 restores patch 1; rollback of patch 1 returns to the release; rollback of the only patch;
  release-version targeting (0.1.0+1 patch not offered to 0.2.0+2); a patch signed with the release's key boots with
  verification on; a patch signed with another key is refused by the CLI before publication; a native change is refused
  and nothing is published; a patched app boots with the server down, and the restarted server serves again.
- **IOS-HAND**: iPhone 7 (iOS 15.8.8), engine `2c4b0718`, 2026-11-11, by hand, with a fork CLI built from `main` plus an
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
| iOS release (ipa) on a device | **working** | IOS-HAND: release 1.0.0+1 launched and ran | By hand, one old device, resign mode; needs `SHOREBIRD_ARTIFACT_ORIGIN`; one Local Network "OK" tap per install |
| iOS patch on a device (Route B, not upstream's linker) | **working** | IOS-HAND: patch 3 downloaded, next launch `ROUTEB: applied 1/1 targets`, marker shown, then rollback ran the release again | One small patch on one engine, by hand. Logs do not show which calls ran in the interpreter. `2c4b0718` is not a qualified cell ([`SUPPORTED_STATE.yaml`](engine/route_b/SUPPORTED_STATE.yaml) names `f85251f3`) |
| iOS patch: arbitrary Dart changes | **partial** | [`ROUTE_B.md`](ROUTE_B.md); [`producer_demand_2.md`](engine/route_b/evidence/producer_demand_2.md) | Route B refuses many change kinds at `shorebird patch` time. Only 3.44-era numbers exist (50% of observed method changes accepted in Wonderous, 92.7% in LocalSend); the owner chose not to re-measure on 3.47. Foldable-constant patches attach and do nothing. Patched functions run in an interpreter, speed not measured |
| iOS release or patch in CI | **untested** | [`STATUS.md`](STATUS.md) stable baseline row 8: "iOS: none" | Needs a Mac runner |
| iOS on older engines `255fd850`, `7806e0fb` | **unsupported** | [`STATUS.md`](STATUS.md#device-runs-on-7806e0fb): `shorebird patch ios` refuses | Superseded by `2c4b0718`; releases run, patches do not |
| iOS add-to-app (`release ios-framework`) | **unsupported** | [`evidence/addtoapp1/RESULT.md`](evidence/addtoapp1/RESULT.md) (2026-09-03) | Four blockers there; Route B not implemented for it |
| macOS release / patch | **untested** | [`DESKTOP_PLATFORMS.md`](DESKTOP_PLATFORMS.md) | Server is platform-agnostic by code audit only; macOS engine host side built, no macOS app release or patch recorded |
| Windows release / patch | **untested** | [`DESKTOP_PLATFORMS.md`](DESKTOP_PLATFORMS.md) | No Windows engine built, no Windows host |
| Linux desktop release / patch | **untested** | [`DESKTOP_PLATFORMS.md`](DESKTOP_PLATFORMS.md) | Linux is only the CI build host for Android today (R12); no Linux desktop app released or patched |

## 2. CLI workflow

| Feature | Status | Evidence | What is missing |
|---|---|---|---|
| `release android` / `patch android` with an API key (`SHOREBIRD_TOKEN`) against the self-hosted server | **working** | CI-ANDROID | Android only; the iOS equivalent is IOS-HAND |
| `patch --release-version`, release targeting | **working** | CI-ANDROID: patch for 0.1.0+1 not offered to 0.2.0+2 | |
| Non-interactive patch refuses to guess the release (#131) | **working** | R12 arms A and B: exit 64 naming "Which release would you like to patch?", `--json` exit 0 | A Linux builder, no device; arm 1 ran with signing off; `SUPPORTED_STATE.yaml`'s `ci_noninteractive` text is stale against #131 |
| `patches rollback` (restores the previous patch, #138) | **working** | CI-ANDROID: the CLI command, three scenarios, device log shows the old patch again | Emulator, Android; iOS rollback ran "through the server API", not the CLI |
| `patches rollforward` | **unsupported** | `api.dart` answers 501 by design; [`upstream/ADOPTION-1.6.123.md`](upstream/ADOPTION-1.6.123.md) s3 | A rolled-back patch is withdrawn for good |
| Native-change guard on patch | **working** | CI-ANDROID: exit 70 "Not publishing: native code changed", nothing published | Android only |
| `patches promote` / `set-track` (release-scoped since #139) | **partial** | `set-track` calls `POST /apps/{id}/patches/promote`, which the server serves; AUG-OLD row 8, [`p6-tracks`](evidence/p6-tracks/VERDICT.md) (device A/B) | Device proof is Aug, 3.44, iOS; the #139 release-scoping has server tests but no device run; not in CI-ANDROID |
| `init`, `create`, `doctor`, browser `login` | **untested** | Routes served (`/login`, `/token`, `/diagnostics/*`, `POST /apps`) | No dedicated run recorded; CI-ANDROID authenticates with an API key |
| `login:ci` | **untested** | None | The fork's documented CI path is an API key |
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
| Percentage (staged) rollout | **partial** | Server bucketing and `POST /admin/apps/{id}/patches/{id}/rollout`; [`g6-tracks-server`](evidence/g6-tracks-server/rollout_surface.md) | Never run on a device. No CLI command, and no server route for the protocol's `SetPatchRolloutRequest`; an operator must call the admin route |
| Patched app boots with the server unreachable | **working** | CI-ANDROID scenario 8 | Emulator |
| Patch download / install events | **partial** | `__patch_download__` and `__patch_install__` seen on the phone in ANDROID-PHONE-HAND | Engine `7806e0fb`; CI-ANDROID does not assert events |
| Crash reports | **partial** | Server routes and symbolication (`/crashes`, `symbolication.dart`) | No device-sent crash report recorded |
| First-activation "launch disappearance" | **partial** | AUG-OLD: 3 occurrences on iOS | Unresolved reliability defect; not reproduced or ruled out on `2c4b0718` |

## 4. Security

| Feature | Status | Evidence | What is missing |
|---|---|---|---|
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
| `tokens list` | **unsupported** | CLI calls `api/api-keys`; no such route | `tokens create/delete` only open a console page |

## 6. Running it yourself (fork-only, but it decides whether you can replace upstream)

| Feature | Status | Evidence | What is missing |
|---|---|---|---|
| Engine and artifact mirror (replaces `download.shorebird.dev`) | **working** | CI-ANDROID pulls engine `2c4b0718` through it; R12 on a cold sealed mirror | Plain HTTP, one host (ci-build); Gradle needs `isAllowInsecureProtocol`; TLS step is the owner's |
| Backup and restore | **partial** | [`backup_restore/CERTIFICATION.md`](backup_restore/CERTIFICATION.md) | Throwaway drills, not a production restore; off-server copy of `PATCH_SIGNING_KEY_SECRET` unconfirmed (STATUS row 9) |
| Publish durability | **partial** | [`evidence/publish-durability-1.4.0/`](evidence/publish-durability-1.4.0/README.md): 447 releases, 445 patches, 0 lost | API driver only; the 2026-08 loss was never explained |
| arm64 server image | **unsupported** | [`STATUS.md`](STATUS.md) open item 10 | amd64 only |

## Biggest gaps, by impact on someone replacing upstream

1. **iOS patches cover a subset of Dart.** Route B refuses many change kinds and has only 3.44-era acceptance numbers;
   iOS is proven by hand on one iPhone 7 and not in CI. This decides whether iOS code push is usable at all.
2. **No desktop code push and no add-to-app.** macOS, Windows and Linux are untested; `aar` is untested and
   `ios-framework` is unsupported.
3. **Android on a physical phone is not shown on `main`'s pin.** CI proves Android on an emulator; the phone run is on
   `7806e0fb`. Debug and profile builds use stock engine bytes that have never run on a device.
4. **Team and account commands fail against the server**: `orgs create/update`, `members`, `service-accounts`,
   `enterprises`, `audit-log`, `usage`, `tokens list`, `apps delete`, `account update`. Anything a team needs is
   console-only today.
5. **Rollout has no CLI path.** Percentage rollout exists only as an admin route, never run on a device. Tracks, flavors,
   defines, targets and obfuscation rest on Aug 2026 runs of an older stack.
6. **Signing is opt-in and not warned about**, and the managed-key flow is untested.
7. **The mirror is single-host plain HTTP**, and engine origins must be set by the developer on a LAN.
8. **A first-activation "launch disappearance" defect** (3 iOS occurrences, Aug) is neither fixed nor re-checked.

## Not verified

- Whether `init`, `doctor`, browser login, `preview`, `flutter versions`, `--json` and the org commands that do have
  routes work end to end: no run was found.
- Whether CI-ANDROID's emulator result holds on a physical phone, or on `main` itself rather than the #142 branch.
- Anything on a real IdP, Postgres or S3.
- The "no route" rows are code reads. They were not run against a live server.
