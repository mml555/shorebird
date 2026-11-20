# iOS device run through cell 54117a2f (2026-11-19)

**Result: every step passed with the per-release SDK kept check on, after one re-run.** The a6a48cf6 sequence was
rerun on a physical iPhone 7 (iOS 15.8.8) through the cell `54117a2fe0510a8cb070faf3f5191542179fb4ce` (coverage
analyzer 23), with main's CLI at `f66e3c21`. No patch was built with `--allow-unchecked-sdk-calls`; `lib.sh` no longer
has the retry. One step failed on that CLI, and passed when re-run on `37a0434b`, which has #257's fix:

- **e1b published a patch the device could not apply.** The CLI published e1b (an extension instance getter,
  `Stars|get#stars`, interpolating `this`) as patch 11, with one target named `stars`. On boot the runtime
  printed `ATTACH: function stars not found in package:untab/main.dart` and `target stars ... REFUSED
  (target-missing)`, applied 0/1, ran the release's code for that launch, reported a failed launch and marked patch 11
  bad. No crash, and the next launch went back to patch 10 (`e1b_boot.log`, `e1b_boot2.log`). In the a6a48cf6
  run (CLI `e7384444`) the CLI refused e1b before upload. main's analysis 22 (`5a9ae6105`, "carry instance members of
  a named extension") now publishes it. e1 (the same getter spelling the extension's static `glyph` unqualified) is
  still refused, with a new reason (below). The interpolated `glyph` in e1b is the same unqualified spelling, so the
  scope check probably also misses it inside an interpolation.
