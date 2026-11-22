# iOS device run through cell f2458551 (2026-11-22)

**Result, for UNSIGNED patches (the release had no patch public key; the supported configuration signs, and signing was not exercised here): every step behaved as its script and the a377ecb7 run say it should, on one CLI (`c212f715`). 12 patches were
published and each showed its values on the device; 9 patch attempts were refused before upload, each for the reason the
a377ecb7 run gave (the combo with p15, p15 alone, p20, p30, r1, r2, e1, p17, t1; the table has each); three rollbacks
fell back as expected, the last one ending on patch 11 as in the a377ecb7 run. No launch failed, no patch was refused by the device, and no patch was built with
`--allow-unchecked-sdk-calls`.** The release and patch run went through the cell
`f2458551039ceb1a48a2ffb4a41dff35950fec5b` (Flutter 3.50, engine `09c6f422`) on a physical iPhone 7 (iPhone 7, iOS 15.8.8,
19H422; `install.txt`). The scripts do not assert app outcomes. The verdicts below come from comparing every launch's
`shape:` lines and the updater's syslog lines with what each step expects and with the a377ecb7 record (`variants.py`, `main.dart`, `tally.dart`, the step
scripts and [`ios-cell-a377ecb7`](../ios-cell-a377ecb7/RESULT.md)). Every `shape:` line, patch number, patch size, target count and refusal reason is the same as in the a377ecb7 run; the differences are listed under "Differences from the a377ecb7 run".

## Limits

- **Patches were unsigned.** The release printed `[WARN] No patch public key was provided` (`release_cli.txt`). Signing is not covered.
- **#254 was not exercised.** The shapes app has no `AnimationController`; no log line mentions `TickerFuture`.
- **One CLI, one device, one app version.** CLI `c212f715` (a detached worktree), the one iPhone 7, release `1.0.0+73`. Each patch
  is built against the release, not on top of the previous patch.
