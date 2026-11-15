# Ordinary Flutter edits on an iPhone, 2026-11-15

**Result:** one patch carrying 18 ordinary edits to a small Flutter app activated 16/16 targets on an iPhone 7 (iOS 15.8). Every edit with a target showed its patched value, with no crash. A second patch, an `async` loop over a list, ran 5 iterations instead of 3. The one edit that did not show, a top-level `const`, is a known producer gap.

## What ran

- **App:** `shapes_main.dart` with the local pure-Dart package `tally.dart` and `package:intl`. Each patch is built by `variants.py`, which makes one exact substitution per edit and fails if a substitution does not match exactly once.
- **Engine:** the iOS release engine built locally with `shorebird_route_b=true` and `dart_dynamic_modules=true`. Dart was dart-sdk-shorebird-lineage at PR #6's head, which became `selfhost/3.13.7/route-b` at `b4671ab733`. The release was built with `--route_b_untabled_overrides`. The compiler cell was a local test cell, not a published one.
- **Release:** `1.0.0+10`, published to a local code push server and installed as an upgrade.
- **Patches:**
  - patch 1: the combination;
  - patch 2: the async loop alone;
  - patch 3: the combination again.

  The launch logs record `current_patch_number: Some(N)` and `applied N/N targets` for each.

## The combination (patch 3, second launch: `combo_patch3_launch2.log`)

`applied 16/16 targets, entering main`. The 18 edits:

| edit | shape | before | after |
|---|---|---|---|
| p01 | `StatelessWidget.build` | `label=L1` | `label=L2` |
| p02 | `State.build` | `home-build=H1` | `home-build=H2` |
| p04 | method called from `setState` | `count=1` | `count=c1` |
| p05 | `initState`, which calls `super.initState()` | `init=I1` | `init=I2` |
| p06 | `async` function return | `greeting=G1` | `greeting=G2` |
| p08 | `async*` generator | `stream=T0..T2` | `stream=U0..U2` |
| p09 | a pushed route's page `build` | `detail=D1` | `detail=D2` |
| p10 | `onGenerateRoute` table | `route=R1` | `route=R2` |
| p13 | call into `package:intl` with a new pattern | `stamp=2026-11-15` | `stamp=15 Nov 2026` |
| p15 | body of a function in a local pure-Dart package | `tally=K1` | `tally=K2` |
| p17 | SDK call chain (`split`, `where`, `map`, `toUpperCase`, `toList`) | (none) | `words=[A, C]` |
| p18 | one override of a polymorphic method | `poly=circle1` | `poly=circle2` (`square1` unchanged, as intended) |
| p19 | getter | `mood=M1` | `mood=M2` |
| p20 | top-level `const` | `const=KT1` | **`const=KT1`, not patched** |
| p21 | `switch` over an enum | `level=hi1` | `level=hi2` |
| p23 | closure inside `build` (`FutureBuilder`) | `future-builder=FB1` | `future-builder=FB2` |
| p24 | pattern `switch` expression | `result=ok` | `result=OK` |
| p26 | static method | `static=S1` | `static=S2` |
| p27 | generic function | `generic=F1` | `generic=F2` |

p20 has no target. A `const` is inlined at every use when the release is compiled, so changing it changes nothing. The producer does not refuse it yet, which is the gap.

The same combination was patch 1 on this release (`combo_patch1_launch2.log`), with the same result. That log lacks the first few app lines (`init`, `label`) because the log stream attached after the app started. The patch 3 launch captured them.

## The async loop (patch 2: `async_loop_patch2_launch1.log`)

`_HomeState._start` awaits in a `for` loop and, before that, iterates a `List`. The edit changes `i < 3` to `i < 5`. Result: `applied 1/1 targets`, then `count=1..5` and `done=START-DONE`. Before Dart PR #6's calling-convention change this patch crashed (`EXC_BAD_ACCESS` at `0x8` in `_GrowableList.get:iterator`). That was the first thing PR #6 fixed.

## What this does not show

- The compiler and engine came from a local test cell. No published cell carries them yet. The engine pin is mml555/shorebird-flutter#13.
- The `dart2bytecode` used here predates Dart PR #5's review fixes (`4a2df35bf4`, `137f06978c`). Those only add refusals and a runtime receiver cast, and were checked on the host with `qualify_dual_kernel_cell.sh`. They have not run on the device.
- Not tried on the device here: p03 (`setState` closure body), p11 (new widget class), p12 (new route page), p14 (new API of a dependency), p16 (`List.add` alone), p22 (extension), p25 (new field), p28 (new top-level function), p29 (a `const` widget only), p30 (field initializer).
- One app on one device. No obfuscated release, and no rollback in this run. Rollback is proven on earlier releases.
- Size: with SDK name lookup on, this app's snapshot is 5,763,424 bytes against 5,705,600 off (+1.01%). Frame time was not measured.
