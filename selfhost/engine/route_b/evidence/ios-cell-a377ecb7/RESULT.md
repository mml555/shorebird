# iOS device run through cell a377ecb7 (2026-11-22)

**Result, for UNSIGNED patches (the release had no patch public key; the supported configuration signs, and signing was not exercised here): every step behaved as its script and the 54117a2f run say it should, on one CLI (`64a64473`). 12 patches were
published and each showed its values on the device; 9 patch attempts were refused before upload, each for the reason the
54117a2f run gave (the combo with p15, p15 alone, p20, p30, r1, r2, e1, p17, t1; the table has each); three rollbacks
fell back as expected. No launch failed, no patch was refused by the device, and no patch was built with
`--allow-unchecked-sdk-calls`.** The release and patch run went through the cell
`a377ecb7ae1c26172d6e9d517c42321726eec427` (Flutter 3.50, engine `e737ede3`) on a physical iPhone 7 (iPhone 7, iOS 15.8.8,
19H422; `install.txt`). The scripts do not assert app outcomes. The verdicts below come from comparing every launch's
`shape:` lines and the updater's syslog lines with what each step expects (`variants.py`, `main.dart`, `tally.dart`, the step
scripts and the 54117a2f record). Two things differ from the 54117a2f run: e1b published and passed on the first try (no re-run
needed), and the last rollback ended on patch 11 instead of the base release (below).

## Limits

- **Patches were unsigned.** The release printed `[WARN] No patch public key was provided` (`release_cli.txt`). Signing is not covered.
- **#254 was not exercised.** The shapes app has no `AnimationController`; no log line mentions `TickerFuture`.
- **One CLI, one device, one app version.** CLI `64a64473` (a detached worktree), the one iPhone 7, release `1.0.0+72`. Each patch
  is built against the release, not on top of the previous patch.
- **`stream` and the values that follow `_count`.** `lib.sh` filters the `shape:stream=` lines out of the printed output; they are
  in the `.log` excerpts. `combo_boot.log` shows `U0 U1 U2` for the async\* edit (p08); the release shows `T0 T1 T2`.
- **p29 in the trio changes nothing the `shape:` lines print.** Only the `3/3` applied-target count shows it was applied.
- **i2 and i2b are not told apart by their values.** Both give `half=1.25` at `_count` 3. What separates them is the patch
  number the updater booted (9 and 10), which `i2b_boot.log` and `i2_boot.log` show.
- **Not an Android run.** No Android device applied a patch on this cell.

## What ran

