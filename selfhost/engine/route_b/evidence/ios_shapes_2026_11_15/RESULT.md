# Ordinary Flutter edits on an iPhone, 2026-11-15

**Result:** one patch carrying 19 ordinary edits to a small Flutter app activated 16/16 targets on an iPhone 7 (iOS 15.8). Every edit with a target showed its patched value, with no crash. A second patch changed the bound of a counted `for` loop that awaits each iteration, and it ran 5 iterations instead of 3. The one edit that did not show, a top-level `const`, is a known producer gap.

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

`applied 16/16 targets, entering main`. There are 19 edits. p20 has no target, and the other 18 land on 16 targets:
- p17 and p27 both edit `_HomeState._start`;
- p23 sits inside the `_HomeState.build` that p02 edits.

The "before" values come from the patch 2 launch in `async_loop_patch2_launch1.log`. Patch 2 replaces only `_start` (with p07), so every other target there runs its release code. `label=L1` is the exception: that launch did not capture it, because the log stream attached late, so it is read from the release source. Long values are shortened.

| edit | shape | before | after |
|---|---|---|---|
| p01 | `StatelessWidget.build` | `label=L1` | `label=L2` |
| p02 | `State.build` | `home-build=H1` | `home-build=H2` |
| p04 | a method that calls `setState` (`_increment`, its log line) | `count=1` | `count=c1` |
| p05 | `initState`, which calls `super.initState()` | `init=I1` | `init=I2` |
| p06 | `async` function return | `greeting=G1` | `greeting=G2` |
| p08 | `async*` generator | `stream=T0..T2` | `stream=U0..U2` |
| p09 | a pushed route's page `build` | `detail=D1` | `detail=D2` |
| p10 | the `onGenerateRoute` callback (`routeFor`) | `route=R1` | `route=R2` |
| p13 | call into `package:intl` with a new pattern | `stamp=2026-11-15` | `stamp=15 Nov 2026` |
| p15 | body of a function in a local pure-Dart package | `tally=K1` | `tally=K2` |
| p17 | SDK call chain (`split`, `where`, `map`, `toUpperCase`, `toList`) | (none) | `words=[A, C]` |
| p18 | one override of a polymorphic method | `poly=circle1` | `poly=circle2` (`square1` unchanged, as intended) |
| p19 | getter | `mood=M1` | `mood=M2` |
| p20 | top-level `const` | `const=KT1` | **`const=KT1`, not patched** |
| p21 | `switch` over an enum | `level=hi1` | `level=hi2` |
| p23 | closure inside `build` (`FutureBuilder`'s builder, no `this` captured) | `future-builder=FB1` | `future-builder=FB2` |
| p24 | pattern `switch` expression | `result=ok` | `result=OK` |
| p26 | static method | `static=S1` | `static=S2` |
| p27 | an explicitly instantiated generic call, `firstOr<String>(…)`, inside `_start` (its argument changes) | `generic=F1` | `generic=F2` |

p20 has no target of its own. Its use, `log('const', kTitle)`, is in `_HomeState._start`, which this patch did replace, and the replaced body still printed `KT1`. `dart2bytecode` compiles a replacement against the release's import kernel, so a `const` named in the body is evaluated from the release's declaration. The analyzer did not see the edit, so the patch shipped without it. mml555/shorebird#172 makes the analyzer refuse a changed `const`, naming it.

The same combination was patch 1 on this release (`combo_patch1_launch2.log`), with the same result. That log lacks the first few app lines (`init`, `label`) because the log stream attached after the app started. The patch 3 launch captured them.

## The async loop (patch 2: `async_loop_patch2_launch1.log`)

`_HomeState._start` opens with a counted `for` loop that awaits each iteration, and later in the same function iterates a `List` with `for`-in. The edit changes `i < 3` to `i < 5`. Result: `applied 1/1 targets`, then `count=1..5` and `done=START-DONE`.

Before Dart PR #6's calling-convention change, this patch crashed (`EXC_BAD_ACCESS` at `0x8` in `_GrowableList.get:iterator`) when the replaced `_start` reached the `for`-in. The symbolicated crash is described in that PR; the crash log is not in this folder. This log file also holds the launch before the patch, where patch 1 was still running.

## Three more edits (patch 4: `trio_patch4_launch2.log`, `trio_patch4_launch3.log`)

One patch carrying p03, p16 and p29, on the same release and install. `applied 3/3 targets`, with `Label.build`, `_HomeState._increment` and `_HomeState._start` activated and no error.

| edit | shape | before | after |
|---|---|---|---|
| p03 | the body of a `setState` closure (`_count += 1` → `+= 10`) | `count=1..3` | `count=10`, `20`, `30` |
| p16 | an added `List.add` on a field, then `join` | (no line) | `events-list=e10`, `e10,e20`, `e10,e20,e30` |
| p29 | only a `const` widget's text (`const Text('L1')` → `'L2'`) | `L1` on screen | `L2` on screen (`trio_patch4_home_1s.png`) |

p29's log line is unchanged by design, so the screen is the evidence. The app navigates to the detail page about 2 seconds after launch, so the home page was captured 1 second in, on the third launch with patch 4 (`trio_patch4_launch3.log`). The cell's analyzer accepted p29. The analyzer on main reports this edit as "nothing differs" because it prints constants as `#C1`, which mml555/shorebird#172 fixes.

## What this does not show

- The compiler and engine came from a local test cell. No published cell carries them yet. The engine pin is mml555/shorebird-flutter#13.
- The `dart2bytecode` used here predates Dart PR #5's review fixes (`4a2df35bf4`, `137f06978c`). Those only add refusals and a runtime receiver cast, and were checked on the host with `qualify_dual_kernel_cell.sh`. They have not run on the device.
- Not tried on the device here: p11 (new widget class), p12 (new route page), p14 (new API of a dependency), p22 (extension), p25 (new field), p28 (new top-level function), p30 (field initializer). The CLI refuses all of them before publishing. p22 is refused by a producer bug, not by design, and p30 was wrongly reported as "nothing differs" (fixed in mml555/shorebird#172).
- One app on one device. No obfuscated release, and no rollback in this run. Rollback is proven on earlier releases.
- Size: with SDK name lookup on, this app's snapshot is 5,763,424 bytes against 5,705,600 off (+1.01%). Frame time was not measured.
