# Android device run through cell 9995f957 (2026-11-24)

**Result, for UNSIGNED patches: on a physical OnePlus CPH2551 (Android 16, adb `3f72a543`), through cell `9995f9571ec94b60eca64ec7eaae5fa190285b4d`, every patch built was published and ran. That includes the #254 patch (`loadGreeting` awaits `TickerFuture.complete()`), which the iPhone run refused before upload, and the `await` trio that the first iPhone run refused. A rollback of patch 2 fell back to patch 1 as expected. Every boot was alive after its wait, no launch failed, and no patch was built with `--allow-unchecked-sdk-calls`.**

The hypothesis written before the run is in `harness/bin/steps.sh`: Android patches are full AOT, so the iOS kept check (the Route B `Future.then` rule of #289) does not apply, and every edit the iPhone refused should publish and run. It held. The CLI printed `COHERENT platform=android ... iOS Route B capability: NOT EVALUATED` (`release_log_excerpt.txt`), the same as in `android-cell-f2458551`.

## CLI: `2f0b38a6`, not the supported `668ce3f0`

The release and both patches were built with CLI `2f0b38a6` (the merge of #285, the pin that selected this cell), not with the supported CLI `668ce3f0` (the merge of #291). #291 changes the iOS release and patch path only (an iOS release keeps `Future.then`); an Android release and patch do not run that code, and the Android CLI prints no Route B check. So Android behaviour is the same with `668ce3f0`. This run did not use `668ce3f0`, and the claim rests on that reasoning, not on a run.

## Limits

- **Patches were unsigned.** The release printed `[WARN] No patch public key was provided` (`release_log_excerpt.txt`, line 5). Signing was not exercised.
- **A harness limit, not a patch defect: `shape:route=R1 /detail` and `shape:detail=D1` are missing under patch 1** (`logcat_t254_boot.txt`, `logcat_t254_boot2.txt`, `logcat_rb1_boot.txt`, `logcat_rb1_boot2.txt`). See the next section.
- **arm64 only was exercised on the device.** Both patches carry arm32, arm64 and x86_64 artifacts; the other two ABIs were uploaded, not run.
- **Two patches, one rollback.** Far fewer variants than `android-cell-f2458551` (9 patches, 2 rollbacks): the point here was the edits the iPhone refused.
- **One CLI, one device, one app version.** CLI `2f0b38a6`, release `1.0.0+2`, patches built against the release, not on top of each other.
- **Android only.** The iPhone runs on this cell are `ios-cell-9995f957` and `ios-cell-9995f957-future-then`.
- **Screenshots are not kept.** The status bar shows the phone owner's notification icons.
- **`steps.out`, `up.out` and `down.out` are an earlier attempt** (2026-11-23, about 21:00): the release was built and installed (`release.out`), then the run stopped because the phone's keyguard was showing for 30 minutes (`steps exit=99`), and was not bypassed. **The resume run is the one that counts:** `steps.resume.out`, 2026-11-24 about 11:45 to 11:52 local, `steps exit=0`. The per-boot logcat files and patch logs are from the resume run. The server and the origin proxy stayed up between the two, so `server.log` and `origin.jsonl` cover both.
- **Noise.** `steps.resume.out` keeps the phone's own `Oplus*` and `NoSuchMethodException` lines (system code, not the app or the updater). `release.out` and `bootstrap.log` keep `fatal: ref HEAD is not a symbolic ref` / `Unable to check for updates`: the CLI's update check failing in a detached worktree, as in the other records.
- **Redaction.** Paths under the Mac's home directory are written as `~`. The phone owner's accounts and notifications are not in any file here.

## What ran

| | |
|---|---|
| Device | OnePlus CPH2551, Android 16, adb `3f72a543`, USB, `adb reverse tcp:18290 tcp:18290` (removed in `down.sh`). The harness stops if the keyguard is showing. The only package installed was our own test app |
| CLI | mml555/shorebird `2f0b38a6990b60549152e282c73a66e8ec0ed906`, `Shorebird 1.6.144+selfhost.1`, a worktree that is shared with the iPhone run `run-9995f957` |
| Flutter and cell | shorebird-flutter `8e996caeeba7d826cc27397660a996c1e6194d07`; `bootstrap.log` prints `Engine • revision 9995f9571ec94b60eca64ec7eaae5fa190285b4d`; the descriptor was served 200, 4141 bytes (`origin.jsonl`, `up.out`) |
| Server | `code_push_server` from the same checkout, `localhost:18290`, sqlite and file store. 66 request lines in `server.log`, none 4xx or 5xx |
| App | the shapes app (`harness/shapes/main.dart`, `tally.dart`, `variants.py`), applicationId `dev.selfhost.untab.android`, app id `11f16eb5-ca0b-f54d-cf30-dd378a47c03c`, version `1.0.0+2`, cleartext allowed, INTERNET permission added |
| Release | `shorebird release android --artifact apk`, APK sha256 `7ecc800afc50a16da9ee589c7455dee74e43f95222d82eaef29afd71b64e8355`, 45,072,543 B (`release.out`), `Published Release 1.0.0+2!` |
| Artifact requests | `origin.jsonl`: the descriptor 200 and 4 `aot-tools.dill` 404s (optional), 0 redirects. `connproxy.jsonl`: 68 CONNECTs, mostly `pub.dev` (54) |

## Per step

Launch counts are distinct (pid, patch) pairs of `Launch success for patch N`, not raw line counts: patch 1 five launches (`t254_boot`, `t254_boot2`, `awaits_download`, `rb1_boot`, `rb1_boot2`), patch 2 three (`awaits_boot`, `awaits_boot2`, `rb1_learn`).

| Step | Edit | Result | On the device |
|---|---|---|---|
| `boot_release`, `boot_release2` | none | ran, `no active patch` | patch check: `patch_available: false`; 31 `shape:` lines, `greeting=G1`, `count` to 3, `events=0` |
| `t254` | `loadGreeting` awaits `TickerFuture.complete()`, returns `G4` | **published, patch 1** (arm32 313.42 KB, arm64 219.60 KB, x86_64 326.19 KB) | `t254_download` fetched patch 1; `t254_boot`, `t254_boot2`: `Launch success for patch 1`, `greeting=G4`, `future-builder=FB1 G4` |
| `awaits` | `p06_async_return` + `p07_async_loop` + `p08_async_star` + `p03_setstate_closure` + `p16b_sdk_list_add_length` + `p29_const_only` | **published, patch 2** (arm32 124.13 KB, arm64 111.71 KB, x86_64 114.80 KB) | `awaits_download` fetched patch 2; `awaits_boot`, `awaits_boot2`: patch 2, `greeting=G2`, `count` to 50, `events-list=1..5`, `events=5` |
| rollback of patch 2 | | `Rolled back: yes` (`rollback1.log`) | `rb1_learn` still on patch 2 (it learns the rollback); `rb1_boot`, `rb1_boot2` on patch 1: `greeting=G4` |

The iPhone refused `t254` before upload for the constructor `TickerFuture.complete`, and with CLI `2f0b38a6` it refused every `await` edit. Here none was refused.

## The missing `route=R1 /detail` and `detail=D1` under patch 1

Under patch 1 (`t254_boot`, `t254_boot2`, `rb1_boot`, `rb1_boot2`) the lines `shape:route=R1 /detail` and `shape:detail=D1` are missing from the 31-line set. They are present in the release boots, in the `t254_download` log's first launch and under patch 2.

Cause: the shapes app pushes `/detail` from `WidgetsBinding.instance.addPostFrameCallback` at the end of `_start()` (`harness/shapes/main.dart`, line 180). A post-frame callback does not schedule a frame; it runs after the next one. In the release, `loadGreeting()`'s 200 ms delay finishes after `_start()` reaches that point and rebuilds the `FutureBuilder`, which produces the frame. Under patch 1, `loadGreeting()` awaits `TickerFuture.complete()`, which finishes at once, so no later frame comes and the callback waits.

Check, after the steps with patch 1 active (`t254_frame_check.txt`): the app was launched and `adb logcat --pid -s flutter:I` streamed. At 11:55:19 one frame was forced by switching the phone's dark mode on and then off (restored to off), and `shape:route=R1 /detail` and `shape:detail=D1` logged at once (lines at 11:55:19.486 and 11:55:19.500, after the `START-DONE` line at 11:55:06). The server was already stopped for this check, so the updater line shows `Update failed: Network request failed`; patch 1 ran from disk (`Launch success for patch 1`).

So the patch runs and the route is pushed once a frame is drawn. This is a limit of the test app: it should call `WidgetsBinding.instance.scheduleFrame()` after registering the callback. It is not a patch defect. The harness was not changed for this run.

## Files

`steps.resume.out` (the run of record), `logcat_<step>.txt` (one per boot, filtered to lines that contain `flutter :` (the app's and the updater's output, with the `shape:` lines), plus any `AndroidRuntime`, `FATAL`, `ANR in`, `has died` or `Fatal signal` line; none of those five appeared; the phone's other system log lines are dropped), `patch_t254.log`, `patch_awaits.log` (the CLI's `-v` output), `patch_numbers.txt`, `rollback1.log`, `release.out`, `release_log_excerpt.txt`, `server.log`, `origin.jsonl`, `connproxy.jsonl`, `t254_frame_check.txt`, and `harness/` (`bin/steps.sh`, `bin/lib.sh`, the other scripts, `env.sh`, `app.env`, `shapes/`). The APK, the work tree and the server data are not kept.
