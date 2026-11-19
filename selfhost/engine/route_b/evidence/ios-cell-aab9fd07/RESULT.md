# iOS device run through cell aab9fd07 (2026-11-16)

**Result: PASS.** On a physical iPhone 7 (iOS 15.8), with the toolchain found through the cell address
`aab9fd07857142c232e4b5a41e41814b8dbf640f`, one release of a small Flutter app was patched with ordinary
edits:

- Patch 1 carried 18 edits and applied 16 of 16 targets on two launches.
- Patch 2 carried 4 edits and applied 3 of 3 on two launches.
- Two edits that a patch cannot carry were refused before anything was uploaded.
- Rolling back patch 2 returned the device to patch 1.

This is the same set of edits as the local-cell run of 2026-11-15
([`ios_shapes_2026_11_15`](../ios_shapes_2026_11_15/RESULT.md)). This time it went through a published
cell and the CLI on main, with nothing local.

## What ran

| | |
|---|---|
| CLI | mml555/shorebird `a443d87c` (PR #190's head; merged as `dd93e875` with the same CLI trees) |
| Flutter | mml555/shorebird-flutter `7def8a99` (`lineage.flutter_selector`). The bootstrap reported `Flutter 3.46.0-1.0.pre-866` and `Shorebird Engine • revision aab9fd07…` |
| Engine | resolved to `aab9fd07` from the production cdn-cache on ci-build. `artifact_origin.jsonl` has 41 requests: 33 under `…/aab9fd07…`, and 8 for fonts, the Gradle wrapper and the iOS USB tools. All 31 that returned 200 came from the overlay |
| Descriptor | `GET download.shorebird.dev/shorebird/cell-manifests/aab9fd07….v2` → 200, 4141 bytes |
| Server | `code_push_server` from the same CLI checkout, on the LAN |
| App | `flutter create` app with the local pure-Dart package `tally` and `package:intl` (`shapes_main.dart`, `tally.dart`, built by `release.sh`). Version `1.0.0+32`, released with `shorebird release ios --no-codesign`, re-signed with `ios_resign.sh`, installed as an upgrade over the previous build of the same bundle id |

The CLI added `--route_b_untabled_overrides` to the release build by itself (`release_cli.txt`). Nothing
on the command line asked for it.

The only 404s were the ten `aot-tools.dill` probes, which fall back to the executable by design.

Each patch is built by `variants.py`, which makes one exact substitution per edit and stops if a
substitution does not match exactly once. `steps.sh` drove the release launches, the four patch commands
and the patch launches.

## Patch 1: 18 edits, 16 targets (`combo_boot.log`, `combo_boot2.log`)

`ROUTEB: applied 16/16 targets, entering main` on both launches after the download (9438 bytes). The 18
edits land on 16 targets because p17 and p27 both edit `_HomeState._start`, and p23 is inside the
`_HomeState.build` that p02 edits. "Before" is the release (`boot_release.log`, `boot_release2.log`).

| edit | shape | before | after |
|---|---|---|---|
| p01 | `StatelessWidget.build` | `label=L1` | `label=L2` |
| p02 | `State.build` | `home-build=H1 n` | `home-build=H2 n` |
| p04 | a method that calls `setState` (`_increment`, its log line) | `count=1..3` | `count=c1..c3` |
| p05 | `initState`, which calls `super.initState()` | `init=I1` | `init=I2` |
| p06 | `async` function return | `greeting=G1` | `greeting=G2` |
| p08 | `async*` generator | `stream=T0..T2` | `stream=U0..U2` |
| p09 | a pushed route's page `build` | `detail=D1` | `detail=D2` |
| p10 | the `onGenerateRoute` callback (`routeFor`) | `route=R1 /detail` | `route=R2 /detail` |
| p13 | a call into `package:intl` with a new pattern | `stamp=2026-11-15` | `stamp=15 Nov 2026` |
| p15 | the body of a function in the local package | `tally=K1 3` | `tally=K2 3` |
| p17 | an SDK call chain (`split`, `where`, `map`, `toUpperCase`, `toList`) | (no line) | `words=[A, C]` |
| p18 | one override of a polymorphic method | `poly=circle1` | `poly=circle2` (`square1` unchanged, as intended) |
| p19 | a getter | `mood=M1` | `mood=M2` |
| p21 | a `switch` over an enum | `level=hi1` | `level=hi2` |
| p23 | a closure inside `build` (`FutureBuilder`'s builder) | `future-builder=FB1` | `future-builder=FB2` |
| p24 | a pattern `switch` expression | `result=ok 7` | `result=OK 7` |
| p26 | a static method | `static=S1` | `static=S2` |
| p27 | an explicitly instantiated generic call, `firstOr<String>(…)` | `generic=F1` | `generic=F2` |

Lines the patch did not touch kept their release values (`const=KT1`, `stars=***`, `square1`).

## Patch 2: 4 edits, 3 targets (`trio_boot.log`, `trio_boot2.log`)

`applied 3/3 targets` on both launches after the download (3735 bytes): `Label.build`,
`_HomeState._increment` and `_HomeState._start`. A patch is built against the release, not on top of patch
1, so every line outside these edits shows its release value again.

| edit | shape | before (release) | after |
|---|---|---|---|
| p03 | the body of a `setState` closure (`_count += 1` → `+= 10`) | `count=1..3` | `count=10..50` |
| p07 | the bound of a counted `for` loop that awaits each iteration (`i < 3` → `i < 5`) | 3 increments, `events=0` | 5 increments (`count` reaches 50), `events=5` |
| p16 | an added `List.add` on a field, then `join` | (no line) | `events-list=e10` … `e10,e20,e30,e40,e50` |
| p29 | only a `const` widget's text (`const Text('L1')` → `'L2'`) | | not captured: see below |

p29 changes only what is on screen, and its log line is unchanged by design. `Label.build` was activated,
but no screenshot was taken in this run, so this record does not show the new text. The 2026-11-15 run
showed it on screen.

## Refused before upload

Each was its own `shorebird patch ios` against the same release. Each exited 70, and nothing was uploaded.

| edit | what changed | the CLI's message (`refuse_*_cli.txt`) |
|---|---|---|
| p20 | a top-level `const` (`kTitle`) | `1 of 2 changed members cannot be carried … package:untab/main.dart#kTitle — this constant changed; a patch is compiled against the release's declarations, so code naming it would still read the old value` |
| p30 | a field initializer (`_events`) | `1 of 1 changed members cannot be carried … package:untab/main.dart#_HomeState.new — this constructor, an instance field initializer it runs, or a constant argument that every caller passes it changed; a patch replaces method bodies only, so the release keeps running its own` |

On the 2026-11-15 local cell, p20 shipped without its change and p30 was reported as "nothing differs".

## Rollback (`rb_learn.log`, `rb_boot.log`, `rb_boot2.log`)

`shorebird patches rollback --patch-number 2` → `Patch 2 on release 1.0.0+32 has been rolled back.`
(`rollback_cli.txt`).

| Launch | Updater | Values |
|---|---|---|
| `rb_learn` | boots patch 2, then the check returns `rolled_back_patch_numbers: Some([2])` | patch 2's |
| `rb_boot` | `Prepared boot of patch 1`, `applied 16/16 targets`, `current_patch_number: Some(1)` | patch 1's (`L2`, `c1..c3`, `I2`, …) |
| `rb_boot2` | the same | the same |

`steps.sh` ran the rollback first, from outside the app directory. The CLI exited 78
(`Unable to find shorebird.yaml`) and nothing was rolled back. `rollback.sh` ran it again from the app
directory, which is the run recorded above.

## Outbound hosts (`outbound_connect.jsonl`, every CONNECT through the run's proxy)

- `pub.dev`: package resolution (154 connections).
- `github.com` with `git-remote-http` (5): the clone of mml555/shorebird-flutter, and the git dependency
  `shorebird_build_trace`, which `packages/flutter_tools/pubspec.yaml` still pins to
  `https://github.com/shorebirdtech/shorebird.git`. That open item is unchanged from the `5f6efd98` run.

No request went to `*.shorebird.dev`, `storage.googleapis.com` or any other Shorebird-owned host.

## What this does not show

- p29's new text on screen (above).
- Not tried here: p11 (a new widget class), p12 (a new route page), p14 (a new API of a dependency), p22
  (an extension member), p25 (a new field) and p28 (a new top-level function). The CLI refuses all of
  them before publishing. p22 is refused because of a producer gap, not by design.
- One app on one device. No obfuscated release. Frame time was not measured.
- The CLI checkout was detached at `a443d87c`, so each CLI command also printed
  `Unable to check for updates … fatal: ref HEAD is not a symbolic ref`. That has no effect on the run.
