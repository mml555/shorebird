# Behavioral findings — Shorebird updater vs. self-hosted control plane

Status legend: `device-verified` = observed on a real device/emulator against our
own `code_push_server`; `source-derived` = inferred from source only.

## Environment (device-verified run)

- Shorebird CLI **1.6.114**, Flutter **3.44.7** (engine revision `309dd6573a9fe716410489284cd325a34b950375`), Dart 3.12.2.
- Verified on BOTH: an Android **arm64-v8a** emulator (`shorebird_spike`), and a
  **physical device** (OnePlus/OPPO **CPH2551**, Android 16, arm64-v8a).
- Server: `packages/code_push_server` (Stage 0 spike). Emulator run used the host
  LAN IP `http://10.0.0.7:8080`; the physical-device run used
  `http://localhost:8080` via `adb reverse tcp:8080 tcp:8080` (USB tunnel) — both
  reachable from the CLI and the device. On the phone the updater logged
  `download_url: http://localhost:8080/...` and applied the patch successfully.
- App: `flutter create` counter app, `arch=aarch64`, `--artifact apk`,
  `--target-platform android-arm64`.

## Result: PASS (the Stage 0 go/no-go)

An unmodified Shorebird-built app installed and ran a patch served **entirely**
by our server. The release built + uploaded, the patch built + promoted, and the
device fetched/inflated/applied the patch and ran the new Dart code on the next
launch. **No `api.shorebird.dev` code-push traffic** — every updater request
targeted our `base_url`.

## Device-verified findings

### base_url embedding — `device-verified`
`shorebird init` writes `shorebird.yaml` (with `app_id`) and adds it to the
Flutter `assets`. Adding `base_url: http://10.0.0.7:8080` to that file is enough
to point the on-device Rust updater at our server — confirmed by updater logs
sending `/patches/check` and downloading from `http://10.0.0.7:8080/...`. One
`base_url` covers both device and CLI; `SHOREBIRD_HOSTED_URL` overrides the CLI.

### /patches/check — `device-verified`
The updater POSTs `PatchCheckRequest { app_id, channel, release_version,
platform, arch, client_id, current_patch_number }`. Observed values: `channel:
"stable"`, `current_patch_number: None` on a fresh install (NOT 0). It expects
`PatchCheckResponse { patch_available, patch: { number, hash, download_url,
hash_signature }, rolled_back_patch_numbers }`. Our fail-closed responses were
accepted; `rolled_back_patch_numbers: []` is fine.

### Download + apply — `device-verified`
The patch artifact is a **binary diff** against the release `libapp.so`
(patch_file 1739 B, base_size 3146640 B → decompressed 3146696 B). The updater
downloads from our `download_url`, inflates against the base it already has, and
writes `patches/1/dlc.vmcode`. **Serving back the exact uploaded bytes + echoing
the CLI-provided `hash` is what makes verification pass** — no server-side
hashing needed. `hash_signature: None` (signing off) was accepted.

### Apply-on-next-restart — `device-verified`
Sequence: launch N checks → downloads → "will be launched when the app next
restarts" (old code still runs launch N). Launch N+1: "active path:
.../patches/1/dlc.vmcode", patched code runs. Subsequent checks log "Patch 1 is
already installed, skipping."

### /patches/events shape — `device-verified` (was unknown; no Dart DTO exists)
The updater POSTs, unauthenticated, one event per state change:
```json
{ "event": { "app_id": "...", "arch": "aarch64", "client_id": "<uuid>",
  "type": "__patch_download__", "patch_number": 1, "platform": "android",
  "release_version": "1.0.0+1", "timestamp": 1784867493, "message": null } }
```
Observed `type` values so far: `__patch_download__`, `__patch_install__`
(wrapped in a top-level `"event"` object). `client_id` is a stable per-install
UUID; `timestamp` is unix seconds. A boot-success/boot-failure event was NOT
observed in this short run — capture over a longer session / failure injection.

## Stage 1 findings (persistent server, real device CPH2551)

