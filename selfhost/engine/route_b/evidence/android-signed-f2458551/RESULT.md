# Android signed-patch run through cell f2458551, arm64 and armeabi-v7a (2026-11-22)

**Result: on a physical OnePlus CPH2551 (Android 16, adb `3f72a543`), through cell `f2458551039ceb1a48a2ffb4a41dff35950fec5b` (Flutter 3.50, engine `09c6f422`, updater `64a458f0`) and CLI `c212f715`, a release built with `--public-key-path` (key A) took 4 key-A patches. Each was verified on the phone (`Patch signature is valid`), applied and shown on the next launch.**

**The CLI refused an unsigned patch and an A-public/B-private patch with clear messages. It also refused a patch signed entirely with key B, but only through the asset-diff check, with a misleading message. Forced through with `--allow-asset-diffs`, that key-B patch was published, and the phone (by then the arm32 install) rejected it at the patch check, before downloading anything: `Patch signature is invalid`, then `Patch 4 is known bad, skipping` on the next two launches, staying on its previous patch. The next key-A patch applied.**

**The same APK reinstalled with only its `armeabi-v7a` libraries (`primaryCpuAbi=armeabi-v7a`) applied patches 2, 3 and 5 from their arm32 artifacts (`base_size=3342920b`, the arm32 `libapp.so`), and fell back from 3 to 2 on a rollback. All 24 launches stayed alive.** This closes "signing not exercised on a device" and "only arm64 ran on a device" for Android on this cell. x86_64 is still not run on a device.

## Limits

- **One CLI, one device, one release.** CLI `c212f715` (the unsigned run's bootstrapped worktree, reused read-only), release `1.0.0+1`, each patch built against the release.
- **The key-B patch is refused by the CLI only by accident.** The release's generated (bundled) shorebird.yaml carries key A as `patch_public_key`, so a patch built with key B changes that asset, and the asset-diff check stops it: the CLI lists `base/assets/flutter_assets/shorebird.yaml` as the changed asset, then "Not publishing: assets changed since the release" (`cli_patch_neg_keyb.txt`). Nothing names the key; the A-public/B-private patch, whose bundled key is still A, lists no changed asset. A clear check before the build is PR #279. The device-side refusal below holds either way.
- **The wrong-key rejection ran on arm32 only.** The phone had been reinstalled as `armeabi-v7a` before the forced key-B patch; the arm64 install only ever saw key-A patches. Signature checking is in the updater and does not depend on the ABI, but this run shows it on arm32.
- **Signing paths not covered:** `--sign-cmd` and `--public-key-cmd` (keys were files), a patch whose bytes were changed after signing, key rotation, and x86_64.
- **Rejected patches burn their number on the device.** Patch 4 is marked bad and is never retried, which is the intended behaviour.
- **`server_requests.txt` covers only the second session** (`go_b.sh`, the forced key-B patch and patch 5): `up.sh` restarts the server, which rewrote `logs/server.log`. The first session's server answered every request the logcat excerpts show (each patch check got a response). `artifact_origin.jsonl` and `connproxy.jsonl` cover both sessions; the CLI's caches were already warm from the unsigned run, so only 5 artifact requests were made, all to ci-build's mirror, with the fallback engine `f0a7d291` named by none. 4 of the 5 were `404`s for `aot-tools.dill`, which the Android patch does not need (`artifact_origin_summary.txt`); the patches built and applied.
- **Keys** were generated for this run with `openssl genrsa 2048`. The two public keys are here (`a_public.pem`, `b_public.pem`, SPKI DER sha256 in `key_fingerprints.txt`); the private keys stayed on the Mac.
- **No system setting was changed.** The only packages touched were our own: `dev.selfhost.untab.signed` was installed, reinstalled once with `--abi armeabi-v7a`, and is still installed. The unsigned run's app `dev.selfhost.untab.android` was not touched.

## What ran

| | |
|---|---|
| Device | OnePlus CPH2551, Android 16 (`install_info.txt`), USB, keyguard checked before every launch |
| CLI | mml555/shorebird `c212f715711d00c4b82261bc093f927d82b7cba9`, `Engine • revision f2458551...` (`up.out`) |
| Server | `code_push_server` from that checkout, local, `localhost:18290` over `adb reverse` |
| App | the shapes app of `android-cell-f2458551` (same `main.dart`, `tally.dart`, `variants.py`), applicationId `dev.selfhost.untab.signed`, label `shapes-signed-f2458551` |
| Release | `shorebird release android --artifact apk --public-key-path=a_public.pem`. APK sha256 `e07446e4...` (`install_info.txt`) |
| Scripts | `harness/` (the unsigned run's scripts plus key arguments, `neg_patch`, `abi_reinstall`; `steps.sh`, then `steps_b.sh` for the forced key-B patch) |

## Steps and verdicts

Patch numbers: `trio 1, p15 2, arm32_m2 3, neg_keyb_forced 4, p20 5`. Signature lines and refusals verbatim: `signing_verdicts.txt`.

| Step | Key | Expected | Observed |
|---|---|---|---|
| release, 2 launches | A public | no patch | `no active patch`, values `count=1..3`, `tally=K1 3` |
| trio (patch 1) | A | publish, verify, apply | `Patch signature is valid`; next launch `current_patch_number: Some(1)`, `count=10..50`, `events=5` |
| unsigned patch | none | refused | CLI exit 64: "Release 1.0.0+1 was signed with your own key, so its patches must be too." |
| key-B patch | B public + B private | refused | CLI exit 70, asset diff only: "Not publishing: assets changed since the release" (see Limits) |
| mismatched patch | A public + B private | refused | CLI exit 70: "Signature verification failed: the signature does not match the provided public key." |
| p15 (patch 2) | A | publish, verify, apply | valid; `Some(2)`, `tally=K2 3` |
| reinstall `--abi armeabi-v7a` | | arm32 libraries, downloads patch 2 | `primaryCpuAbi=armeabi-v7a`; valid; applied with `base_size=3342920b` (arm32); `Some(2)`, `tally=K2 3` |
| arm32 m2 (patch 3) | A | apply on arm32 | valid, `base_size=3342920b`; `Some(3)`, `count=4`, `home-build=H1 104` |
| rollback patch 3 | | back to patch 2 | `rb1_boot`: `Some(2)`, `tally=K2 3` |
| key-B patch forced (patch 4) | B, `--allow-asset-diffs` | phone rejects | published; phone: `Patch signature is invalid`, `Update failed: Patch signature could not be verified`; next 2 launches `Patch 4 is known bad, skipping`, stays on `Some(2)`, `const=KT1` |
| p20 (patch 5) | A | apply after a rejected patch | valid, applied on arm32; `Some(5)`, `const=KT2` |

Patches 4 and 5 are the same code (`p20_const`) and have the same hash `898763ed...`; only the signature differs. The phone refused one and applied the other.

## Files

- `signing_verdicts.txt`: each refusal and each signature line, verbatim.
- `logcat_<step>.txt`: per launch, the app's and updater's lines; `cli_patch_<step>.txt`, `cli_release.txt`, `cli_rollback1.txt`: CLI excerpts.
- `steps.out`, `steps_b.out`, `up*.out`, `go*.out`, `release.out`: the harness output.
- `artifact_origin*.{jsonl,txt}`, `connproxy.jsonl`, `server_requests.txt`, `bootstrap.log`, `install_info.txt`, `key_fingerprints.txt`, `a_public.pem`, `b_public.pem`.
- `screenshots/`: the release's first launch, and the first arm32 launch.

<!-- cspell:words SPKI keyguard keyb -->
