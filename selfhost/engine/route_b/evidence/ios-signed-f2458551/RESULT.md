# iOS signed-patch run through cell f2458551 (2026-11-22)

**Result: on the iPhone 7 (iOS 15.8.8), through cell `f2458551039ceb1a48a2ffb4a41dff35950fec5b` (Flutter 3.50, engine `09c6f422`, updater `64a458f0`) and CLI `c212f715`, a release built with `--public-key-path` (key A; `release_cli.txt`: `Patch Signing: your key`) took 3 key-A Route B patches. Each was verified on the phone (`Patch signature is valid`), applied (3/3 or 15/15 targets) and showed its values on the next launch. A rollback fell back to the earlier patch, which verified again.**

**The CLI refused an unsigned patch (exit 64) and an A-public/B-private patch (exit 70) with clear messages. It refused a patch signed entirely with key B (exit 70) only through the asset-diff check, which names the bundled `shorebird.yaml` and not the key. Forced through with `--allow-asset-diffs`, that key-B patch was published, and the phone rejected it at the patch check, before downloading anything: `Patch signature is invalid`, `Update failed: Patch signature could not be verified`. The next two launches logged `Patch 3 is known bad, skipping` and stayed on patch 1. The same code signed with key A (patch 4, the same hash as patch 3) then applied, 15/15 targets.**

**No launch failed (18 launches), and no patch was built with `--allow-unchecked-sdk-calls`.** This closes "signing not exercised on a device" for iOS on this cell. It matches the Android signed run, [`android-signed-f2458551`](../android-signed-f2458551/RESULT.md).

## Limits

- **One CLI, one device, one release.** CLI `c212f715` (the unsigned run's worktree at `devrun/run-f2458551/cli`, reused read-only), release `1.0.0+74` upgrade-installed over the unsigned run's `+73` (same bundle `dev.selfhost.untab`). Each patch is built against the release.
- **The CLI's refusal of the key-B patch is a side effect.** A key-B patch bundles key B's public key in its generated (bundled) shorebird.yaml, and the release bundled key A. So the CLI lists `Products/Applications/Runner.app/Frameworks/App.framework/flutter_assets/shorebird.yaml` as a changed asset and stops ("Not publishing: assets changed since the release"; `signing_verdicts.txt`). Nothing names the key. PR #279 adds a direct key check. The phone's refusal below holds either way.
- **Signing paths not covered:** `--sign-cmd` and `--public-key-cmd` (the keys were files), a patch whose bytes changed after signing, and key rotation.
- **Only the trio and combo variants.** This run covers signing, not Route B coverage. The variants are the unsigned run's (`../ios-cell-f2458551/variants.py`, `main.dart`, `tally.dart`, byte-identical), and their values match that run's trio and combo steps.
- **Two server sessions.** `go_b.sh` restarted the server for the forced key-B step. The first session's log was copied before that, so `server_requests.log` covers both: 74 + 31 requests, all 2xx.
- **Artifacts.** The CLI's caches were warm from the unsigned run, so it made only 7 artifact requests (`artifact_origin.jsonl`), all to ci-build's cdn-cache `10.0.0.41:8085`, none naming the fallback engine. 3 were the cell manifest (200). 4 were `aot-tools.dill` (404), which the iOS Route B patch does not use; every patch built. `outbound_connect.jsonl` has 54 CONNECTs, all to `pub.dev`.
- **Keys** were generated with `openssl genrsa 2048` for the Android signed run and reused here: the same two key pairs, so the fingerprints in `key_fingerprints.txt` match that run's. Only the public keys are here.
- **Device left as found, plus our app.** Nothing was uninstalled. The app was upgrade-installed, which keeps its Local Network permission, and is still on patch 4.

## What ran

| | |
|---|---|
| Device | iPhone 7, iOS 15.8.8 (19H422), USB (`install.txt`, device name redacted) |
| CLI | mml555/shorebird `c212f715711d00c4b82261bc093f927d82b7cba9`, `Engine • revision f2458551...` (`up.out`), engine identity `COHERENT ... VERIFIED against the published cell` (`release_cli.txt`) |
| Server | `code_push_server` from that checkout, on the Mac at `10.0.0.242:18290` |
| App | the shapes app of `ios-cell-f2458551`, display name `shapes-signed-f2458551` |
| Release | `shorebird release ios --no-codesign --public-key-path=a_public.pem`, then re-signed and installed (`release.out`, `install.txt`). `verified 7156 patchable call sites` |
| Scripts | `harness/` (`steps.sh`, then `go_b.sh`/`steps_b.sh` for the forced key-B patch; `collect.sh` built this folder) |

## Steps and verdicts

Patch numbers (`patch_numbers.txt`): `trio 1, combo 2, neg_keyb_forced 3, combo2 4`. Signature lines and refusals verbatim: `signing_verdicts.txt`.

| Step | Key | Expected | Observed |
|---|---|---|---|
| release, 2 launches | A public | no patch | `no active patch`; `count=1..3`, `home-build=H1`, `detail=D1` |
| trio (patch 1, 3.73 KB) | A | publish, verify, apply | `trio_download`: `Patch signature is valid`; `trio_boot`, `trio_boot2`: `applied 3/3 targets`, `Some(1)`, `count=10..50`, `events=5`, `arith=49:true` |
| unsigned patch | none | refused | CLI exit 64: "Release 1.0.0+74 was signed with your own key, so its patches must be too." |
| key-B patch | B public + B private | refused | CLI exit 70, asset diff only (see Limits) |
| mismatched patch | A public + B private | refused | CLI exit 70: "Signature verification failed: the signature does not match the provided public key." |
| combo (patch 2, 8.86 KB) | A | publish, verify, apply | valid; `combo_boot`, `combo_boot2`: `applied 15/15 targets`, `Some(2)`, `home-build=H2`, `detail=D2`, `greeting=G2` |
| rollback patch 2 | | back to patch 1 | `rb_learn` still on 2 and re-verifies patch 1 (valid); `rb_boot`, `rb_boot2`: `applied 3/3 targets`, `Some(1)`, trio values |
| key-B patch forced (patch 3) | B, `--allow-asset-diffs` | phone rejects | published (`[WARN] Your app contains asset changes`); phone: `Patch signature is invalid`, `Update failed: Patch signature could not be verified`; the next 2 launches log `Patch 3 is known bad, skipping` and stay on `Some(1)` |
| combo2 (patch 4) | A | apply after a rejected patch | valid; `combo2_boot`, `combo2_boot2`: `applied 15/15 targets`, `Some(4)`, combo values |

Patches 2, 3 and 4 are the same code (`combo_nop15`), with the same hash `d6583d05...` and the same 27866-byte Route B payload. Only the signature differs: the phone applied 2 and 4 and refused 3.

## Files

- `signing_verdicts.txt`: every signature line from the launches, and each refusal, verbatim.
- `<step>.log`: per launch, the app's syslog lines. `patch_<step>_cli.txt`, `release_cli.txt`, `rollback_cli.txt`: CLI excerpts with their original line numbers.
- `steps.out`, `steps_b.out`, `go*.out`, `up*.out`, `down*.out`, `release.out`: the harness output.
- `artifact_origin.jsonl`, `outbound_connect.jsonl`, `server_requests.log`, `bootstrap.log`, `analyze.log`, `install.txt`, `patch_numbers.txt`, `key_fingerprints.txt`, `a_public.pem`, `b_public.pem`.
- `screenshots/`: the last frame of the trio, combo and combo2 first launches.

<!-- cspell:words SPKI keyb genrsa -->
