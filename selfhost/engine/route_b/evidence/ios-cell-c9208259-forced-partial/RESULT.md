# iOS forced-partial-patch run through cell c9208259 (2026-11-27)

**Result: FORCED_PARTIAL_PASS.** On the iPhone 7 (iOS 15.8.8), through cell `c920825972cdc7e096fa114bbb616b306914c4c7` (Flutter 3.50, engine `93adf4fb`, Dart `e3f6fa90`), five forged patches, each built to fail during activation, were each refused by the engine, rolled back as a whole, and marked known bad. The app kept running patch 1 at 3 of 3 targets, and no launch crashed.

What is new against the previous cell, `83198f59`: two more forge modes. A payload that does not load (`bad-format-last`, `unresolve-last`) now prints `ROUTEB: payload does not load, refused: <reason>`, then `REFUSED (invalid-bytecode)`, and rolls back. The fix is dart-sdk-shorebird-lineage #11 and shorebird-flutter #24. On engine `88a7bf8c` the same two patches aborted the app before `main`; see "Evidence of the problem" below.

The three modes that `83198f59` already ran (`retarget-last`, `reuse-first-payload`, `append`) give the same verdicts here.

Times are the Mac's clock, UTC-5, 2026-11-27 12:46 to 12:59 (17:46 to 17:59 UTC).

## What ran

| | |
|---|---|
| Device | iPhone 7, iOS 15.8.8 (19H422), USB (`install.txt`, device name redacted) |
| CLI | mml555/shorebird `4a3adb1dfae837cf4c2d49061cdd5e25ea670391`, the head of #313 (`git rev-parse HEAD` in `devrun/run-c9208259/cli`). `Shorebird 1.6.144+selfhost.1` (`bootstrap.log`) |
| Flutter and engine | `bootstrap.log` prints `Flutter • revision 246fd6f6fc70f2c4a7fb9b563eda5fcdccba2104` and `Engine • revision c920825972cdc7e096fa114bbb616b306914c4c7` |
| App | the shapes app, bundle id `dev.selfhost.untab`, release `1.0.0+80`: `shorebird release ios --no-codesign`, then re-signed and installed (`release.out`: `SIGN_OK`, `RELEASE_DONE`) |
| Signing | a fresh key pair made for this run. Only `public.pem` is kept here; the private key and the run's secrets file are not. The forge tool verified each forged patch's signature against it (`forge_*.txt`) |
| Forge | `packages/shorebird_cli/tool/route_b_forge_partial_patch.dart`, a test instrument that republishes a real two-patch container with one change. Run with `FORGE_MODES="retarget-last reuse-first-payload append bad-format-last unresolve-last"` |
| Harness | `selfhost/engine/route_b/device_run/`; step output in `forced_partial.out` |

## Steps and verdicts

Patch numbers are the server's. Each patch was downloaded on one launch, booted on the next, then a third launch ("after") showed the state the app settles in.

| Patch | What it is | Boot verdict (`<step>_boot.log`) | Next boot |
|---|---|---|---|
| 1 (`two`) | a real patch, 3 targets: `_HomeState._increment`, `_HomeState._start`, `loadGreeting` | `applied 3/3 targets`, `Launch success for patch 1`, greeting `G2` | |
| 2 (`retarget-last`) | patch 1's container with its last target renamed to a selector that does not exist | `target ... not found`, `REFUSED (target-missing)`, `applied 2/3`, `rolled back 2/2 attached targets, main runs the release code`, greeting `G1` | `Patch 2 is known bad, skipping`; patch 1 runs at 3/3 |
| 3 (`reuse-first-payload`) | the last target carries the first target's payload | `ROUTEB: payload library ~/.../replacement_0.dart is already loaded`, `loadGreeting ... REFUSED (invalid-bytecode)`, `applied 2/3`, `rolled back 2/2`, greeting `G1` | `Patch 3 is known bad, skipping`; patch 1 runs at 3/3 |
| 4 (`append`) | patch 1's container with a fourth, non-existent target appended | `REFUSED (target-missing)`, `applied 3/4`, `rolled back 3/3 attached targets`, greeting `G1` | `Patch 4 is known bad, skipping`; patch 1 runs at 3/3 |
| 5 (`bad-format-last`) | the last target's payload has its bytecode format version word forged to `0xFFFFFFFF` | `ROUTEB: payload does not load, refused: Unsupported Dart bytecode format version 4294967295. This version of Dart VM supports bytecode format version 3.`, `loadGreeting ... REFUSED (invalid-bytecode)`, `applied 2/3`, `rolled back 2/2 attached targets, main runs the release code`, greeting `G1` | `Patch 5 is known bad, skipping`; patch 1 runs at 3/3 |
| 6 (`unresolve-last`) | the last target's payload names `dart:cor_` instead of `dart:core` | `ROUTEB: payload does not load, refused: Unable to find library dart:cor_`, `loadGreeting ... REFUSED (invalid-bytecode)`, `applied 2/3`, `rolled back 2/2 attached targets, main runs the release code`, greeting `G1` | `Patch 6 is known bad, skipping`; patch 1 runs at 3/3 |