| | |
|---|---|
| CLI | mml555/shorebird `64a64473db6fd735cf348262e0d00ec80758a552` (the merge of #263; contains #257, the fix for e1b's truncated target), a fresh detached worktree at `devrun/run-a377ecb7/cli`, version `1.6.144+selfhost.1` (`bootstrap.log`) |
| Flutter | shorebird-flutter `52347b6108fa0e8b84b718e76c920e890da4c0a5` (selector, `selfhost/3.50-cell-a377ecb7`); `bootstrap.log` prints `Flutter • revision 52347b61…` and `Engine • revision a377ecb7ae1c26172d6e9d517c42321726eec427`. This run did not print the version string; the chain's bootstrap printed `3.46.0-1.0.pre-2390` for this tree (see the open item on the missing 3.50 tag in `PROMOTION_a377ecb7.md`) |
| Engine | resolved through `origin.py` to ci-build's production cdn-cache (`10.0.0.41:8085`) (`artifact_origin.jsonl`): 77 requests, all 77 naming `a377ecb7`, none naming another cell, 0 redirects; 33 returned 200 with `X-Overlay: hit` (372.8 MB), the 44 404s are all `aot-tools.dill` probes |
| Updater | `a58774ab8a88` (the DEPS updater of the selector): the device printed `Launch success for patch N: prior_ambiguous_attempts=0 (recovery event suppressed: no prior ambiguity)` (#455) and `Reporting launch paused` / `resumed` (#453) on patched launches, lines `87c198d3` does not have |
| Descriptor | `GET download.shorebird.dev/shorebird/cell-manifests/a377ecb7….v2`, 200, 4141 bytes (`up.out`) |
| Server | `code_push_server` from the same checkout, local, `10.0.0.242:18290`, sqlite/file store in `run-a377ecb7/data` |
| App | the shapes app (`main.dart` + `tally.dart` + `intl`), display name `shapes-a377ecb7`, app id `6bb3b1e7-7d48-6053-178d-148ab7dc4a0b`, version `1.0.0+72`, `shorebird release ios --no-codesign`, re-signed with `ios_resign.sh`, upgrade-installed over the 54117a2f run's `1.0.0+71` (never uninstalled; the updater printed `release_version changed 1.0.0+71 -> 1.0.0+72, creating new state`) |
| Release | `Route B retention: 57 named SDK members kept (default set only …)` (`release_cli.txt`); no `keep_sdk_collection_methods`; Route B release hash `b207a26f7fca990da4b4044161398baf` (the `built-for` of every patched boot's `ROUTEB: parsed` line) |
| Time | 01:22 to 02:14 EST, one `go.sh` run, exit 0, every step script exit 0 (`go.out`, `steps*.out`) |

The first attempt (not copied, except `attempt1_analyze.log`) stopped at `flutter analyze`: Flutter 3.50 deprecates
`package:flutter/material.dart` (an info, `deprecated_member_use`, "Use package:material_ui/material_ui.dart instead"), and
`release.sh` made infos fatal. `release.sh` now passes `--no-fatal-infos` (the app keeps the import); the app and the cell are unchanged. The run
below is the second one, from a clean `work/` and a new app id.

Scripts: `go.sh` (runs `up.sh`, `release.sh`, `steps.sh`, `steps2.sh`, `steps3.sh`, `steps4.sh`, `down.sh`), `lib.sh`, `env.sh`
(sources `../secrets.sh`, not copied). `variants.py`, `main.dart` and `tally.dart` are the 54117a2f files. Every substitution is
exact-once. heavy.lock was taken around the bootstrap, the release build and each patch build only.

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
| trio (p03 + p16b + p29 + p07) | 2 (8144 B, 3 targets) | `count=10..50`, `events=5`, `events-list=1..5` | `trio_download` ran patch 1 and downloaded 2; `trio_boot`, `trio_boot2`: 3/3, `count=10,20,30,40,50`, `events=5`, `events-list=1..5` (also `decorate=[P1:50]`, `arith=49:true`, `half=25.0`, `tally=K1 50 …`, which follow from `_count` 50) | PASS |
| p20 (`kTitle`) | – | refused: the constant changed | exit 70, `package:untab/main.dart#kTitle` "this constant changed" | PASS (refused) |
| p30 (field initializer) | – | refused: `_HomeState.new` | exit 70, "this constructor, an instance field initializer it runs … changed" | PASS (refused) |
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
| e1 (extension getter, unqualified static `glyph`) | – | refused: write `Stars.glyph` | exit 70, "`Stars\|get#stars` … its body spells `glyph`, which is also a static of `Stars` … Write `Stars.glyph`" | PASS (refused) |
| e1b (the same getter, interpolating `this`) | 11 (1630 B, 1 target `Stars\|get#stars`) | published; `stars=*3*` (`'$glyph$this$glyph'` at 3) | `e1b_download` ran 10 and downloaded 11; `e1b_boot`, `e1b_boot2`: patch 11, 1/1, `stars=*3*`, successful launches reported, no `REFUSED` / `target-missing` | PASS (the 54117a2f first run failed this step on `f66e3c21`; #257 is in `64a64473`) |
| p16 (`List.add` + `Iterable.join`) | 12 (6403 B, 2 targets) | `events=3`, `events-list=e1`, `e1,e2`, `e1,e2,e3` | `p16_download` ran 11 (`stars=*3*`) and downloaded 12; `p16_boot`, `p16_boot2`: 2/2, those values | PASS |
| p17 (`Iterable.map`/`toList`) | – | refused by the SDK kept check | exit 70, "it calls the dart: method `Iterable.map` … `Iterable.toList` … and 56 more" | PASS (refused) |
| t1 (class type parameter) | – | refused: `Box.kind` | exit 70, "its body uses the class type parameter `T`, which is not in scope" | PASS (refused) |
| rollback 12 (the newest) | – | `rb3_learn` runs 12 and learns; later launches boot 11, the newest patch that is not rolled back | rollback exit 0; `rb3_learn`: patch 12 booted 2/2, `rolled_back_patch_numbers: Some([2, 5, 12])`, patch 11 downloaded; `rb3_boot`, `rb3_boot2`: patch 11, 1/1, `stars=*3*`, `events=0`, `half=1.5` | PASS |

**`stars=*3*` in `steps4.out` is the expected value, not a fault.** Rolling back 12 leaves patch 11 (e1b) as the server's
newest, and patch 11 changes only `Stars.stars`, so the device shows e1b's `*3*` with the release's `events=0` and `half=1.5`
(patch 11 is built against the release, so it does not carry p16 or i2). In the 54117a2f run patch 11 was the one the device had
refused and marked bad, so the same rollback ended on the base release (`stars=***`). That difference is the e1b fix, not a
change in the updater.

## The server and the updater

- **No rejected reports.** `server_requests.log` has every request line of `server.log` (bodies and signed URLs dropped; elsewhere in this directory each signed URL's `sig` value is replaced with `<redacted>`, home paths with `~`, and `release.sh`'s signing identity, team and profile with placeholders): 288
  requests, no 4xx and no 5xx. `POST /api/v1/patches/check` 47 times, all 200 (the launch checks, sent by `a58774ab` with
  `host_bundle_id: dev.selfhost.untab`, #451); `POST /api/v1/patches/events` 30 times, all 204, 15 `__patch_download__` and 15
  `__patch_install__` (the 12 patches once each, plus patches 4, 1 and 11 again after the three rollbacks); 12 patch creates and 12
  promotes, all 200/204; 1 rollback request per rollback (3), 200; 22 build-run posts, 201.
- **The launch-paused/resumed and launch-success lines stay on the device.** The updater prints them (44 `Launch success …
  prior_ambiguous_attempts=0` lines) and sends no event for them; the server's events are only download and install. No recovery
  event was sent, since no launch was ambiguous.
- **Patch bytes came from the server only:** the device's downloads are `GET /download/<id>`, 200, from `10.0.0.242:18290`.
- **The outcome of each patched boot** is in the `.log` excerpts: `Prepared boot of patch N`, `ROUTEB: hook entered`, `ROUTEB: parsed,
  targets=y, built-for=b207a26f…`, `ROUTEB: running=b207a26f…` (the same hash), `ROUTEB: assert-pool-offset supplied=0xd4a8`, `applied x/y targets`,
  `Reporting successful launch`. No excerpt has `Reporting failed`, `REFUSED`, `ATTACH`, `Unhandled`, `NoSuchMethod` or `Exception`.

## Where artifacts came from

- `artifact_origin.jsonl` (the origin proxy to ci-build's overlay): 77 requests, every one naming `a377ecb7`, every one answered by
  `10.0.0.41:8085`, 0 redirects, nothing named another cell or another host. 33 were 200 with `X-Overlay: hit`; the 44 404s are all
  `aot-tools.dill`. Nothing in this log escaped to upstream.
- `outbound_connect.jsonl` (the CONNECT logger for everything else the CLI and Dart tools opened): pub.dev 54, github.com 1,
  release-assets.githubusercontent.com 1. The github.com pair is `GET https://github.com/google/bundletool/releases/download/1.18.3/bundletool-all-1.18.3.jar`
  (`release.log` line 17, read by the CLI's Dart VM at 01:22:25 as the release started; the proxy logs only the CONNECT). That is an
  Android tool the CLI fetches on first use, not an engine or Flutter artifact. The pub.dev connections are `flutter pub add intl` and the
  app's pub get. The Flutter checkout was already cached, so there is no clone traffic (54117a2f had 6 github.com connections for it).

## Also seen

- **`Unable to check for updates. ProcessException: fatal: ref HEAD is not a symbolic ref (git symbolic-ref HEAD)`** was printed at
  the end of the release (`release_cli.txt`, `release.out`) and by `shorebird --version -v` in the bootstrap (`bootstrap.log`). The CLI's update check
  runs `git symbolic-ref HEAD` in `cli/bin/cache`, and `cli/` is a detached worktree. It is harmless for the run: the release
  published and every command exited 0. The 54117a2f run had it too (its RESULT.md, "Also seen"; also a detached worktree). #258, which would
  have made a detached checkout skip the check quietly, was closed on 2026-11-20 without merging, so `64a64473` still prints it.
- **Flutter 3.50 deprecation info** (`analyze.log`, `attempt1_analyze.log`): one `deprecated_member_use` info for `package:flutter/material.dart`.
- **New in the Route B build output on 3.50:** `[route-b] P5-TARGET OPEN: release target lib/main.dart, this patch invoked with <default>. Recorded, not gated …`
  on every patch (`patch_*_cli.txt`).

## Files

`up.out`, `down.out`, `go.out`, `release.out`, `steps.out` … `steps4.out` are the scripts' own output (the `shape:` lines the verdicts
come from). `<step>_{download,boot,boot2}.log`, `rb*_{learn,boot,boot2}.log` and `boot_release*.log` are the per-launch
`Runner(Flutter)` syslog excerpts (the full syslog was 318 MB and is not kept). `patch_*_cli.txt` and `release_cli.txt` are excerpts of
the verbose build logs (the release log dumps the build environment, including the API token). `patch_numbers.txt`: combo 1, trio 2, h1 3, m1 4, m2 5, s1b 6, s1 7, i1 8,
i2b 9, i2 10, e1b 11, p16 12. The device's UDID is in `install.txt` and `env.sh`, as in the 54117a2f evidence; the device's name is removed.

The server log has 17 `/download` GETs (14 distinct patch files, three fetched twice) against 15 `Downloading patch` lines on the
device; the two extra fetches are not attributed in this record.
