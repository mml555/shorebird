# iOS device run through cell 2fc41d3f (2026-11-16)

**Result: PASS.** The aab9fd07 run was repeated on a physical iPhone 7 (iOS 15.8.8) through the cell
`2fc41d3fbd9966958ba3ccf2be9761e064e92bcc`, then extended with the two features this cell adds: a patch may ADD a
private top-level function (#193) and a private instance method of an existing class (#194).

- Regression: patch 1 (18 edits) applied 16/16 targets and patch 2 (4 edits) applied 3/3, each on two launches.
  p20 and p30 were refused before upload. Rolling back patch 2 returned the device to patch 1 (16/16 on two launches).
- New: h1 (patch 3, 2/2), m1 (patch 4, 2/2) and m2 (patch 5, 1/1) published and showed their new values on two
  launches each. r1 and r2 were refused before upload (exit 70, nothing published). Rolling back patch 5 returned the
  device to patch 4 (2/2, `m1=LBL1..3`) on two launches.

## What ran

| | |
|---|---|
| CLI | mml555/shorebird `d7e5325eba1a96a4791fe774a6badb2404d6029a` (PR #195, detached worktree) |
| Flutter | shorebird-flutter `5c60356ca635c74696ab737e2d5e77f04d615057`; bootstrap printed `Flutter 3.46.0-1.0.pre-866`, `Shorebird Engine • revision 2fc41d3fbd9966958ba3ccf2be9761e064e92bcc` (`bootstrap.log`) |
| Engine | resolved from ci-build's production cdn-cache. `artifact_origin.jsonl`: 57 requests, 49 naming `2fc41d3f`; all 37 that returned 200 had `X-Overlay: hit`; the 20 404s are all `aot-tools.dill` probes |
| Descriptor | `GET download.shorebird.dev/shorebird/cell-manifests/2fc41d3f….v2` returned 200 (4141 bytes) 11 times |
| Server | `code_push_server` from the same checkout, local, `10.0.0.115:18290`, sqlite/file store |
| App | the shapes app (`shapes_main.dart` + `tally.dart` + `intl`), display name `shapes-2fc4`, version `1.0.0+33`, `shorebird release ios --no-codesign`, re-signed with `ios_resign.sh`, upgrade-installed over the existing `dev.selfhost.untab` (never uninstalled) |

The release command line carried `--extra-gen-snapshot-options=--route_b_untabled_overrides` on its own.
Scripts: `release.sh`, `lib.sh`, `steps.sh`, `steps2.sh`, `up.sh`, `all.sh`; `variants.py` is the aab9 file plus
five variants (h1, m1, m2, r1, r2), every substitution exact-once.

## Patch numbers on release 1.0.0+33

| # | what | outcome |
|---|---|---|
| 1 | combo, 18 edits | published, 9355 bytes, 16/16 |
| 2 | trio (p03+p16+p29+p07) | published, 3658 bytes, 3/3; later rolled back |
| 3 | h1 | published, 3105 bytes, 2/2 |
| 4 | m1 | published, 3096 bytes, 2/2 |
| 5 | m2 | published, 2704 bytes, 1/1; later rolled back |

Each patch is built against the release, not on top of the previous patch, so every line outside its edit shows the
release value. The first launch after a publish downloads (still runs the old patch); the next launches boot it.

## Regression (`combo_boot*.log`, `trio_boot*.log`, `rb_*.log`)

Same expectations as aab9 and the same values: `L2`, `H2`, `c1..c3`, `I2`, `G2`, `D2`, `R2`, `15 Nov 2026`, `K2`,
`words=[A, C]`, `circle2` (`square1` unchanged), `M2`, `hi2`, `FB2`, `OK 7`, `S2`, `F2` for patch 1; `count=10..50`,
`events=5`, `events-list=e10..e10,e20,e30,e40,e50` for patch 2 (all others at release values).
Refusals (each exit 70, "Nothing was uploaded"): p20 `package:untab/main.dart#kTitle`, p30
`package:untab/main.dart#_HomeState.new`. Rollback of patch 2 (`rollback_cli.txt`, exit 0, run from the app
directory this time): `rb_learn` still boots patch 2 and learns of the rollback, `rb_boot` and `rb_boot2` boot patch 1 with 16/16.

p29 is now seen on screen (`shots/trio_boot_3_s.png`, `trio_boot_2_s.png`): under patch 2 the screen shows `L2` below
`FB1 G1`, while the log still reads `label=L1` and the home text reads `H1 10`. `shots/trio_boot_8_s.png` shows the
detail page the app pushes at the end (`D1`, patch 2 leaves it alone).

## New edits

| edit | shape | patch | CLI | applied (two launches) | before -> after |
|---|---|---|---|---|---|
| h1 | new private top-level `String _greet(int n) => 'N$n';`, called from `_increment` (`log('h1', _greet(_count))`) | 3 | exit 0, "Published Patch 3" | 2/2, 2/2 | (no line) -> `h1=N1,N2,N3` |
| m1 | new private instance method `_HomeState._label() => 'LBL$_count'`, called from `_increment` | 4 | exit 0, "Published Patch 4" | 2/2, 2/2 | (no line) -> `m1=LBL1,LBL2,LBL3`; h1 line gone (patch 4 is built against the release) |
| m2 | new private `_HomeState._bump()` calling existing `_increment()` then `_count += 100`, called from `_start` | 5 | exit 0, "Published Patch 5" | 1/1, 1/1 | counts 1..3 -> 1..4, `bump=104`, `home-build=H1 104` |
| r1 | new PUBLIC `toJson` used by `jsonEncode(this)` | none | exit 70 | n/a | refused: "new member, and a PUBLIC method, which code outside this library can call by name" |
| r2 | new private `Label._increment`, same name as `_HomeState._increment` | none | exit 70 | n/a | refused: "its name is also used by `_HomeState._increment`; a carried helper's private name must be unique in its library" |

h1 and m1 each also carried the unchanged `_HomeState._start` ("carrying 1 unchanged member(s) that hold a copy of a
changed one"), which is why they report 2 targets. Rollback of patch 5 (`rollback2_cli.txt`, exit 0): `rb2_learn`
still booted patch 5 (1/1), `rb2_boot` and `rb2_boot2` booted patch 4 (2/2, `m1=LBL1..3`).

## Outbound hosts (`outbound_connect.jsonl`)

`pub.dev` (192), `github.com` via `git-remote-http` (5, the shorebird-flutter clone and the
`shorebird_build_trace` git dependency, as before), and, new compared with aab9: `github.com` (1) and
`release-assets.githubusercontent.com` (1) from `dartvm`, which is the release build downloading
`google/bundletool 1.18.3` (`release_cli.txt`: `GET .../google/bundletool/releases/download/1.18.3/bundletool-all-1.18.3.jar`).
That is not a Shorebird host. No request went to `*.shorebird.dev` or `storage.googleapis.com`.

## What this does not show

- A tap-driven increment: the app drives itself, so the "after a tap" case for m1 was the automatic `_increment` calls only.
- m2 does not show the new method's field write persisting beyond the log (`events` stays 0 by design).
- Not tried: p11, p12, p14, p22, p25, p28 (p28's shape, a new top-level function, is covered by h1).
- One app on one device, no obfuscated release, no frame-time measurement.
- Each CLI command printed `Unable to check for updates … ref HEAD is not a symbolic ref` (detached checkout); no effect.
- Screenshots were taken only on `combo_boot` and `trio_boot` (the others were not kept beyond the three listed); the combo shots were not examined.

## About this record

- `release_cli.txt` is an excerpt. The verbose release log prints the build environment, including the server API
  token, so only the lines this document cites are kept (the original line numbers are in its header).
  `steps.out` and `steps2.out` are the scripts' own outputs and carry every exit code quoted above.
  The server's API key and URL-signing secret lived in a `secrets.sh` that `env.sh` sources; it is not copied.
- `origin.py` and `connproxy.py` were recovered from an earlier session log, not from the repository.
- `patches list` on the server printed `[no track]` for patches 1 to 4 and `track: stable` for patch 5
  (`steps2.out`). Not explained, and no effect on what the device did.
- The release build downloads `bundletool` from github.com, which is not mirrored.
