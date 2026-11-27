# Android device run through cell 83198f59 (2026-11-26, device clock)

**Result, for SIGNED patches: on a physical OnePlus CPH2551 (Android 16, arm64 only), through cell `83198f598d638fb2b5848f64bb377f504185a3da` (engine `88a7bf8c`), a release, two patches and a rollback ran as expected. Patch 1 (`t254`: `loadGreeting` awaits `TickerFuture`) and patch 2 (the `awaits` set: p06, p07, p08, p03, p16b, p29) were each published, verified on the device ("Patch signature is valid") and launched ("Launch success for patch N"). Rolling patch 2 back made the next two boots run patch 1.**

The release and both patches were built with the CLI checkout at `6885b3fc` (#307's head; `git rev-parse HEAD` in `devrun/run-83198f59/cli`). Its `packages/shorebird_cli`, `bin/internal` and `packages/code_push_server` trees equal those of the supported `910ff250`, the merge of #307.

## What ran

- App `dev.selfhost.untab.android`, release `1.0.0+1`, `release.apk` sha256 `675bf5144a91250361105b6559be42065a88424703cde7b851f83ea9bcc968e4` (45072851 B), installed over adb. `bootstrap.log` prints `Flutter • revision b259cf5419ac79d1da59099b2ebbaa9f8f519877` and `Engine • revision 83198f598d638fb2b5848f64bb377f504185a3da`; the release and patch logs print `COHERENT platform=android engine=83198f59... | iOS Route B capability: NOT EVALUATED`.
- Signed with a fresh RSA-2048 key pair made for this run. `release_log_excerpt.txt` has `🔏 Patch Signing: your key`; only `public.pem` is kept here (sha256 `2d7ed2df981d7b7196af001ffa18571a61a7af1d42bfa19187ca6beb8a19349c`). The private key and `secrets.sh` are not copied.
- Steps are in `harness/bin/steps.sh`; their output is `steps.out`, and the per-boot logcat captures are `logcat_<step>.txt`. They are filtered to the `flutter` tag, as the `9995f957` run's are; the full captures in the run dir hold no `FATAL`, `SIGSEGV` or crash line (checked with grep before filtering).

| Step | Logcat | What it shows |
|---|---|---|
| release, 2 boots | `logcat_boot_release*.txt` | `Shorebird updater: no active patch.`, `greeting=G1`, `route=R1 /detail`, `detail=D1` |
| patch 1 download | `logcat_t254_download.txt` | `Patch signature is valid`, `Patch 1 successfully downloaded` |
| patch 1 boots | `logcat_t254_boot.txt`, `..._boot2.txt` | `Launch success for patch 1`, `greeting=G4`, `future-builder=FB1 G4`, `events=0` |
| patch 2 download | `logcat_awaits_download.txt` | boot on patch 1, then `Patch signature is valid`, `Patch 2 successfully downloaded` |
| patch 2 boots | `logcat_awaits_boot.txt`, `..._boot2.txt` | `Launch success for patch 2`, `count=10..50`, `greeting=G2`, `events=5`, `route=R1 /detail`, `detail=D1` |
| rollback of patch 2 | `rollback1.log` | `Rolled back: yes` |
| learn boot | `logcat_rb1_learn.txt` | still `Launch success for patch 2` (the app ran the rolled-back patch while it learned of the rollback), then `Patch 1 successfully downloaded` is the next patch offered |
| two boots after | `logcat_rb1_boot.txt`, `..._boot2.txt` | `Launch success for patch 1`, `greeting=G4`, `events=0` |

`steps.out` ends `STEPS_DONE`, `steps exit=0`; every boot was alive after its wait. Patch 1 is 3 platform artifacts (arm32 313.42 KB, arm64 219.60 KB, x86_64 326.19 KB), patch 2 124.13 KB, 111.71 KB and 114.80 KB (`patch_*.log`). Neither patch used `--allow-unchecked-sdk-calls`.

## Limits

- `harness/env.sh`'s first line ("2026-11-24", "CLI 2f0b38a6") is a comment carried over from the `9995f957` harness and was not updated for this run; the run used the CLI checkout at `6885b3fc` (its `git rev-parse HEAD`) on 2026-11-26. `release.out` shows the generated Gradle file's `applicationId = "dev.selfhost.untab"`, which `harness/bin/release.sh` (line 16) then rewrites and checks; the installed app and every logcat line are `dev.selfhost.untab.android`.
- Only the arm64 device was run. The arm32 and x86_64 artifacts were uploaded, not run.
- Under patch 1 the `route=R1` and `detail=D1` shape lines are absent in `logcat_t254_boot*.txt`: the harness's post-frame callback gets no frame under that patch (the same harness limit as in `android-cell-9995f957-future-then`). It is not a patch defect; under patch 2 and the release both lines are present.
- No negative signing cases were run (wrong key, tampered patch, unsigned patch). The run shows a valid signature accepted, not a bad one refused.
- One device, one app, one fresh key. The Android CLI prints no Route B check, so this run does not exercise the iOS engine changes (container rollback, already-loaded payload library); those are covered by `ios-cell-83198f59-forced-partial`.
- Logs are copied with home paths redacted to `~`; `patch_*.log` lines are cut at 600 columns, and `release_log_excerpt.txt` holds the head, the identity lines and the tail of the 517 KB `release.log` (not copied whole).