- **The updater is identified by the installed binary, not by a syslog line.** See "Updater identity" below. The bounded `success_diag.log` and `state_diag.log` and their `.1` rotations (mirror #11) live in the app container on the device and were not read; nothing touched the device beyond the run.
- **`stream` and the values that follow `_count`, p29 in the trio, i2 and i2b not told apart by their values**: as in the a377ecb7 record (same files, same behaviour).
- **Not an Android run.** No Android device applied a patch on this cell.
- **Two syslog excerpts have a line missing** (below, "Differences"). Neither changes a verdict.

## What ran

| | |
|---|---|
| CLI | mml555/shorebird `c212f715711d00c4b82261bc093f927d82b7cba9` (the merge of #270), a fresh detached worktree at `devrun/run-f2458551/cli`, version `1.6.144+selfhost.1` (`bootstrap.log`) |
| Flutter | shorebird-flutter `8f54cc7bc78915802fb29fa1d7b8b88fbd2d4974` (selector, `selfhost/3.50-cell-f2458551`); `bootstrap.log` prints `Flutter • revision 8f54cc7b…` and `Engine • revision f2458551039ceb1a48a2ffb4a41dff35950fec5b`, and `up.out` prints `Flutter 3.50.1-0.0.pre-254`. **This differs from the a377ecb7 record**, which printed `3.46.0-1.0.pre-2390` because the 3.50.0 tag was not yet on the fork; the tag is there now |
| Engine | `09c6f4225d3ddf276fe4f3473beca79e038360b6` (the engine behind the cell address; `e737ede3` plus a `DEPS` bump of the updater). The CLI resolved the cell through `origin.py` to ci-build's production cdn-cache (`10.0.0.41:8085`); numbers under "Where artifacts came from" |
| Updater | `64a458f034c8` (= `a58774ab8a88` plus updater-mirror #10 and #11 via #14: #11 bounds the diag logs and classifies a refused proxy CONNECT as a transport error; `library/src/diag_log.rs`, `http.rs`, `updater.rs`, `cache/updater_state.rs`). The syslog shows the same updater lines as `a58774ab` (#455 launch-success and #453 launch paused / resumed); nothing in it separates the two. The installed binary does: `updater_identity.txt` |
| Descriptor | `GET download.shorebird.dev/shorebird/cell-manifests/f2458551….v2`, 200, 4141 bytes (`up.out`) |
| Server | `code_push_server` from the same checkout, local, `10.0.0.242:18290`, sqlite/file store in `run-f2458551/data` |
| App | the shapes app (`main.dart` + `tally.dart` + `intl`), display name `shapes-f2458551`, app id `f4a67f38-6f70-1470-d58b-65fdb1ee0068`, version `1.0.0+73`, `shorebird release ios --no-codesign`, re-signed with `ios_resign.sh`, upgrade-installed over the a377ecb7 run's `1.0.0+72` (never uninstalled; the updater printed `release_version changed 1.0.0+72 -> 1.0.0+73, creating new state`) |
| Release | `Route B retention: 57 named SDK members kept (default set only …)` (`release_cli.txt`); no `keep_sdk_collection_methods`; Route B release hash `b207a26f7fca990da4b4044161398baf` (the `built-for` of every patched boot's `ROUTEB: parsed` line; the same hash as the a377ecb7 release) |
| Time | 16:20 to 17:16 (the Mac's clock; the syslog's), one `go.sh` run, `GO_DONE`, exit 0 for `up`, `release`, `steps` to `steps4` (`go.out`, `up.out`, `release.out`, `steps*.out`) |

Unlike the a377ecb7 run there was no first attempt: `release.sh` already passed `--no-fatal-infos`, so `flutter analyze` (one `deprecated_member_use` info for `package:flutter/material.dart`, `analyze.log`) did not stop it, and there is no `attempt1_analyze.log`.

Scripts: `go.sh` (runs `up.sh`, `release.sh`, `steps.sh`, `steps2.sh`, `steps3.sh`, `steps4.sh`, `down.sh`), `lib.sh`, `env.sh`
(sources `../secrets.sh`, not copied). `variants.py`, `main.dart` and `tally.dart` are the a377ecb7 files byte for byte (and so the 54117a2f files); the scripts are the a377ecb7 scripts with `a377ecb7` replaced by `f2458551`, `52347b61…` by `8f54cc7b…` and `1.0.0+72` by `1.0.0+73`. `release.sh` has the signing identity, profile and team replaced by placeholders. heavy.lock was taken around the bootstrap, the release build and each patch build only.

## Differences from the a377ecb7 run

1. **Version string.** `Flutter 3.50.1-0.0.pre-254` (tag on the fork), not `3.46.0-1.0.pre-2390`.
2. **Updater.** `64a458f034c8` here, `a58774ab8a88` there. The installed binary shows it (`updater_identity.txt`); the syslog does not.
3. **CLI.** `c212f715` (the merge of #270), not `64a64473`; both print `1.6.144+selfhost.1`.
4. **App version and id.** `1.0.0+73`, app `f4a67f38…`, upgrade-installed over `+72`.
5. **No first attempt** (no `analyze` stop; see above).
6. **Artifact origin.** 93 requests, not 77: 85 name `f2458551`, and 8 are Flutter's own dependency downloads that a fresh Flutter checkout needs (fonts, the Gradle wrapper, the iOS USB tools), each named by its own hash and served from the same overlay. All 93 came from `10.0.0.41:8085`, 0 redirects. 49 were 200 with `X-Overlay: hit` (662.8 MB, against 372.8 MB); the 44 404s are all `aot-tools.dill`. Details under "Where artifacts came from".
7. **Network use outside the origin.** A fresh Flutter checkout was cloned (`Cloning into … 8f54cc7b…`, five `github.com` CONNECTs by `git-remote-http` from `https://github.com/mml555/shorebird-flutter.git`, at 16:20:10 to 16:20:43); the a377ecb7 run had no clone traffic. `pub.dev` 159 (was 54), `github.com` 6 (was 1), `release-assets.githubusercontent.com` 1: the bundletool jar, as before.
8. **Two syslog excerpts are missing a line.** `e1b_boot.log` (the first boot of patch 11) starts at `Reporting launch paused`; the six lines before it in the a377ecb7 excerpt (`ASSET PATH`, `Checking for active patch`, `Preparing next boot`, `Prepared boot of patch 11.`, the patch path and `active patch is a Route B container`) are not in this run's syslog. The same boot shows `ROUTEB: parsed, targets=1`, `applied 1/1 targets`, `Launch success for patch 11` and `stars=*3*`; the next launch (`e1b_boot2.log`) has `Prepared boot of patch 11.` `s1b_download.log` lacks the `Sending patch check request` line (its `Patch check response` and the whole download are there). All other launch excerpts have the same message kinds as the a377ecb7 ones.
9. **Patch sizes in the CLI's `Platform: iOS [arm64 (x KB)]` line** differ by 0.01 KB in six patches (combo 8.85 vs 8.84, h1, i1, i2b, m1, p16; e1b's CLI excerpt has no such line in either record); the packed bytes (27761, 8144, 6315, 6305, 4962, 1785, 1808, 5998, 5921, 5910, 1630, 6403) are identical.

Unchanged from the a377ecb7 run: 12 published and 9 refused with the same reasons, the three rollbacks and where each ended (patch 1, patch 4, patch 11), all 47 launch checks answered, 15 downloads and 15 installs, 44 `Launch success` lines, 288 server requests with no 4xx or 5xx, no `Reporting failed` / `REFUSED` / `ATTACH` / `Unhandled` / `NoSuchMethod` / `Exception` in any device excerpt, `Unable to check for updates … not a symbolic ref` at the end of the release (detached `cli/` worktree; #258 is closed, unmerged).

## Per step

Each patch is built against the release. The first launch after a publish downloads it (and still runs the previous good
patch); the next two boot it, unless the step says otherwise. "x/y" is the updater's `applied x/y targets` (the Route B hook's
`ROUTEB: parsed, targets=y`). `patch_<name>_cli.txt` keeps each build's verdict lines. Every published patch was built with the check on.
Values are the app's `shape:` lines that differ from the release's.

| step | patch | expected | observed | verdict |
|---|---|---|---|---|
| release, two launches | – | no active patch; the release's values; check answers `patch_available: false` | `boot_release`, `boot_release2`: `no active patch`, `Prepared boot of the base release`, `patch_available: false`; `label=L1`, `half=1.5`, `stars=***`, `tally=K1 3 \|\|\|` | PASS |
| combo with p15 (17 edits) | – | refused before upload: the tally package | exit 70, "changes code outside the app's own package (untab) … `package:tally/tally.dart#tallyLabel`", "Nothing was uploaded" (`patch_refuse_combo_p15_cli.txt`) | PASS (refused) |
| combo without p15 (16 edits) | 1 (27761 B, 15 targets) | `L2 H2 c1..c3 I2 G2 D2 R2 15 Nov 2026 circle2 M2 hi2 FB2 OK 7 S2 F2`; `tally` stays the release's `K1 3`; `U0..U2` | `combo_download`: base values, patch 1 downloaded; `combo_boot`, `combo_boot2`: 15/15, every one of those values, `tally=K1 3 \|\|\|`, `stream=U0 U1 U2`, `poly=circle2` and `square1` | PASS |
| trio (p03 + p16b + p29 + p07) | 2 (8144 B, 3 targets) | `count=10..50`, `events=5`, `events-list=1..5` | `trio_download` ran patch 1 and downloaded 2; `trio_boot`, `trio_boot2`: 3/3, `count=10,20,30,40,50`, `events=5`, `events-list=1..5` | PASS |
| p20 (`kTitle`) | – | refused: the constant changed | exit 70, `package:untab/main.dart#kTitle` "this constant changed" | PASS (refused) |
| p30 (field initializer) | – | refused: `_HomeState.new` | exit 70, `package:untab/main.dart#_HomeState.new` | PASS (refused) |
| p15 alone | – | refused: the tally package | exit 70, as the combo | PASS (refused) |
| rollback 2 | – | `rb_learn` still runs 2 and learns the rollback; later launches boot patch 1 | rollback exit 0; `rb_learn`: patch 2 booted 3/3, `rolled_back_patch_numbers: Some([2])`, patch 1 downloaded; `rb_boot`, `rb_boot2`: patch 1, 15/15, the combo's values | PASS |
| h1 | 3 (6315 B, 2 targets) | `h1=N1..N3` | `h1_download` ran patch 1 (2 is rolled back) and downloaded 3; `h1_boot`, `h1_boot2`: 2/2, `h1=N1 N2 N3` | PASS |
| m1 | 4 (6305 B, 2 targets) | `m1=LBL1..LBL3` | `m1_download` ran 3; `m1_boot`, `m1_boot2`: 2/2, `m1=LBL1 LBL2 LBL3` | PASS |
| m2 | 5 (4962 B, 1 target) | `bump=104` | `m2_download` ran 4; `m2_boot`, `m2_boot2`: 1/1, `bump=104`, `count=1..4`, `home-build=H1 104` | PASS |
| r1 (public `toJson`) | – | refused: `jsonEncode` | exit 70, "it uses the symbol `jsonEncode`, which the release never used in its own code" | PASS (refused) |
| r2 (`Label._increment`) | – | refused: private member | exit 70, "it uses the private member `Label._increment` … which the release never used" | PASS (refused) |
| rollback 5 | – | `rb2_learn` runs 5 and learns; later launches boot 4 | rollback exit 0; `rb2_learn`: patch 5 booted 1/1, `rolled_back_patch_numbers: Some([2, 5])`, patch 4 downloaded; `rb2_boot`, `rb2_boot2`: patch 4, 2/2, `m1=LBL1..3` | PASS |
| s1b | 6 (1785 B, 1 target) | `decorate=[P1:3]` -> `[[n3]]` | `s1b_download` ran 4; `s1b_boot`, `s1b_boot2`: 1/1, `decorate=[[n3]]` | PASS |
| s1 | 7 (1808 B, 1 target) | `decorate=P1/[P1]/3` | `s1_download` ran 6; `s1_boot`, `s1_boot2`: 1/1, `decorate=P1/[P1]/3` | PASS |
| i1 (`int` `+`, `*`, `>`) | 8 (5998 B, 2 targets) | `arith=2:false` -> `4:true` | `i1_download` ran 7; `i1_boot`, `i1_boot2`: 2/2, `arith=4:true` | PASS |
| i2b (`double` `*`, `+`) | 9 (5921 B, 2 targets) | `half=1.5` -> `1.25` | `i2b_download` ran 8; `i2b_boot`, `i2b_boot2`: patch 9, 2/2, `half=1.25` | PASS |
| i2 (`int / int`, then `+`) | 10 (5910 B, 2 targets) | `half=1.25` | `i2_download` ran 9; `i2_boot`, `i2_boot2`: patch 10, 2/2, `half=1.25` | PASS |
| e1 (extension getter, unqualified static `glyph`) | – | refused: write `Stars.glyph` | exit 70, `package:untab/main.dart#Stars\|get#stars` "its body spells `glyph`, which is also a static of `Stars`" | PASS (refused) |
| e1b (the same getter, interpolating `this`) | 11 (1630 B, 1 target `Stars\|get#stars`) | published; `stars=*3*` | `e1b_download` ran 10 and downloaded 11; `e1b_boot`, `e1b_boot2`: patch 11, 1/1, `stars=*3*`, successful launches reported, no `REFUSED` / `target-missing` (the first boot's excerpt lacks its first six lines; difference 8) | PASS |
| p16 (`List.add` + `Iterable.join`) | 12 (6403 B, 2 targets) | `events=3`, `events-list=e1`, `e1,e2`, `e1,e2,e3` | `p16_download` ran 11 (`stars=*3*`) and downloaded 12; `p16_boot`, `p16_boot2`: 2/2, those values | PASS |
| p17 (`Iterable.map`/`toList`) | – | refused by the SDK kept check | exit 70, "it calls the dart: method `Iterable.map` … `Iterable.toList` … and 56 more" | PASS (refused) |
| t1 (class type parameter) | – | refused: `Box.kind` | exit 70, `package:untab/main.dart#Box.kind` "its body uses the class type parameter `T`, which is not in scope" | PASS (refused) |
| rollback 12 (the newest) | – | `rb3_learn` runs 12 and learns; later launches boot 11, the newest patch that is not rolled back | rollback exit 0; `rb3_learn`: patch 12 booted 2/2, `rolled_back_patch_numbers: Some([2, 5, 12])`, patch 11 downloaded; `rb3_boot`, `rb3_boot2`: patch 11, 1/1, `stars=*3*`, `events=0`, `half=1.5` | PASS |

**`stars=*3*` at the end of `steps4.out` is the expected value, not a fault**, for the reason in the a377ecb7 record: rolling back 12 leaves patch 11 (e1b), which changes only `Stars.stars`, as the newest, so the device shows `*3*` with the release's `events=0` and `half=1.5`.

## Updater identity

The question is whether the app ran updater `64a458f034c8` and not `a58774ab8a88`. **No syslog line separates them.** Both print `Launch success for patch N: prior_ambiguous_attempts=0 (recovery event suppressed: no prior ambiguity)` (#455) and `Reporting launch paused` / `resumed` (#453); the lines this run printed (44 of each) are the lines the a377ecb7 run printed. What mirror #11 changed is two file logs (`success_diag.log` and `state_diag.log`, each bounded to 64 KiB with a `.1` rotation) and the proxy-refusal classification, neither of which prints to the syslog on a normal launch; the syslog has no `diag_log` or `state_diag` text and no proxy error.

What does separate them is the installed binary. `updater_identity.txt` shows the compiled format string of the `success_diag.log` line (`pid=… patch=… raw_boot_attempt=… prior_ambiguous_attempts=… recovery_event_decision=…`) in the app's `Flutter.framework/Flutter`: in the a377ecb7 app (updater `a58774ab`) its trailing literal is `\n`; in this app it is empty, which is the change #11 made to that `format!` in `library/src/updater.rs` (`record_launch_success`; the newline moved into `diag_log::append`). The two binaries also differ (sha256 `fb928345…` and `35e3fe03…`, same size). That ties this app to a `Flutter.framework` built with the #11 updater source. What ties it to the cell and the selector: `Shorebird Engine • revision f2458551…` and the selector `8f54cc7b` in `bootstrap.log`, the cell descriptor fetched by its address (`up.out`, `artifact_origin.jsonl`), and the 85 engine and Flutter requests that all name `f2458551`. That the engine at `f2458551` pins updater `64a458f0` in `DEPS` is the promotion record's finding (`PROMOTION_f2458551.md`), not re-derived here.

## The server and the updater

- **No rejected reports.** `server_requests.log` has every request line of `server.log` (bodies and signed URLs dropped; elsewhere in this directory each signed URL's `sig` value is replaced with `<redacted>`, home paths with `~`, and `release.sh`'s signing identity, team and profile with placeholders): 288
  requests, no 4xx and no 5xx. `POST /api/v1/patches/check` 47 times, all 200 (the launch checks, with `host_bundle_id: dev.selfhost.untab`); `POST /api/v1/patches/events` 30 times, all 204, 15 `__patch_download__` and 15
  `__patch_install__` (the 12 patches once each, plus patches 4, 1 and 11 again after the three rollbacks); 12 patch creates and 12
  promotes, all 200/204; 1 rollback request per rollback (3), 200; 22 build-run posts, 201. The same numbers as the a377ecb7 run.
- **The launch-paused/resumed and launch-success lines stay on the device.** The updater prints them (44 `Launch success …
  prior_ambiguous_attempts=0` lines) and sends no event for them. No recovery event was sent, since no launch was ambiguous.
- **Patch bytes came from the server only:** the device's downloads are `GET /download/<id>`, 200, from `10.0.0.242:18290`.
- **The outcome of each patched boot** is in the `.log` excerpts: `Prepared boot of patch N`, `ROUTEB: hook entered`, `ROUTEB: parsed,
  targets=y, built-for=b207a26f…`, `ROUTEB: running=b207a26f…` (the same hash), `ROUTEB: assert-pool-offset supplied=0xd4a8`, `applied x/y targets`,
  `Reporting successful launch`. No excerpt has `Reporting failed`, `REFUSED`, `ATTACH`, `Unhandled`, `NoSuchMethod` or `Exception`.

## Where artifacts came from

- `artifact_origin.jsonl` (the origin proxy to ci-build's overlay): 93 requests, every one answered by `10.0.0.41:8085`, 0 redirects, none to another host. 85 name `f2458551` (23 are the descriptor, fetched once by `up.sh` and once per patch build; the rest are the cell's engine, Dart and Flutter artifacts); none names another cell. The other 8 are Flutter's dependency downloads under `flutter_infra_release/` named by their own hashes (fonts `3012db47…`, gradle-wrapper `fd5c1f2c…`, and the six iOS USB tools: libimobiledevice, libusbmuxd, libplist, openssl, libimobiledeviceglue, ios-deploy); they are not engine artifacts and not another cell's. 49 were 200 with `X-Overlay: hit` (662.8 MB); the 44 404s are all `aot-tools.dill` under the `f2458551` path. Nothing in this log escaped to upstream.
- `outbound_connect.jsonl` (the CONNECT logger for everything else the CLI and Dart tools opened): `pub.dev` 159 (`flutter pub add intl`, the app's pub get, and the Flutter tool's and CLI's own `pub get`), `github.com` 6, `release-assets.githubusercontent.com` 1. Five of the `github.com` CONNECTs are the Flutter checkout's `git clone` of `https://github.com/mml555/shorebird-flutter.git` (`bootstrap.log`; the CONNECT logger records the host only); the sixth, with the release-assets one, is `GET https://github.com/google/bundletool/releases/download/1.18.3/bundletool-all-1.18.3.jar` (`release_cli.txt`), an Android tool the CLI fetches on first use. `release_cli.txt` has no other `github.com` fetch.

## Also seen

- **`Unable to check for updates. ProcessException: fatal: ref HEAD is not a symbolic ref (git symbolic-ref HEAD)`** was printed at
  the end of the release (`release_cli.txt`, `release.out`) and by `shorebird --version -v` in the bootstrap (`bootstrap.log`): `cli/` is a detached worktree. Harmless; every command exited 0. As in the a377ecb7 record, #258 was closed unmerged.
- **Flutter 3.50 deprecation info** (`analyze.log`): one `deprecated_member_use` info for `package:flutter/material.dart`.
- **`[route-b] P5-TARGET OPEN: …`** on every patch (`patch_*_cli.txt`), as in the a377ecb7 run.

## Files

`up.out`, `down.out`, `go.out`, `release.out`, `steps.out` … `steps4.out` are the scripts' own output (the `shape:` lines the verdicts
come from). `<step>_{download,boot,boot2}.log`, `rb*_{learn,boot,boot2}.log` and `boot_release*.log` are the per-launch
`Runner(Flutter)` syslog excerpts (the full syslog was 338 MB and is not kept). `patch_*_cli.txt` and `release_cli.txt` are excerpts of
the verbose build logs (the release log dumps the build environment, including the API token). `patch_numbers.txt`: combo 1, trio 2, h1 3, m1 4, m2 5, s1b 6, s1 7, i1 8,
i2b 9, i2 10, e1b 11, p16 12. `updater_identity.txt` is new in this record. The device's UDID is in `install.txt` and `env.sh`, as in the earlier evidence; the device's name is removed.

The server log has 17 `/download` GETs against 15 `Downloading patch N for app` lines on the device (each followed by a `Downloading patch from:` line; the per-patch counts are the a377ecb7 run's); the two extra fetches are not attributed in this record, as in the a377ecb7 one.
