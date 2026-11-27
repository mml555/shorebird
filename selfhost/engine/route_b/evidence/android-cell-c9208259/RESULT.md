# Android device run through cell c9208259 (2026-11-27, device clock)

**Result, for SIGNED patches: on a physical OnePlus CPH2551 (Android 16, arm64 only), through cell `c920825972cdc7e096fa114bbb616b306914c4c7` (engine `93adf4fb`, Dart `e3f6fa90`), a release, two patches and a rollback ran as expected. Patch 1 (`t254`: `loadGreeting` awaits `TickerFuture`) and patch 2 (the `awaits` set: p06, p07, p08, p03, p16b, p29) were each published, verified on the device ("Patch signature is valid") and launched ("Launch success for patch N"). Rolling patch 2 back made the next two boots run patch 1.**

The release and both patches were built with the CLI checkout at `4a3adb1d` (#313's head; `git rev-parse HEAD` in `devrun/run-c9208259/cli`, the same checkout as the iOS run).

The iOS half of this cell is in [`ios-cell-c9208259-forced-partial`](../ios-cell-c9208259-forced-partial/RESULT.md). The Android CLI prints no Route B check, so this run does not exercise the iOS engine changes of this cell (the refusal of a payload that does not load). The evidence of that problem, and of its fix, is in the iOS record and in [`../../device_run/README.md`](../../device_run/README.md). The previous Android run is [`android-cell-83198f59`](../android-cell-83198f59/RESULT.md).

## What ran

- App `dev.selfhost.untab.android`, release `1.0.0+1`, `release.apk` sha256 `18b6a816cf5eb3e9699440f29ba0f8aaf60e05da2b15be9f253a20a7bed0acf3` (45072851 B), installed over adb. `bootstrap.log` prints `Flutter • revision 246fd6f6fc70f2c4a7fb9b563eda5fcdccba2104` and `Engine • revision c920825972cdc7e096fa114bbb616b306914c4c7`; the release and patch logs print `COHERENT platform=android engine=c920825972cdc7e096fa114bbb616b306914c4c7 | iOS Route B capability: NOT EVALUATED`.
- Signed with a fresh RSA-2048 key pair made for this run. `release_log_excerpt.txt` has `🔏 Patch Signing: your key`; only `public.pem` is kept here (sha256 `f4aa45496012da89ceef37ecbf6e6bfb827610b71b215acaa4665ad03b0fc52a`). The private key and `secrets.sh` are not copied.
- Steps are in `harness/bin/steps.sh`; their output is `steps.out`, and the per-boot logcat captures are `logcat_<step>.txt`. They are filtered to the `flutter` tag, as the `83198f59` run's are. The full captures in the run dir hold no `FATAL`, `SIGSEGV` or crash line (checked with grep, case-insensitive, before filtering).

| Step | Logcat | What it shows |
|---|---|---|
| release, 2 boots | `logcat_boot_release*.txt` | `Shorebird updater: no active patch.`, `greeting=G1`, `route=R1 /detail`, `detail=D1` |
| patch 1 download | `logcat_t254_download.txt` | `Patch signature is valid`, `Patch 1 successfully downloaded` |
| patch 1 boots | `logcat_t254_boot.txt`, `..._boot2.txt` | `Launch success for patch 1`, `greeting=G4`, `events=0` |
| patch 2 download | `logcat_awaits_download.txt` | boot on patch 1 (`greeting=G4`), then `Patch signature is valid`, `Patch 2 successfully downloaded` |
| patch 2 boots | `logcat_awaits_boot.txt`, `..._boot2.txt` | `Launch success for patch 2`, `count=10..50`, `greeting=G2`, `events=5`, `route=R1 /detail`, `detail=D1` |
| rollback of patch 2 | `rollback1.log` | `Rolled back: yes` |
| learn boot | `logcat_rb1_learn.txt` | still `Launch success for patch 2` (the app ran the rolled-back patch while it learned of the rollback), then `Patch signature is valid` and `Patch 1 successfully downloaded` |
| two boots after | `logcat_rb1_boot.txt`, `..._boot2.txt` | `Launch success for patch 1`, `greeting=G4`, `events=0` |

`steps.out` ends `STEPS_DONE`, `steps exit=0`. Patch 1 is 3 platform artifacts (arm32 313.42 KB, arm64 219.60 KB, x86_64 326.19 KB), patch 2 124.13 KB, 111.71 KB and 114.80 KB (`patch_*.log`). The server's patch numbers are in `patch_numbers.txt` (`t254 1`, `awaits 2`).

## Limits

- `harness/env.sh`'s first line now names this run (cell `c9208259`, 2026-11-27, CLI `4a3adb1d`). The `83198f59` record's first line was a stale comment; that is fixed here. `release.out` shows the generated Gradle file's `applicationId = "dev.selfhost.untab"`, which `harness/bin/release.sh` then rewrites and checks; the installed app and every logcat line are `dev.selfhost.untab.android`.
- Only the arm64 device was run. The arm32 and x86_64 artifacts were uploaded, not run.
- Under patch 1 the `route=R1` and `detail=D1` shape lines are absent in `logcat_t254_boot*.txt`: the harness's post-frame callback gets no frame under that patch (the same harness limit as in `83198f59`). It is not a patch defect; under patch 2 and the release both lines are present.
- No negative signing cases were run (wrong key, tampered patch, unsigned patch). The run shows a valid signature accepted, not a bad one refused.
- One device, one app, one fresh key.
- Logs are copied with home paths redacted to `~`; `patch_*.log` lines are cut at 600 columns, and `release_log_excerpt.txt` holds the head, the identity lines and the tail of the 516 KB `release.log` (not copied whole), cut at 300 columns.
