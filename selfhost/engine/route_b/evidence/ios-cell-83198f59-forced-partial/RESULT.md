# iOS forced-partial-patch run through cell 83198f59 (2026-11-26)

**Result: FORCED_PARTIAL_PASS.** On the iPhone 7 (iOS 15.8.8), through cell `83198f598d638fb2b5848f64bb377f504185a3da` (Flutter 3.50, engine `88a7bf8c`), three forged patches, each built to fail partway through activation, were each refused by the engine, rolled back as a whole, and marked known bad. The app kept running patch 1 at 3 of 3 targets, and no launch crashed. The engine `88a7bf8c` carries the all-or-nothing container rollback (shorebird-flutter #20, dart-sdk-shorebird-lineage #8) and the already-loaded-payload refusal (shorebird-flutter #23, lineage #10). The run is the device evidence that the previous cell, `97f91aff`, did not survive: see [`../ios-cell-97f91aff-activation-crash/RESULT.md`](../ios-cell-97f91aff-activation-crash/RESULT.md).

Times are the Mac's clock, UTC-5, 2026-11-26 19:45 to 19:53 (2026-11-27 00:45 to 00:53 UTC).

## What ran

| | |
|---|---|
| Device | iPhone 7, iOS 15.8.8 (19H422), USB (`install.txt`, device name redacted) |
| CLI | mml555/shorebird `6885b3fc6256b743ea364cb2b5f773e56215d87d`, the head of #307. Its `packages/shorebird_cli` (`dea83097`), `bin/internal` (`05364f8d`) and `packages/code_push_server` (`afba38b5`) trees equal those of the merge `910ff250` that the record pins (`git rev-parse` on both). `Shorebird 1.6.144+selfhost.1` (`bootstrap.log`) |
| Flutter and engine | shorebird-flutter `b259cf5419ac79d1da59099b2ebbaa9f8f519877`; `bootstrap.log` prints `Engine • revision 83198f598d638fb2b5848f64bb377f504185a3da` |
| App | the shapes app, bundle id `dev.selfhost.untab`, release `1.0.0+79`: `shorebird release ios --no-codesign`, then re-signed and installed (`release.out`: `SIGN_OK`, `RELEASE_DONE`) |
| Signing | a fresh key pair made for this run. Only `public.pem` is kept here; the private key and the run's secrets file are not. The forge tool verified each forged patch's signature against it (`forge_*.txt`) |
| Forge | `packages/shorebird_cli/tool/route_b_forge_partial_patch.dart`, a test instrument that republishes a real two-patch container with one change |
| Harness | `selfhost/engine/route_b/device_run/`; step output in `forced_partial.out` |

## Steps and verdicts

Patch numbers are the server's. Each patch was downloaded on one launch, booted on the next, then a third launch ("after") showed the state the app settles in.

| Patch | What it is | Boot verdict (`<step>_boot.log`) | Next boot |
|---|---|---|---|
| 1 (`two`) | a real patch, 3 targets: `_HomeState._increment`, `_HomeState._start`, `loadGreeting` | `applied 3/3 targets`, `Launch success for patch 1`, greeting `G2` | |
| 2 (`retarget-last`) | patch 1's container with its last target renamed to a selector that does not exist | `target ... not found`, `REFUSED (target-missing)`, `applied 2/3`, `rolled back 2/2 attached targets, main runs the release code`, greeting `G1` | `Patch 2 is known bad, skipping`; patch 1 runs at 3/3 |
| 3 (`reuse-first-payload`) | the last target carries the first target's payload | `ROUTEB: payload library ~/.../replacement_0.dart is already loaded`, `loadGreeting ... REFUSED (invalid-bytecode)`, `applied 2/3`, `rolled back 2/2`, greeting `G1` | `Patch 3 is known bad, skipping`; patch 1 runs at 3/3 |
| 4 (`append`) | patch 1's container with a fourth, non-existent target appended | `REFUSED (target-missing)`, `applied 3/4`, `rolled back 3/3 attached targets`, greeting `G1` | `Patch 4 is known bad, skipping`; patch 1 runs at 3/3 |

The reuse-first-payload step exercises lineage #10's refusal of a payload library that is already loaded: engine `88a7bf8c` refuses it with `invalid-bytecode` and rolls back. Engine `64abe347` (cell `97f91aff`) was not run with this mode. The exact shape that crashed `97f91aff` (its patch 4: a 1-target `loadGreeting` patch with a missing selector appended, so 2 targets) was rerun on `83198f59` on 2026-11-26: `REFUSED (target-missing)`, `rolled back 1/1 attached targets`, marked known bad, no crash; see below.

`crash.out` shows the harness found no crash report newer than the run's start (`no crash reports since 2026-11-26-194349` in `forced_partial.out`). The two `Runner-2026-11-26-1625*.ips` reports it also copied are 3.5 hours older than the first launch here. They are the `97f91aff` run's crashes of the same bundle id (see the other record) and are not kept.

## The 97f91aff crash shape, rerun

Run after the forced-partial steps, 2026-11-26 21:19 to 21:23 (Mac clock, UTC-5), same app, release, keys and harness. Logs: `crash_shape_*.log` (the app's own syslog lines), `forge_crash_shape.txt`, `crash_shape_crash.out`.

| Patch | What it is | Boot verdict |
|---|---|---|
| 5 (`one`) | a real 1-target patch (`p06_async_return`, `loadGreeting` only; container 1882 bytes, as on `97f91aff`) | `parsed, targets=1`, `applied 1/1 targets`, `Launch success for patch 5`, greeting `G2` |
| 6 (`append`) | patch 5's container with `selfhost_forged_partial_patch_no_such_selector` appended: targets `loadGreeting` and the bogus one (2018 bytes, as `97f91aff`'s patch 4) | `parsed, targets=2`, `activated loadGreeting ... before main`, `REFUSED (target-missing)`, `applied 1/2 targets`, `rolled back 1/1 attached targets, main runs the release code`, `Patch 6 is known bad, skipping`, greeting `G1` |
| next boot | | `Prepared boot of patch 5`, `applied 1/1 targets`, `Launch success for patch 5`, greeting `G2` |

On `97f91aff` the same sequence stopped after `activated loadGreeting` with a SIGSEGV on every launch. `crash_shape_crash.out` lists only the two `97f91aff` reports from 16:25 again; no report is newer than this run's start (21:19:23).

## Limits

- **Signed with a fresh key, one device, one app, one CLI.** Unsigned patches were not run here.
- **These are forged patches.** They exercise the engine's refusal and rollback paths, not the Route B coverage of ordinary edits. Patch 1 is an ordinary patch: the 3-target `p06_async_return` plus `p03_setstate_closure` edit.
- **Android** is a separate run: [`android-cell-83198f59`](../android-cell-83198f59/RESULT.md).
- **The `.dbg` captures are empty** (0 bytes, not kept), and the screenshots were not kept: the status bar can show personal notifications. The `<step>_*.log` files are the app's own lines from the iPhone's system log (`Runner`), cut from the 2.6-5.4 MB captures; the same lines are in `forced_partial.out`.
- **The release's `built-for` hash `ff1d533b...` equals the one in the `97f91aff` run** (a different release, `1.0.0+78`). It is the Route B release hash the engine prints; the same app source gives the same hash. It was not checked further.
- **`install.txt` is cut**: the per-file `Copying` lines are removed. Home paths are written `~`.

## Files

`forced_partial.out` (step output and device lines), `forge_*.txt` (what each forged patch contains, its sha256, and the signature check), `two_*`, `retarget-last_*`, `reuse-first-payload_*` and `append_*` `.log` (the app's lines per launch: `download`, `boot`, `after`), `release.out`, `bootstrap.log`, `install.txt`, `crash.out`, `public.pem`.