- **e1b re-run on `37a0434b` passed.** #257 stops the CLI cutting an extension getter's packed selector at its last
  `#`. With main at `37a0434b`, e1b published as patch 13 with the target `Stars|get#stars` (`compiled Stars|get#stars`,
  1630 B packed). The two boot launches applied 1/1 and printed `stars=*3*` (the e1b edit's value), and reported
  successful launches.

## Limits

- **CLI revisions.** The sequence ran on mml555/shorebird main `f66e3c21`; only the e1b re-run used `37a0434b`. The
  other published patches were not rebuilt on `37a0434b`.
- **Patches were unsigned.** CLI P7 has not landed; the release printed `No patch public
  key was provided`. Signing is not covered by this run.
- **#254 was not exercised.** The shapes app has no `AnimationController`, so no await on a `TickerFuture` ran.
- **Extension instance members** are verified on the device only from the e1b re-run on, that is, after #257.

What this run settles:

- `_HomeState._start`'s `for (final s in shapes)` over a `List<Shape>` no longer trips the check. `_start` is a
  compiled target of nine published patches (combo, trio, h1, m1, m2, i1, i2b, i2, p16), and all nine published
  checked; no patch log mentions `iterator`. The a6a48cf6 run refused 9 of its 11 patches only for that loop (`Iterable.iterator` on `ObserverList`).
- The SDK kept check refused exactly one patch, p17: `Iterable.map` and `Iterable.toList` in `_start`, which the
  release does not keep (`keep_sdk_collection_methods` is off). It raised nothing on the twelve that published. It
  prints nothing when it passes, so "asked" has no other output to show.
- #251 works: the combo with p15 and p15 alone were refused before upload, naming `package:tally/tally.dart#tallyLabel`.
  a6a48cf6 dropped that edit silently.
- i2 (`num./`) and p16 (`List.add` + `Iterable.join`), which a6a48cf6 published only under the flag, published
  checked and showed their values on the device.
- #254 (await on a TickerFuture) did not show up: no log line mentions `TickerFuture`. The shapes app has no
  `AnimationController`, so it does not exercise that path. This run is not evidence for or against #254.

## What ran

| | |
|---|---|
| CLI | mml555/shorebird main `f66e3c219cf85287f463ac5f1e12fddf1d052af5` (the merge of #255; includes #247, #248, #251, #252, #256), a fresh detached worktree at `devrun/run-54117a2f/cli`, no local changes. For the e1b re-run the same worktree was checked out at main `37a0434bcf986bf2e36549591671f9fa181b5a52` (the merge of #257) |
| Flutter | shorebird-flutter `f4024608592183cbfc27ff404e9fb23e84096f95` (branch `selfhost/3.47-cell-54117a2f`); bootstrap printed `Flutter 3.46.0-1.0.pre-866` and `Shorebird Engine • revision 54117a2fe0510a8cb070faf3f5191542179fb4ce` (`bootstrap.log`) |
| Engine | resolved from ci-build's production cdn-cache (`10.0.0.41:8085`) through `origin.py` (`artifact_origin.jsonl`): 93 requests, 85 naming `54117a2f` and none naming another cell; 49 returned 200 with `X-Overlay: hit`, the 44 404s are all `aot-tools.dill` probes |
| Descriptor | `GET download.shorebird.dev/shorebird/cell-manifests/54117a2f….v2`, 200, 4141 bytes (`up.out`) |
| Server | `code_push_server` from the same checkout, local, `10.0.0.242:18290`, sqlite/file store in `run-54117a2f/data` |
| App | the shapes app (`main.dart` + `tally.dart` + `intl`), display name `shapes-54117a2f`, app id `475e8639-2f3e-9615-47f6-60b71540ef7e`, version `1.0.0+71`, `shorebird release ios --no-codesign`, re-signed with `ios_resign.sh`, upgrade-installed over the a6a48cf6 run's `1.0.0+70` (never uninstalled; `install.txt`). The version moved to +71 so the device could not boot the a6a48cf6 release's patches against this release |
| Release | `Route B retention: 57 named SDK members kept (default set only …)` (`release_cli.txt`); no `keep_sdk_collection_methods` |

Patches were not signed: the release printed `No patch public key was provided`, which main's CLI does for a self-hosted
server without a key of your own. Signing is not covered by this run.

Outbound connections (`outbound_connect.jsonl`): pub.dev (228), github.com (6, the Flutter clone), one
release-assets.githubusercontent.com.

Scripts: `go_rerun.sh` (renames the first run's syslog, ledgers and bootstrap log to `*.run1.*`, then runs `up.sh`,
`e1b_rerun.sh`, `down.sh`) ran the e1b re-run. `go.sh` (runs `up.sh`, `release.sh`, `steps.sh`, `steps2.sh`, `steps3.sh`, `steps4.sh`, `down.sh`),
`lib.sh`, `env.sh` (sources `../secrets.sh`, not copied). `variants.py` is the a6a48cf6 file plus `combo_nop15` (the
combo without p15). Every substitution is exact-once. heavy.lock was taken around the bootstrap, the release
build and each patch build only.

## Per step

Each patch is built against the release, not on top of the previous one. The first launch after a publish downloads
(it still runs the previous patch); the next two boot it. `patch_<name>_cli.txt` keeps each build's verdict lines.
Every published patch in the table was built with the check on.

| step | patch | verdict | device (two boot launches) | evidence |
|---|---|---|---|---|
| release, two launches | – | – | no active patch; release values | `boot_release*.log` |
| combo with p15 (17 edits) | – | REFUSED, exit 70: "changes code outside the app's own package (untab) … `package:tally/tally.dart#tallyLabel`" | – | `patch_refuse_combo_p15_cli.txt` |
| combo without p15 (16 edits) | 1 (27728 B) | PASS | 15/15, 15/15: `L2`, `H2`, `c1..c3`, `I2`, `G2`, `D2`, `R2`, `15 Nov 2026`, `circle2`, `M2`, `hi2`, `FB2`, `OK 7`, `S2`, `F2`; `tally=K1 3` (the release value, as p15 is not in it) | `patch_combo_cli.txt`, `combo_boot*.log` |
| trio (p03+p16b+p29+p07) | 2 (8128 B) | PASS | 3/3, 3/3: `count=10..50`, `events=5`, `events-list=1..5` | `patch_trio_cli.txt`, `trio_boot*.log` |
| p20 (`kTitle`) | – | REFUSED, exit 70: "this constant changed" (its own reason, reached with the check on) | – | `patch_refuse_const_cli.txt` |
| p30 (field initializer) | – | REFUSED, exit 70: `_HomeState.new` "this constructor, an instance field initializer it runs … changed" | – | `patch_refuse_field_cli.txt` |
| p15 alone | – | REFUSED, exit 70: the tally package, as the combo | – | `patch_refuse_p15_cli.txt` |
| rollback 2 | – | PASS, exit 0 | `rb_learn` booted 2 (3/3) and learned the rollback; `rb_boot`, `rb_boot2` booted 1 (15/15) | `rollback_cli.txt`, `rb_*.log` |
| h1 | 3 (6315 B) | PASS | 2/2, 2/2: `h1=N1..N3` | `patch_h1_cli.txt`, `h1_boot*.log` |
| m1 | 4 (6305 B) | PASS | 2/2, 2/2: `m1=LBL1..LBL3` | `patch_m1_cli.txt`, `m1_boot*.log` |
| m2 | 5 (4962 B) | PASS | 1/1, 1/1: `bump=104` | `patch_m2_cli.txt`, `m2_boot*.log` |
| r1 (public `toJson`) | – | REFUSED, exit 70: "it uses the symbol `jsonEncode`, which the release never used" (as in a6a48cf6) | – | `patch_refuse_r1_cli.txt` |
| r2 (`Label._increment`) | – | REFUSED, exit 70: "it uses the private member `Label._increment` … which the release never used" (as in a6a48cf6) | – | `patch_refuse_r2_cli.txt` |
| rollback 5 | – | PASS, exit 0 | `rb2_learn` booted 5 (1/1) and learned it; `rb2_boot`, `rb2_boot2` booted 4 (2/2) | `rollback2_cli.txt`, `rb2_*.log` |
| s1b | 6 (1785 B) | PASS | 1/1, 1/1: `decorate=[P1:3]` -> `[[n3]]` | `patch_s1b_cli.txt`, `s1b_boot*.log` |
| s1 | 7 (1808 B) | PASS | 1/1, 1/1: `decorate=` -> `P1/[P1]/3` | `patch_s1_cli.txt`, `s1_boot*.log` |
| i1 (`int` `+`, `*`, `>`) | 8 (5998 B) | PASS | 2/2, 2/2: `arith=2:false` -> `4:true` | `patch_i1_cli.txt`, `i1_boot*.log` |
| i2b (`double` `*`, `+`) | 9 (5921 B) | PASS | 2/2, 2/2: `half=1.5` -> `1.25` | `patch_i2b_cli.txt`, `i2b_boot*.log` |
| i2 (`int / int`, then `+`) | 10 (5910 B) | PASS (a6a48cf6: only under the flag) | 2/2, 2/2: `half=1.25` | `patch_i2_cli.txt`, `i2_boot*.log` |
| e1 (extension getter, unqualified static `glyph`) | – | REFUSED, exit 70: "`Stars|get#stars` … its body spells `glyph`, which is also a static of `Stars` … Write `Stars.glyph`" (a6a48cf6: refused because a replacement did not pass the receiver) | – | `patch_e1_cli.txt` |
| e1b (the same getter, interpolating `this`) | 11 (1620 B) | **FAIL**: published; the device could not attach it | `e1b_boot`: 0/1, `target stars … REFUSED (target-missing)`, failed launch reported, patch 11 marked bad, release code ran (`stars=***`); `e1b_boot2`: back on patch 10 (2/2) | `patch_e1b_cli.txt`, `e1b_boot*.log` |
| p16 (`List.add` + `Iterable.join`) | 12 (6403 B) | PASS (a6a48cf6: only under the flag) | 2/2, 2/2: `events=3`, `events-list=e1`, `e1,e2`, `e1,e2,e3` | `patch_p16_cli.txt`, `p16_boot*.log` |
| p17 (`Iterable.map`/`toList`) | – | REFUSED by the SDK kept check, exit 70: "it calls the dart: method `Iterable.map` … `Iterable.toList` … and 57 more" | – | `patch_p17_cli.txt` |
| t1 (class type parameter) | – | REFUSED, exit 70: `Box.kind` "uses the class type parameter `T`, which is not in scope" | – | `patch_t1_cli.txt` |
| rollback 12 | – | PASS, exit 0 (see below) | `rb3_learn` booted 12 (2/2) and learned it; `rb3_boot`, `rb3_boot2` booted the base release | `rollback3_cli.txt`, `rb3_*.log` |
| e1b re-run on 37a0434b | 13 (1630 B) | PASS | `e1b_rerun_download`: base release (`stars=***`), patch 13 downloaded; `e1b_rerun_boot`, `e1b_rerun_boot2`: 1/1, 1/1, `stars=*3*`, successful launches reported | `patch_e1b_rerun_cli.txt`, `e1b_rerun_*.log`, `up_rerun.out`, `e1b_rerun.out`, `down_rerun.out` |

**The e1b re-run** brought the servers and proxies back up on the same data (`up_rerun.out`: descriptor 200, 4141
bytes; bootstrap printed engine `54117a2f` and Flutter `f4024608`, `bootstrap_e1b_rerun.log`) and published e1b against
release `1.0.0+71` with the check on. The CLI's build: `artifact_origin_e1b_rerun.jsonl`, 4 requests, all naming
`54117a2f` (the descriptor twice at 200, two `aot-tools.dill` 404s); `outbound_connect_e1b_rerun.jsonl`, pub.dev (5) and
github.com (1). Patch 13 is the server's newest patch, so the device moved off the base release that rollback 12 left
it on. heavy.lock was taken around the bootstrap and the patch build, and released by `down.sh`.

**After rolling back 12** the server's newest patch is 11, which this device had already marked bad. The device
printed `Patch 11 is known bad, skipping.` and `Prepared boot of the base release.`, and showed release values
(`label=L1`, `half=1.5`, `stars=***`). It did not go back to patch 10. That is the updater's behavior when the server's
current patch is one it refused, not a fault of the rollback. Every other device would have done the same, and it is
only reachable because e1b published.

Patch numbers per variant: `patch_numbers.txt`.

## Also seen

`shorebird release` ended with `Unable to check for updates. ProcessException: fatal: ref HEAD is not a symbolic ref`
(`release_cli.txt`): the CLI's update check fails on a detached checkout. It is harmless, but the message does not say why.
mml555/shorebird#258 makes a detached checkout skip the update check quietly.