### Patch `hash` is the INFLATED OUTPUT hash, not the uploaded bytes — `device-verified`
Critical for server-side verification. For a **release** artifact,
`hash = sha256(uploaded file)` (libapp.so / aab), so the server verifies bytes
directly. For a **patch** artifact, the CLI sets
`hash = sha256(the full reconstructed libapp.so)` (the inflation *output*) while
the **uploaded bytes are a binary diff** and `size` is the diff length
(`android_patcher.dart:221` hashes `patchArtifactPath`, uploads `createDiff(...)`).
So the server can only verify a patch's **size**; the device verifies the hash
after inflating the diff against the base it already has. A server that
sha256-checks the uploaded patch bytes will wrongly reject every patch.

### Rollback via `rolled_back_patch_numbers` — `device-verified`
Server withdrew patch 2 with rollback=true → `/patches/check` returned
`patch_available: false, rolled_back_patch_numbers: [2]`. On next launch the
updater logged "no active patch" and the app **reverted to the base code**
(screenshot confirmed baseline text returned). So listing a patch number in
`rolled_back_patch_numbers` forces installed devices to drop that patch.
Withdraw *without* rollback (number NOT in the list) simply stops offering the
patch to new checks — already-installed devices keep running it.

### Lifecycle / verification (server) — verified via smoke + device
sha256 verification of release artifacts on upload; fail-closed finalize
(release stays non-ready until every non-failed artifact is verified);
promote rejected unless the patch is `ready`; failed upload token not reusable;
SQLite persistence survives a full server restart (app/release/patch intact).

### Events — `device-verified` (persistent, idempotent)
Same shape as Stage 0 (`__patch_download__`, `__patch_install__`). Now stored
append-only in SQLite with a dedupe key
(`client_id|app_id|release_version|patch_number|type|timestamp`). A boot
success/failure event was still NOT observed by default — likely requires the
`shorebird_code_push` package or an explicit report; open for Stage 2.

### Signed patches — `device-verified`
Generated an RSA keypair (`openssl genpkey`). Built the release with
`--public-key-path` (embeds the public key), patched with BOTH
`--public-key-path` and `--private-key-path` (patch requires both, not just the
private key). The CLI signed the sha256 and sent `hash_signature` (base64 RSA
signature) on patch-artifact register; our server stored it and returned it in
`/patches/check`. The updater logged "Verifying patch signature... Patch
signature is valid" and applied the patch. So signing is fully device-side; the
server is a faithful pass-through of `hash_signature`.

