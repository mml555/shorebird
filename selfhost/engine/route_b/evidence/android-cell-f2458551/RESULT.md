# Android device run through cell f2458551 (2026-11-22)

**Result, for UNSIGNED patches (the release had no patch public key; signing was not exercised): on a physical OnePlus CPH2551 (Android 16, adb `3f72a543`), through the cell `f2458551039ceb1a48a2ffb4a41dff35950fec5b` (Flutter 3.50, engine `09c6f422`, updater `64a458f0`), a `shorebird release android` produced an APK whose `libflutter.so` carries the producer engine revision (and not the fallback's), and all 9 patches that were built were published, downloaded on one launch, and showed their new values on the next. Two rollbacks fell back on the device as expected (9 -> 8, then 8 -> 7). Nothing was refused: unlike the iOS run, which refused 9 of 21 attempts for Route B reasons, the Android CLI published every variant, including the ones iOS refused (the `tally` dependency body, a changed `const`, a field initializer, a new public method with `jsonEncode`, `Iterable.map`/`toList`, a class type parameter). All 35 launches stayed alive; no `Unhandled`, `NoSuchMethod`, `FATAL`, `Reporting failed` or `REFUSED` line is in any logcat excerpt; the server answered 277 requests, all 2xx.** This closes "no Android device applied a patch on this cell". The scripts do not assert app outcomes; the verdicts below come from comparing each launch's `shape:` lines and the updater's logcat lines with what each step expects (expectations for the variants iOS refused are stated as "published" because the Android CLI printed no refusal rule for them, see Limits).

## Limits

- **Patches were unsigned.** The release printed `[WARN] No patch public key was provided` (`cli_release.txt`). Signing is not covered here.
- **The expectation "publishes" for the refused-on-iOS variants is a hypothesis written before the run** (Android patches are ordinary bidiff patches of `libapp.so`, not Route B; `cli_patch_*.txt` show no Route B, SDK-kept or dependency check on Android, only `COHERENT platform=android ... iOS Route B capability: NOT EVALUATED`). Whether a changed `const` or a changed dependency body *should* be safe on Android is a question about the product, not answered by this run; it only observed that each applied and showed the expected value.
- **arm64 only was exercised on the device.** The release and every patch carry arm32, arm64 and x86_64 artifacts (the device is arm64; `base_size=3015640b` in the updater line is the arm64 `libapp.so`). The other two ABIs were built and uploaded but not run.
- **One CLI, one device, one app version.** CLI `c212f715` (a fresh detached worktree `cli/`), release `1.0.0+1`, patches each built against the release, not on top of the previous patch.
- **#254 was not exercised** (no `AnimationController` in the shapes app).
- **The first run attempt failed for two environmental reasons and was redone** (below). `artifact_origin.jsonl`, `connproxy.jsonl` and `server_requests.txt` cover both attempts, because the origin proxy and the server stayed up between them; the attempt-1 app (id `5b99ce6e`, release 1) is in the same server database but no patch was ever published for it.
- **`stream` is logged as `shape:stream=` per tick and is excluded from the per-launch value diff** (as in the iOS run); the combo's `U0 U1 U2` was read from the raw excerpt.
- **Android's own pre-existing log noise** (`Oplus*`, `avc: granted`, `NoSuchMethodException` from OPlus heap code) is in the raw logcat and was filtered out of the excerpts; none of it comes from the app or the updater.

## What ran

| | |
|---|---|
| Device | OnePlus CPH2551, Android 16, adb `3f72a543`, USB; screen awake and `isKeyguardShowing=false` before every launch (the harness stops the run if it is ever true; it never was). `stay_on_while_plugged_in` was already 15 (the owner's), `bmgr enabled` true; **no system setting was changed** (nothing to revert). The only package installed or removed was our own test app |
| CLI | mml555/shorebird `c212f715711d00c4b82261bc093f927d82b7cba9` (merge of #270), fresh detached worktree at `devrun/run-f2458551-android/cli`, bootstrap in `bootstrap.log` |
| Flutter | selector `8f54cc7bc78915802fb29fa1d7b8b88fbd2d4974`, `Flutter 3.50.1-0.0.pre-254`, `Shorebird Engine - revision f2458551...` (`up.out`) |
| Engine | `09c6f4225d3ddf276fe4f3473beca79e038360b6` behind cell `f2458551...`; fallback `f0a7d291...`. The release printed `COHERENT platform=android engine=f2458551... | iOS Route B capability: NOT EVALUATED` (`cli_release.txt`) |
| Updater | `64a458f034c8` (in the cell's engine; the logcat shows `updater::updater`, `Launch success for patch N: prior_ambiguous_attempts=0`) |
| Server | `code_push_server` from the same checkout, local, `localhost:18290`, reached from the phone with `adb reverse tcp:18290 tcp:18290` (removed in `down.sh`); sqlite/file store in `data/` |
| App | the shapes app, byte-identical `main.dart`, `tally.dart`, `variants.py` to the iOS run (checked with a digest), display name `shapes-android-f2458551`, **applicationId `dev.selfhost.untab.android`** (`pm list packages` showed no `untab`/`selfhost` package beforehand), app id `cdfacedc-f9ab-a45c-e54f-2af76b3c6d2d`, version `1.0.0+1`; manifest edited with `usesCleartextTraffic="true"` and `allowBackup="false"`; INTERNET permission added by `shorebird doctor --fix` |
| Release | `shorebird release android --artifact apk --no-confirm -v` (all three ABIs). APK sha256 `915ad5fb0dc9b81b171660abcacde4133c8a134eec607def3918b6a94eb3f4e1`, 45,072,543 B (`install_info.txt`). Recorded release artifacts (`release_artifacts_app2.txt`): arm 3,342,920 `27ee447f...`, aarch64 3,015,640 `2a384330...`, x86_64 3,146,712 `b4cbda8f...`, aab 46,764,676, supplement 435. The three `libapp.so` hashes in the APK equal the recorded artifacts' hashes (3 of 3) |
| Time | 17:39 to 18:05 (the Mac's clock): attempt 1 17:39-17:44, attempt 2 `release.sh` 17:44-17:45, steps 17:45-18:05, one `steps.sh` run ending `GO_DONE`; `release exit=0`, `steps exit=0` |

Scripts (`harness/`): `bin/up.sh`, `release.sh`, `lib.sh`, `steps.sh`, `down.sh`, `collect.sh`, `origin.py`, `connproxy.py`, `env.sh` (sources `../secrets.sh`, not copied). They are the iOS run's scripts with the device layer replaced: `adb` install / `monkey` launch / `am force-stop`, `logcat -d --pid=<pid of the test app>` instead of idevicesyslog, `pull`ed screenshots (not `exec-out screencap`, per android-final-stack-2), a keyguard check before each launch, and one `try_patch` step that publishes-or-records instead of expecting a refusal. heavy.lock was taken around bootstrap, the release build and each of the 9 patch builds, and was gone afterwards.

## What differed from the iOS run

1. **Nothing was refused.** 9 patch builds, 9 publishes (iOS: 12 published, 9 refused). The variants iOS refused all published here and all showed their values: the combo including `p15` (tally body), `p15` alone, `p20` (`kTitle`), `p30` (field initializer), `r1` (public `toJson` + `jsonEncode`), `p17` (`Iterable.map`/`toList`), `t1` (class type parameter).
2. **A changed constant and a changed dependency body take effect** (`const=KT2`, `tally=K2 3 |||`). On iOS Route B these were the refusals.
3. **Patch sizes are ordinary bidiff sizes**, 0.3 KB to 333 KB for arm64 (`patch_artifacts.txt`), several far larger than iOS's Route B containers (the `r1` and `p17` edits shift the snapshot layout: 341 KB and 295 KB against 3.0 MB). The updater applied each with `output_written` equal to the release's arm64 size (3,015,640 B).
4. **`aot-tools.dill` is requested and 404s** (28 times across both attempts), the CLI prints `optional artifact: "aot-tools.dill" was not found, skipping...` and carries on, as in android-final-stack-2.
5. **Only the first launch of a patch downloads; there is no `ROUTEB: parsed` or `applied x/y targets` line on Android.** The proof a patch ran is `Launch success for patch N` plus the changed `shape:` values.
6. **`shorebird doctor --fix` talks to upstream** (see "Where artifacts came from").

## Two environmental failures in attempt 1, fixed and re-run

(`attempt1_failures.txt`; the first logs are kept in `logs.attempt1/`, the first screenshots in `shots.attempt1/`.)

- **Cleartext.** The first release launched but its updater printed `Update failed: Network request failed` with `java.io.IOException: Cleartext HTTP traffic to localhost not permitted`. The server was `http://localhost:18290` over `adb reverse`. The release was rebuilt with `android:usesCleartextTraffic="true"` (and `allowBackup="false"` so a reinstall of the same package id cannot restore updater state, the android-final-stack-2 incident), the test app was uninstalled (our own app only) and reinstalled. A different, fresh app record was used for attempt 2.
- **Wrong patch flag.** My `lib.sh` passed `--artifact apk` to `shorebird patch android`; the CLI exits 64 ("Could not find an option named --artifact") before any build. Every variant failed that way in the 17:42 run, with no effect on the server. The flag was removed (`patch android --release-version 1.0.0+1`, which uses the release's artifacts) and the steps re-run from the start.

Neither affects a verdict below; both were harness errors, not product behavior. (The first `steps.sh` was started as the tail of `go.sh` before the APK had been installed, and was stopped and restarted after the install; no patch was published in between.)

## Where artifacts came from

`artifact_origin.jsonl` (73 requests, both attempts; `artifact_origin_summary.txt`): all 73 answered by `10.0.0.41:8085`, 0 redirects, 43 `200` with `X-Overlay: hit` (1.17 GB), 28 `404`, 2 `400`.

- Every request under `/flutter_infra_release/flutter/<engine hash>/` (23, the Android engine, profile and release artifact sets and `darwin-x64` gen_snapshot zips) names `f2458551039c...`; **no request names the fallback `f0a7d291`** and none names another engine revision. 34 responses carry `X-Engine-Hash: f2458551...`.
- All 28 404s are the optional `aot-tools.dill`, and the two 400s are `/` probes; no required artifact was missing.
- 8 requests name no engine hash: Flutter's own dependency downloads for a fresh checkout (`fonts.zip`, `gradle-wrapper.tgz`, and the iOS USB tools that `flutter precache` always fetches), each served by the same overlay.
- **Outside the origin** (`connproxy.jsonl`): `pub.dev` 211, `dl.google.com` 50 (Android SDK components), `repo.maven.apache.org` 36, `plugins.gradle.org` 11, `plugins-artifacts.gradle.org` 3, `services.gradle.org` 1, `github.com` 7 (the fresh Flutter clone and the bundletool jar) and `release-assets.githubusercontent.com` 2. **Also `console.shorebird.dev`, `auth.shorebird.dev` and `cdn.shorebird.cloud` 2 each**, at 17:39:07 and 17:44:35: these are the two `shorebird doctor --fix` runs (the CLI's network checker, `network_checker.dart`), reachability probes made by the `dartvm` process that carry no artifact; they are the only connections to Shorebird's own hosts, and the iOS run had none because it does not run `doctor`. No engine, Flutter or updater artifact came from upstream.

## The shipped engine

`engine_revision_check.txt` (final APK): the stripped `libflutter.so` in each ABI contains the producer revision `09c6f4225d3d...` once and the fallback `f0a7d291...` zero times (arm64-v8a 12,345,064 B, armeabi-v7a 9,143,464 B, x86_64 13,602,336 B). Same discriminator as android-final-stack-2 (AGP strips the symbols, so byte identity with the cell jar cannot hold). The negative side was not separately proven against the fallback engine's own jar here; it is one string absent, not a control with a known positive.

## Per step

Each patch is built against the release. A "download" launch runs the previous good patch (or the release) and downloads the new one; the next two launches boot it. Values are the `shape:` lines that differ from the release's (`boot_release`); `logcat_<name>.txt` has each launch, `cli_patch_<name>.txt` each build's verdict lines.

| step | patch | expected | observed | verdict |
|---|---|---|---|---|
| install, two launches | - | no active patch; the release's values; check answers `patch_available: false` | `boot_release`, `boot_release2`: `Shorebird updater: no active patch`, `No usable state file ... creating new state` (first), `Patch check response: ... patch_available: false, rolled_back_patch_numbers: Some([])`, `label=L1 half=1.5 stars=*** tally=K1 3 |||`, `stream=T0 T1 T2` | PASS |
| combo incl. `p15` (17 edits) | 1 (arm64 49,724 B; CLI `arm32 65.50 / arm64 48.56 / x86_64 60.68 KB`) | publishes (iOS refused it); next boots show `L2 H2 c1..c3 I2 G2 D2 R2 15 Nov 2026 circle2 M2 hi2 FB2 OK 7 S2 F2`, `tally=K2 3`, `U0..U2` | `combo_p15_download`: release values, `Downloading patch 1`, `Patch 1 successfully downloaded`, `Patch successfully applied ... output_written=3015640b`, `Update installed`; `combo_p15_boot`, `_boot2`: `current_patch_number: Some(1)`, `Launch success for patch 1`, every one of those values incl. `detail=D2`, `route=R2 /detail`, `init=I2`, `label=L2`, `stream=U0 U1 U2`, `tally=K2 3 |||`; `const=KT1` unchanged (not in the combo) | PASS (published, not refused as on iOS) |
| trio (p03 + p16b + p29 + p07) | 2 (114,627 B) | `count=10..50`, `events=5`, `events-list=1..5` | `trio_download` ran patch 1, downloaded 2; boots: `Some(2)`, `count=10,20,30,40,50`, `events=5`, `events-list=1,2,3,4,5`, `home-build=H1 0..H1 50`, `tally=K1 50 ||||...` (the loop count follows `_count`), `half=25.0`, `arith=49:true` | PASS |
| p15 alone (tally body) | 3 (7,064 B) | publishes (iOS refused); `tally=K2 3 |||` | `p15_download` ran 2, downloaded 3; boots: `Some(3)`, `tally=K2 3 |||`, nothing else changed | PASS (published) |
| m2 (new private method calls and writes) | 4 (81,411 B) | `bump=104` | `m2_download` ran 3; boots: `Some(4)`, `bump=104`, `count=1,2,3,4`, `home-build=H1 104` | PASS |
| p20 (`kTitle` const) | 5 (5,603 B) | publishes (iOS refused: "this constant changed"); `const=KT2` | `const_download` ran 4; boots: `Some(5)`, `const=KT2` | PASS (published) |
| p30 (field initializer) | 6 (61,920 B) | publishes (iOS refused: `_HomeState.new`); `events=1` | `field_download` ran 5; boots: `Some(6)`, `events=1` | PASS (published) |
| r1 (public `toJson`, `jsonEncode`) | 7 (341,374 B) | publishes (iOS refused); `json={"count":3}` | `r1_download` ran 6; boots: `Some(7)`, `json={"count":3}` | PASS (published) |
| p17 (`Iterable.map`/`toList`) | 8 (295,104 B) | publishes (iOS refused by the SDK kept check); `words=[A, C]` | `p17_download` ran 7; boots: `Some(8)`, `words=[A, C]` | PASS (published) |
| t1 (class type parameter, `Box.kind`) | 9 (536 B) | publishes (iOS refused); `box=T2` | `t1_download` ran 8; boots: `Some(9)`, `box=T2` | PASS (published) |
| rollback 9 (the newest) | - | `rb1_learn` runs 9 and learns; later launches boot 8 | rollback exit 0 ("Patch 9 ... has been rolled back"); `rb1_learn`: `Launch success for patch 9`, `rolled_back_patch_numbers: Some([9])`, patch 8 downloaded and installed; `rb1_boot`, `rb1_boot2`: `Some(8)`, `words=[A, C]`, `box=T1` back | PASS |
| rollback 8 | - | `rb2_learn` runs 8 and learns; later launches boot 7 | rollback exit 0; `rb2_learn`: `Launch success for patch 8`, `rolled_back_patch_numbers: Some([8, 9])`, patch 7 downloaded; `rb2_boot`, `rb2_boot2`: `Some(7)`, `json={"count":3}`, `words` gone | PASS |

Goal-area coverage: widget rebuild and value change (combo `p01`/`p02`/`p23`: `label`, `home-build`, `future-builder`); state (trio `p03`/`p16b`: `count`, `events`; `p25`-style field change via `p30`, `m2`); async (`p06` async return `greeting=G2`, `p08` `async*` `stream=U0..U2`, `p07` loop `count` to 50); routing (`p09` page build `detail=D2`, `p10` route table `route=R2 /detail`); pure-Dart dependency `tally` (`p15`: `tally=K2`); `intl` (`p13`: `stamp=15 Nov 2026`).

Totals over the 35 launches: 11 downloads and 11 installs (9 patches + 2 rollback fallbacks), 32 `Launch success for patch N` lines (the 3 other launches ran the base release), 0 launches dead after the wait (`logs/*.pid`), 35 logcat excerpts, 10 screenshots (`screenshots/`, pulled as files and all valid PNGs; corroboration only, the assertions are on logcat).

## Server

`server_requests.txt`: **277 requests, all 2xx** (`200`, `201`, `204`; no 4xx, no 5xx), covering both attempts: 35 `POST /api/v1/patches/check`, 22 `POST /api/v1/patches/events`, 11 `POST /api/v1/apps/<id>/runs`, 9 patches created (`POST .../patches`, 27 artifact uploads), 9 promoted, 2 rollbacks, 2 releases (attempt 1 and 2), about 50 signed `/download/...` and `/api/v1/uploads/...` calls. `patch_artifacts.txt`: all 27 patch artifacts `verified`.

## Device state left behind

Our test app `dev.selfhost.untab.android` is still installed (running patch 7, after the last rollback). No other package, setting or file on the phone was touched except two `/sdcard` screenshot temp files, deleted after each pull. The local server, origin proxy and connect proxy were stopped by `down.sh` (no listeners on 18185, 18188, 18290), the `adb reverse` rule was removed, and `heavy.lock` is gone.

## Evidence files

`evidence/`: `logcat_<launch>.txt` (35), `cli_patch_<name>.txt` (9), `cli_release.txt`, `cli_rollback1.txt`, `cli_rollback2.txt`, `artifact_origin.jsonl`, `artifact_origin_summary.txt`, `connproxy.jsonl`, `server_requests.txt`, `release_artifacts_app2.txt`, `patch_artifacts.txt`, `engine_revision_check.txt`, `install_info.txt`, `attempt1_failures.txt`, `bootstrap.log`, `up.out`, `release.out`, `steps.out`, `screenshots/`, `harness/`. Home paths are `~`, signed-URL `sig` values and bearer tokens are redacted. Raw, unredacted logs are in `logs/` and `logs.attempt1/`.
