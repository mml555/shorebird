# Cell 97f91aff: a forged patch crashed pre-main activation on the iPhone (2026-11-26); the withdrawn cells before it

**Result: cell `97f91aff85e1db8b724afb51ff0e91466b78764c` (engine `64abe347da9ba3901b8c235aaf1f97dcda7f28eb`) is SUPERSEDED, not supported.** On the iPhone 7 (iOS 15.8.8, release `1.0.0+78`, bundle id `dev.selfhost.untab`), a forged two-target patch crashed the app in the pre-main activation hook, on every launch, until the patch was no longer the active one. Cell `83198f59` (engine `88a7bf8c`) replaces it; its run is [`../ios-cell-83198f59-forced-partial/RESULT.md`](../ios-cell-83198f59-forced-partial/RESULT.md). The `97f91aff` Linux promotion (2026-11-26) had passed; the Linux chain does not run a forged patch on a device.

The logs here are the excerpts the harness printed (`steps_d.out`, `steps_e.out`), the forge tool's output, and a summary of the crash report. Home paths are written `~`. The run's directory was `devrun/run-97f91aff` on the Mac; the crash reports and screenshots are not kept.

## The crash (`steps_d.out`, `forge_detach4.txt`, `crash_summary.txt`)

- Patch 4 was forged from a real patch by `route_b_forge_partial_patch.dart` (the test instrument of #305): two targets, `loadGreeting` and a selector that does not exist (`forge_detach4.txt`). It was published and downloaded (`download4`, 16:24:40 to 16:25:15, Mac clock UTC-5).
- On the next launch: `Prepared boot of patch 4`, `ROUTEB: hook entered`, `parsed, targets=2`, `activated loadGreeting in package:untab/main.dart before main`, and then nothing from Route B: no `REFUSED`, no `rolled back`, no `entering main`. The app died (`ReportCrash ... CORPSE`, `termination reported by launchd (2, 11, 11)`).
- The relaunch at 16:25:46 did the same (the second report). Both reports: `EXC_BAD_ACCESS`, `SIGSEGV`, `KERN_INVALID_ADDRESS at 0x00000000000000a7`, faulting in the `App` image (`kDartSnapshotText`) then `Flutter` (`crash_summary.txt`, the first report).
- The harness's step name for this run was `detach4`; the owner's brief calls the forge mode that did it append. The forge's printed target list for patch 4 is the two above, so this record states what the log shows and does not rely on the mode name.

What the log does not show: which line of the engine faulted. Only the sequence (the first target attached, then the fault before the second target's verdict) and the report's top frames are recorded.

## The rollback itself worked, with another forged patch (`steps_e.out`, `forge_retarget.txt`)

Run with `--retarget-last` (#305): patch 5, a real 3-target patch, applied 3/3 (`Launch success for patch 5`). Patch 6, patch 5's container with its last target renamed to a missing selector, booted as: `REFUSED (target-missing)`, `applied 2/3 targets`, `rolled back 2/2 attached targets, main runs the release code`, then `Patch 6 is known bad, skipping`, and the next boot ran patch 5 at 3/3. So rollback worked where the refusal happened after attaching, and crashed in patch 4's case. On engine `88a7bf8c` the forge's retarget-last and append modes (append over a 3-target patch, so 4 targets, not patch 4's 2) and reuse-first-payload were refused and rolled back without a crash. The exact shape that crashed `97f91aff` (its patch 4: a 1-target `loadGreeting` patch with a missing selector appended, so 2 targets) was rerun on `83198f59` on 2026-11-26: `REFUSED (target-missing)`, `rolled back 1/1 attached targets`, marked known bad, no crash ([`../ios-cell-83198f59-forced-partial/RESULT.md`](../ios-cell-83198f59-forced-partial/RESULT.md#the-97f91aff-crash-shape-rerun)). Which engine line faulted on `97f91aff` is still not known.

## The two withdrawn cells before it

- Engine `c9a5421ce57c8f9091462400fbc606ea0f7364ac` and cell `04e5ef97bb563da87cf32dc1380bc632a14d7bd3` were withdrawn and never overwritten. Their Dart SDK zips carried a stale revision label (fixed by shorebird #301 and dart-sdk-shorebird-lineage #9). They were never promoted or device-run for this record.
- Cell `97f91aff`'s PROVENANCE named the `build_engine_*` scripts as the build's source, but the scratch `build350_*` scripts built engine `c9a5421c`. That is as the owner reported it; it is not re-derived here, and the provenance file was not re-read for this note.

All four hashes (`c9a5421c`, `04e5ef97`, `64abe347`, `97f91aff`) stay in the Caddyfile protection groups and in `experimental_hashes.map`, and `64abe347` and `97f91aff` stay in `DartSdkCompatibility`. **Open owner question:** whether the CLI should refuse, or warn on, a release built against a withdrawn engine. Nothing in this change decides it; today the CLI accepts them.
