# iOS device run through cell a6a48cf6 (2026-11-19)

**Result: PARTIAL. Not a clean pass; this cell is not device-qualified by this run.** The `2fc41d3f` sequence was
repeated on a physical iPhone 7 (iOS 15.8.8) through the cell `a6a48cf673a291f607323e89b41839c4b8b74e5d`, plus the
edits analysis 21 allows. Every patch that published applied all its targets on every launch, the refusals that
reached their own verdict were the right ones, and all three rollbacks worked. Two things keep it from a pass, and
a third narrows what the cell was meant to add:

1. **Most patches skipped the snapshot check.** Nine of the eleven published patches were published with
   `--allow-unchecked-sdk-calls`, because the checked build was refused only for a known checker false positive (see
   [Patches that skipped the snapshot check](#patches-that-skipped-the-snapshot-check)).
2. **p15 was silently left out of the combo patch.** The edit to the `tally` dependency package (`K1` -> `K2`) was
   applied to the source, the patch published, and the device ran the release's `tallyLabel` (`tally=K1 3`). The
   2fc41d3f run applied the same edit (16/16, `K2 3`). Nothing in the CLI's output says the edit was dropped.
3. The extension form of "a member naming its own class's statics" was refused (e1, e1b); only the class form passed.
   The refusal itself is correct (before upload, with the reason: a replacement does not pass the extension's
   receiver), so it is a coverage gap against what the cell was promoted for, not a wrong verdict.

Where the fixes stand: #247 (the for-in false positive) and #248 (the flag's side effect) are merged; #247 ships as
analysis version 23, which this cell's v21 analyzer does not have, so a checked run needs a new cell. #251 (refuse a
patch that changes a dependency instead of dropping it; its root cause is `c9c6270d8`, the app-only `--include`
prefix reaching the patch path) and #252 (the SDK kept check asks concrete base classes too) are open. Qualifying
needs a new analysis-23 cell, a CLI with #248, #251 and #252, and this sequence rerun with the check on.

## What ran

| | |
|---|---|
| CLI | mml555/shorebird `e7384444fad53cdd35317fe3dc0abc4d3c7b1c36` (the merge of PR #234, pubspec `1.6.140+selfhost.1`) plus ONE cherry-pick: `05d5b08db34a3ec4a2b2a0db51766abc328cda2a`, which is `72873c909` from PR #248 ("read the snapshot profile under --allow-unchecked-sdk-calls"). Local scratch branch `devrun/a6a4-unchecked-fix`; the CLI snapshot was rebuilt from it before any patch. The release was built by `e7384444` alone (the cherry-pick touches only the patch path). So the patches were built by `e7384444` plus `05d5b08d`, not by the pinned CLI alone. |
| Flutter | shorebird-flutter `cc4fc222c210836f89bde6e91f7580e8241432da`; bootstrap printed `Flutter 3.46.0-1.0.pre-866` and `Shorebird Engine • revision a6a48cf673a291f607323e89b41839c4b8b74e5d` (`bootstrap.log`) |
| Engine | resolved from ci-build's production cdn-cache (`10.0.0.41:8085`) through `origin.py`. Release phase (`artifact_origin_release.jsonl`): 7 requests, 3 descriptor fetches returned 200 with `X-Overlay: hit`, 4 `aot-tools.dill` probes 404 (the engine artifacts were already in the CLI's cache). Patch phase (`artifact_origin.jsonl`): 87 requests, all naming `a6a48cf6`; the 29 that returned 200 are the descriptor, all `X-Overlay: hit`; the 58 404s are all `aot-tools.dill` probes |
| Descriptor | `GET download.shorebird.dev/shorebird/cell-manifests/a6a48cf6….v2`, 200, 4141 bytes, once per CLI command |
| Server | `code_push_server` from the same checkout, local, `10.0.0.242:18290` (the Mac's LAN address changed from `10.0.0.115` since the last run), sqlite/file store |
| App | the shapes app (`main.dart` + `tally.dart` + `intl`), display name `shapes-a6a4`, app id `f40fd369-cd9a-b8f0-59bb-c23cfa9f2812`, version `1.0.0+70`, `shorebird release ios --no-codesign`, re-signed with `ios_resign.sh`, upgrade-installed over the existing `dev.selfhost.untab` (never uninstalled; `install.txt`) |
| Release | `Route B retention: 57 named SDK members kept (default set only …)` (`release_cli.txt` line 916): the #234 default, no `keep_sdk_collection_methods` |

The release printed `No patch public key was provided`: patches in this run were not signed.

Scripts: `release.sh`, `lib.sh`, `up.sh`, `all.sh` (runs `steps.sh`, `steps2.sh`, `steps3.sh`), `steps4.sh`,
`steps4b.sh`, `steps5.sh`. `variants.py` is the 2fc41d3f file plus this cell's variants (s1b, s1, i1, i2, i2b, e1, e1b,
t1), with p17 taken out of the combo (it calls `Iterable.map`, measured unsafe). Every substitution is exact-once.

## Patches that skipped the snapshot check

`lib.sh`'s `patch()` builds each patch without the flag first. When, and only when, that build was refused with
"calls the dart: method `Iterable.iterator`", it rebuilt the same edit with `--allow-unchecked-sdk-calls`
(`patch_<name>_cli.txt` keeps both verdicts). Patches named `refuse_*` were never retried.

The cause is a checker false positive, PR #247: the analyzer records a for-in loop as a call to `Iterable.iterator`
with no receiver type, so the per-release snapshot check (`route_b_sdk_kept.dart`) demands `get:iterator` on every
`Iterable` class the release could hold there, and refuses on `ObserverList` (`package:flutter/src/foundation/observer_list.dart`).
The loop is `_HomeState._start`'s `for (final s in shapes)` over a `List<Shape>`. `_start` is in every patch that
changes it or carries it, which is nearly all of them.

The flag also had a side effect that blocked the combo patch in the first attempt: with it, the CLI did not read the
snapshot profile at all, so #230's extension-getter path refused every `Ext|get#x` ("`Stars|get#stars` … which the
release never used"). That is PR #248; its commit is the one cherry-pick above.

| patch | variant | checked build | published with the flag |
|---|---|---|---|
| 1 | combo | refused: `Iterable.iterator` only | yes |
| 2 | trio | refused: `Iterable.iterator` only | yes |
| 3 | h1 | refused: `Iterable.iterator` only | yes |
| 4 | m1 | refused: `Iterable.iterator` only | yes |
| 5 | m2 | refused: `Iterable.iterator` only | yes |
| 6 | s1b | published | no |
| 7 | s1 | published | no |
| 8 | i1 | refused: `Iterable.iterator` only | yes |
| 9 | i2b | refused: `Iterable.iterator` only | yes |
| 10 | i2 (steps4b) | refused: `Iterable.iterator` only | yes |
| 11 | p16 (steps4b) | refused: `Iterable.iterator` only | yes |

The flag skips only the snapshot-kept check. p20 shows the other checks still run under it: rebuilt with the flag, it
was refused for `package:untab/main.dart#kTitle` ("this constant changed …"), exit 70, nothing uploaded
(`patch_unchecked_p20_cli.txt`). It was never booted.

## Patch numbers on release 1.0.0+70

| # | what | size | outcome |
|---|---|---|---|
| 1 | combo, 17 edits (p15 among them, p17 left out) | 8.83 KB | 15 compiled targets (the edits touch 16 functions; p15's `tallyLabel` was dropped), 15/15 on two launches (below) |
| 2 | trio (p03+p16b+p29+p07) | 3.71 KB | 3/3 on two launches; later rolled back |
| 3 | h1 | 3.18 KB | 2/2, 2/2 |
| 4 | m1 | 3.18 KB | 2/2, 2/2 |
| 5 | m2 | 2.79 KB | 1/1, 1/1; later rolled back |
| 6 | s1b | 1.06 KB | 1/1, 1/1 |
| 7 | s1 | 1.08 KB | 1/1, 1/1 |
| 8 | i1 | 3.05 KB | 2/2, 2/2 |
| 9 | i2b | 3.01 KB | 2/2, 2/2 |
| 10 | i2 | 3.01 KB | 2/2, 2/2 (steps5, after patch 11 was rolled back) |
| 11 | p16 (`List.add` + `Iterable.join`) | 3.19 KB | 2/2, 2/2; then rolled back (`rollback3_cli.txt`, exit 0) |

Each patch is built against the release, not on top of the previous patch, so every line outside its edit shows the
release value. The first launch after a publish downloads (still runs the old patch); the next launches boot it.

## Regression (`combo_boot*.log`, `trio_boot*.log`, `rb_*.log`)

Release (`boot_release*.log`, no active patch): `L1`, `H1`, `count=1..3`, `I1`, `G1`, `D1`, `R1`, `2026-11-15`,
`K1 3`, `circle1`, `square1`, `M1`, `hi1`, `FB1`, `ok 7`, `S1`, `F1`, `arith=2:false`, `half=1.5`, `decorate=[P1:3]`,
`stars=***`.

Patch 1 (15/15 on `combo_boot` and `combo_boot2`): `L2`, `H2`, `c1..c3`, `I2`, `G2`, `D2`, `R2`, `15 Nov 2026`,
`circle2` (`square1` unchanged), `M2`, `hi2`, `FB2`, `OK 7`, `S2`, `F2`. **`tally=K1 3`**, where 2fc41d3f showed `K2 3`.

**p15 (FAIL).** The combo applies `p15_dep_body` to `packages/tally/lib/tally.dart` (`'K1 $n ` -> `'K2 $n `; the file
and the variant are identical to 2fc41d3f's). The patch log lists 15 `[route-b] compiled` members, all in
`package:untab/main.dart`; `tallyLabel` (`package:tally/tally.dart`) is not among them and no line mentions the
package, so the CLI neither carried nor refused the change. The device then booted 15/15 and printed the release's
`K1 3`. The 2fc41d3f run (CLI `d7e5325e`) compiled 16, `tallyLabel` included. The Nov 17 dry run of this cell's
sequence (CLI `b7a0c335`) also compiled 15. #251 traces it to `c9c6270d8` (in `d7e5325e..b7a0c335`): the coverage
analysis on the patch path compares only `package:<app>/` libraries, so a change in another package is never seen.
A patch that silently drops an edit to a path dependency is a correctness bug, not a coverage gap.

Patch 2 (3/3 on two launches): `count=10..50`, `events=5`, `events-list=1..5`, `home-build=H1 10..50`; others at
release values.

Refusals: p20 `kTitle` and p30 `_HomeState.new` (`patch_refuse_const_cli.txt`, `patch_refuse_field_cli.txt`). p30
was refused for its own reason ("this constructor, an instance field initializer it runs … changed"). p20's checked
build was refused only for the `Iterable.iterator` false positive, so its own verdict came from the flagged rebuild
in steps4 (above): `kTitle`, as before.

Rollback of patch 2 (`rollback_cli.txt`, exit 0): `rb_learn` booted patch 2 (3/3) and learned
`rolled_back_patch_numbers: [2]`; `rb_boot` and `rb_boot2` booted patch 1 (15/15, combo values).

## steps2: h1, m1, m2, r1, r2

| edit | patch | applied (two launches) | before -> after |
|---|---|---|---|
| h1, new private top-level `_greet` | 3 | 2/2, 2/2 | (no line) -> `h1=N1,N2,N3` |
| m1, new private `_HomeState._label` | 4 | 2/2, 2/2 | (no line) -> `m1=LBL1,LBL2,LBL3` |
| m2, new private `_HomeState._bump` | 5 | 1/1, 1/1 | counts 1..3 -> 1..4, `bump=104`, `home-build=H1 104` |
| r1, new PUBLIC `toJson` used by `jsonEncode(this)` | none | exit 70 | refused: "it uses the symbol `jsonEncode`, which the release never used" |
| r2, new private `Label._increment` | none | exit 70 | refused: "it uses the private member `Label._increment` … which the release never used" |

r1 and r2 were refused before upload, but for different reasons than in 2fc41d3f ("new member, and a PUBLIC
method" and the private-name collision). Both are true statements about the edit, and the first one found wins; the
2fc41d3f reasons were not reached. Rollback of patch 5 (`rollback2_cli.txt`, exit 0): `rb2_learn` booted patch 5
(1/1) and learned `[2, 5]`; `rb2_boot` and `rb2_boot2` booted patch 4 (2/2, `m1=LBL1..3`).

## This cell's edits (steps3, steps4b, steps5)

| edit | shape | patch | applied (two launches) | before -> after |
|---|---|---|---|---|
| s1b | class member naming its own class's static, nested in an interpolation | 6 | 1/1, 1/1 | `decorate=[P1:3]` -> `[[n3]]` |
| s1 | class member naming its own class's statics unqualified | 7 | 1/1, 1/1 | `decorate=[P1:3]` -> `P1/[P1]/3` |
| i1 | inlined `int` operators (`+`, `*`, `>`) | 8 | 2/2, 2/2 | `arith=2:false` -> `4:true` |
| i2b | inlined `double` operators (`*`, `+`) | 9 | 2/2, 2/2 | `half=1.5` -> `1.25` |
| i2 | `int / int` (`num./`), then `+` | 10 | 2/2, 2/2 | `half=1.5` -> `1.25` |
| e1 | extension instance getter `Stars|get#stars` naming the extension's static `glyph` | none | exit 70 | refused: "its class scope cannot be carried: it is an instance member of `Stars`, whose receiver a replacement does not pass" |
| e1b | the same getter, interpolating `this` | none | exit 70 | refused, same reason |
| p16 | `_events.add` + `_events.join(',')` | 11 | 2/2, 2/2 | (no line) -> `events-list=e1`, `e1,e2`, `e1,e2,e3`; `events=3` |
| p17 | `Iterable.where/map/toList` chain | none | exit 70 | refused: `Iterable.map` (measured: throws NoSuchMethodError) and `Iterable.toList`, besides the false positive |
| t1 | class member using the class type parameter `T` | none | exit 70 | refused: "uses the class type parameter `T`" |

s1 and s1b each published without the flag. i2 and p16 were in steps3's refusal list from the dry run, but steps3's
checked builds were refused only for `Iterable.iterator`, so steps4b rebuilt them with the flag (no launches) and
steps5 booted them: p16 first (patch 11, then rolled back), then i2 (`i2_learn` booted 11 and learned the rollback,
`i2_boot` and `i2_boot2` booted 10). No launch logged a NoSuchMethodError or an unhandled exception. The dry run measured i2 as refused for `num./`; with this cell's v21
analyzer the checked build no longer named it (only `Iterable.iterator`), consistent with `/` on two `int`s being an
inlined operator.

## Outbound hosts (`outbound_connect_release.jsonl`, `outbound_connect.jsonl`)

`pub.dev` (51 during the release, 5 during the patches) and `github.com` via `git-remote-http` (1 each, the
`shorebird_build_trace` git dependency). No request went to `*.shorebird.dev` or `storage.googleapis.com`; the
descriptor and artifacts came through `origin.py` from ci-build.

## What this does not show

- A checked patch of anything that touches `_HomeState._start`: every such patch here was published with the
  snapshot check skipped. #247 is merged, but as analysis version 23, so it needs a new cell. The patches' SDK calls were not checked against what this release kept; the device
  ran each one without a NoSuchMethodError, which covers these edits on this release only.
- The p15 path-dependency edit (FAIL above).
- The extension form of a member that names its own statics, and an extension static method (not tried).
- Signed patches. The release had no patch public key (`No patch public key was provided`), so nothing here covers
  the signed path, which customers must use (signing is mandatory since 2026-11-16).
- A tap-driven increment, an obfuscated release, frame times, a second device.

## About this record

- Earlier attempts the same day stopped before any patch: the release built on 2026-11-17 used the old CLI
  `af1e14a1` and was rebuilt as `1.0.0+70`; launches failed with "Could not start com.apple.debugserver" until the
  owner mounted the iOS 15.5 developer disk image; the combo's first flagged build was refused for `Stars|get#stars`
  (#248). Their logs are not part of this record.
- `release_cli.txt`, `install.txt` and the `patch_*_cli.txt` files are excerpts with the original line numbers. The
  verbose logs dump the build environment, including the server's API token, so they are not kept; the install log
  is cut to drop the device's name. The API key and URL-signing secret live in a `secrets.sh` that `env.sh` sources;
  it is not copied.
- `steps4.sh` was stopped after p20, before i2, because as written it would have booted anything it published;
  `steps4b.sh` reran i2 and p16 without launching, and `steps5.sh` booted what they published (p20 excluded).
- Each launch's log is the `Runner(Flutter)` lines of the device syslog during that launch.