In every "after" log the app reached the end of `main`'s shape lines with greeting `G2`, the greeting of patch 1.

`crash.out` shows the harness found no crash report newer than the run's start (`no crash reports since 2026-11-27-124545` in `forced_partial.out`). The two `Runner-2026-11-26-1625*.ips` reports it lists are from the `97f91aff` run (see below) and are not kept.

## Evidence of the problem this cell fixes

- Engines up to `88a7bf8c` abort before `main` on a payload that does not load (`Unsupported Dart bytecode format version`, `Unable to find library ...`): the table in [`../../device_run/README.md`](../../device_run/README.md), "The two load-failure modes". This cell is the run that shows the refusal on device.
- The earlier activation crash, on cell `97f91aff`: [`../ios-cell-97f91aff-activation-crash/RESULT.md`](../ios-cell-97f91aff-activation-crash/RESULT.md).
- The previous cell's run of the other three modes: [`../ios-cell-83198f59-forced-partial/RESULT.md`](../ios-cell-83198f59-forced-partial/RESULT.md).

## Limits

- **Signed with a fresh key, one device, one app, one CLI.** Unsigned patches were not run here.
- **These are forged patches.** They exercise the engine's refusal and rollback paths, not the Route B coverage of ordinary edits. Patch 1 is an ordinary patch.
- **No crash-shape rerun this time.** The `97f91aff` crash shape was rerun on `83198f59` and is in that record.
- **Android** is a separate run: [`android-cell-c9208259`](../android-cell-c9208259/RESULT.md).
- **`unresolve-last_after.log` has no `Launch success for patch 1` line**, and no `shape:init` or `shape:label` line. The app ran: patch 1 at 3/3, greeting `G2`, `shape:done=START-DONE`. The raw capture lacks those lines too, so they were lost from the system log, not cut here. The other four "after" logs have them.
- **The `.dbg` captures are empty** (0 bytes, not kept), and the screenshots were not kept: the status bar can show personal notifications. The `<step>_*.log` files are the app's own lines from the iPhone's system log (`Runner(Flutter)`), cut from the 2.7-4.5 MB captures, as in the `83198f59` record: the startup `INFO` and `IMPORTANT` lines, the `ATTACH` line and the lines naming device paths are left out. The same lines are in `forced_partial.out`.
- **The release's `built-for` hash `ff1d533b...` equals the one in the `83198f59` and `97f91aff` runs** (other releases, `1.0.0+79` and `1.0.0+78`). It is the Route B release hash the engine prints; the same app source gives the same hash. It was not checked further.
- **`install.txt` is cut**: the per-file `Copying` lines are removed. Home paths are written `~`, and the device name is redacted.

## Files

`forced_partial.out` (step output and device lines), `forge_*.txt` (what each forged patch contains, its sha256, and the signature check), `two_*`, `retarget-last_*`, `reuse-first-payload_*`, `append_*`, `bad-format-last_*` and `unresolve-last_*` `.log` (the app's lines per launch: `download`, `boot`, `after`), `release.out`, `bootstrap.log`, `install.txt`, `crash.out`, `public.pem`.