### iOS on-device patch — `device-verified` (real iPhone, self-hosted server)
Completed on a physical iPhone (iPhone 16 Pro, "Mister Brody") against the
Postgres+MinIO+signed-URL stack. Because no Apple ID was signed into Xcode
(automatic signing blocked) and the on-disk profiles are Xcode-managed (can't be
used with manual signing), the working path was **build-unsigned + CLI resign**
(`tool/ios_resign.sh`): `shorebird release ios --no-codesign` → embed an existing
dev provisioning profile that already includes the device → `codesign` the
frameworks + app with the matching dev cert + dev entitlements → install via
`xcrun devicectl`. Patch built with `shorebird patch ios --no-codesign` (the
patch only diffs; the device already runs the signed app and downloads the Dart
diff at runtime). The server logged the iPhone's `/patches/check` →
`GET /download/<token>?exp&sig` → `__patch_download__` + `__patch_install__`
(both `platform: ios`), i.e. the updater fetched and applied the patch from our
server. (Screenshots aren't available: the device is network-paired, so
libimobiledevice/idevicescreenshot can't attach; verification is via the
updater's own events, the same reports that accompanied the Android screenshot.)

### iOS — historical: control-plane-only verification
`shorebird release ios --no-codesign` built the xcarchive with the Shorebird
engine and uploaded iOS release artifacts to our server: `ios/xcarchive`,
`ios/runner`, `ios/ios_supplement` (all sha256-verified). So the self-host
control plane handles iOS identically to Android (same `/api/v1` contract, same
`/patches/check`). The remaining gap for an on-device iOS *patch* run is purely
Apple **code-signing/provisioning** for the bundle id (`flutter build ipa`
fails without a development team + provisioning profile + registered device) —
orthogonal to the server. To finish: use a real signed bundle id under an Apple
Developer team, register the iPhone, then release/patch as on Android (device
reaches the host via LAN IP since `adb reverse` is Android-only).

## Stage 2 findings (Postgres + MinIO + OAuth, real device CPH2551)

### Signed download URLs work on device — `device-verified`
`download_url` is now a short-lived HMAC-signed URL (`?exp=&sig=`) the server
validates before streaming bytes from MinIO. The updater fetched and applied a
patch from such URLs (logs show `download_url: .../download/<token>?exp=..&sig=..`),
and the value rotates on each `/patches/check`. Keeping the URL pointed at our
own reachable base (rather than a MinIO presigned URL) avoids device-reachability
issues with the object store while still giving short-lived, tamper-proof links.

### `shorebird login` works against self-hosted OAuth — `device/CLI-verified`
The real CLI completed the loopback flow against our `/login` → `/token` → JWT →
`/users/me`, printing "logged in as <dev@self-host.local>". The RS256 JWT
(header `{alg,kid,typ}`, claims `iss=SHOREBIRD_JWT_ISSUER, aud, sub, iat, exp,
email`) is accepted as a bearer for the whole CLI surface — a subsequent
`shorebird release`/`patch` ran entirely on the OAuth session with no API key.

### Reused-package stale-patch caveat — operational note
Reinstalling a new release APK under the same Android package id can leave the
previous run's patch in the updater cache, so the device may show a stale patch.
`adb uninstall` (clearing app data) before installing a fresh release resolves
it. Not a server issue; relevant only to repeated local test cycles.

## Single-container SQLite backend — on-device re-verification

After the backend was refactored to the plug-and-play default (embedded SQLite +
local-disk artifacts, no Postgres/MinIO), the full Android flow was re-verified
end-to-end on a **physical device** against a `dart run` server using the SQLite
+ filesystem backend (`PUBLIC_BASE_URL=http://<LAN-IP>:8080`):

- `shorebird init` → created the app on the SQLite server; `shorebird release
  android --artifact apk` → release + artifacts stored; installed the APK.
- Device checked in (`POST /patches/check → 200`) against our server.
- `shorebird patch android` → the CLI **downloaded the release artifacts back
  from our server** to diff, uploaded the patch, created `stable`, promoted.
- Device fetched the patch over signed `/download/<token>` URLs, applied it, and
  on next launch ran the patched Dart (screen showed the patched string);
  `/patches/events` recorded download + install.
- **Withdraw + rollback** (`rollback=true`) → next launch reverted to the base
  release code; `/patches/check` returned `patch_available:false,
  rolled_back_patch_numbers:[1]`.

So the code-push runtime path is device-verified on BOTH backends — the earlier
Postgres+MinIO stack and the SQLite single-container default — with identical
behavior.

## Platform coverage (verified)

| Platform | Status | Evidence |
|---|---|---|
| Android (arm64) | device-verified | emulator + physical device; release→patch→boot→rollback→signed |
| iOS (arm64) | device-verified | physical iPhone; resign flow; `__patch_install__` |
| macOS (arm64 + x86_64) | device-verified | this Mac; `__patch_install__` (multi-arch — surfaced + fixed the `ready→uploading` bug) |
| aar (Android add-to-app) | server-verified | `shorebird release aar` on a module → arm/aarch64/x86_64 + `aar` artifacts stored/verified. No device boot (it's a library). |
| ios-framework (iOS add-to-app) | server-verified | `shorebird release ios-framework` → `xcframework` + supplement stored/verified. No device boot (library). |
| Windows / Linux | server-generic, untested | server has no platform/arch literals; must be built on those hosts (see selfhost/DESKTOP_PLATFORMS.md). |

## Still open (later)

- Boot success/failure + local-rollback events (types, timing).
- What `rolled_back_patch_numbers` (non-empty) makes the device do; behavior of
  an already-installed patch after server-side withdraw.
- Mid-download failure / HTTP range support / retry+offline queueing.
- `hash_signature` verification path when signing is enabled.
