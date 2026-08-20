# NEXT SESSION — produce ONE coherent, publishable engine cell

Scope is deliberately narrow. **Do not reopen lifecycle semantics.** The
lifecycle question is answered as far as it can be without a wired engine; this
session exists only to produce that engine through the documented pipeline.

## WHY THIS IS NOT A COMPILER PROBLEM

The Mac build failure was a **stale generated file**, not a toolchain defect:
`version.cc` from 2026-08-10 hard-coded SDK hash `6b58bb3a72` while the Dart SDK
HEAD had moved to `9e8c898a4d`. Deleting it gave `ninja exit=0`. See
`evidence/g15/after_run_BLOCKED.md`.

The remaining problem is **artifact coherence and publishing**.

## THE STEPS

1. `build_host_zips.sh` — host toolchain from the SAME tree, producing a
   `dart-sdk` whose frontend expects `9e8c898a4d`.
2. `publish_ios_overlay.sh` — publish the full set under ONE engine hash, so the
   CLI resolves a coherent set by construction rather than by hand.
3. Verify all FOUR coherence surfaces share one SDK/tool lineage:
   `Flutter.xcframework` · `gen_snapshot`/`analyze_snapshot` ·
   `flutter_patched_sdk_product` · `dart-sdk`.
4. Verify the lifecycle wiring is present in the SHIPPED artifacts —
   `__patch_boot_lifecycle__`, `ambiguous_boot_retry`,
   `recovered_after_ambiguity`, `retired_after_ambiguity`. The BEFORE engine has
   **zero** occurrences, so this discriminates.
5. Verify published updater provenance really corresponds to `ae1a4849`. The
   mechanical test: the serde-generated `recovered_after_ambiguity` exists in the
   binary, and its source token `RecoveredAfterAmbiguity` is present at
   `ae1a4849` and **absent at `ae1a4849~1`**.

### >>> GATE — before step 6 <<<

> **No provenance stamp may change until the exact published bytes that will
> service release 103 have been FETCHED BACK THROUGH THE NORMAL CONSUMPTION PATH
> and verified coherent.**

Not the build output. Not a hand-placed file. The bytes the CLI actually
downloads and installs. This exists because `compatibility.yaml` was briefly
stamped `updater_revision: ae1a4849` while no engine carrying it was in service —
metadata describing an engine that did not exist. Reverted; the gate stops a
repeat.

6. Update `compatibility.yaml` — `updater_revision` **and** `engine_revision`.
   Provenance, not a version bump.
7. Cut release 103 from **unchanged** fixture source. `lib/main.dart` must hash
   `b284143628441e50543317f5f78ca7da12492aeca81987d29c4a4540589c813f`
   (`sixlaunch_before/FREEZE.txt`); only version metadata may differ.
8. Re-run the **identical** six-launch sequence.
   **Row 5 is the load-bearing before/after.** Everything else is a regression
   control.

## ROW 5 — THE ONLY ROW EXPECTED TO CHANGE

    BEFORE (device-proven):  hard-kill -> next launch retires the patch
                             single-strike; release renders; 0 lifecycle events

    AFTER  (required):       hard-kill -> next launch classifies AMBIGUITY
                             -> ambiguous_boot_retry
                             -> the launch itself succeeds on the PATCH
                             -> recovered_after_ambiguity

Require evidence at all three layers, not just the first:

1. **device/updater state** — ambiguity, then successful recovery;
2. **client wire output** — both outcomes emitted under the same existing
   correlation identity (`client_id` + `app_id` + `release_version` +
   `patch_number`);
3. **server state** — both accepted and represented, **not deduped into one**.
   The two events can land in the same second; that dedupe fix is already in and
   this is its real-device test.

## WHAT IS ALREADY DONE — do not redo

* baseline frozen: `evidence/g15/sixlaunch_before/FREEZE.txt`
* BEFORE engine preserved + hashed: `evidence/g15/engine_lineage/`
* release 102 preserved; App `D06B410E…`, engine `4C4C44C0…`
* hard-kill primitive **device-qualified** (all four veto conditions)
* explicit-vs-inferred distinction **device-proven** — needs no new engine
* mode setter qualified; `rm` -> `put` -> read-back is mandatory
* wiring + telemetry: BUILT, host-tested, 287 updater tests, 299 server tests

## RIG STATE AT HANDOFF

`~/.shorebird` restored to the coherent BEFORE set and verified by a real patch
build. Backups, durable and hash-recorded:

    evidence_preserved/shorebird_ios_release_BEFORE   engine + snapshot tools
    evidence_preserved/shorebird_common_BEFORE        both patched SDKs
    evidence_preserved/build_coherence/               gen_snapshot pair + dill

### DEVICE STATE TRAP — read before launch 1 of the after-run

The device's `Documents/g15_mode` currently reads **`dart-fail`**, left from the
baseline's final launch. **`Documents` survives an install-over** — proven, since
the receipt carried from release 101 to 102 — so installing release 103 does NOT
reset it. Launch 1 of the after-run would throw instead of succeeding, and the
sequence would be scored against the wrong mode.

`--rmtree` of the shorebird state dir does not help either: the mode file lives
under `Documents`, not under `Library/Application Support/shorebird`.

**Set the mode explicitly before launch 1, and confirm by read-back.** Never rely
on the default, and never assume an install cleared it. Same discipline that
caught `afcclient put`'s silent non-overwrite.

**Do not ship the wiring to devices ahead of the telemetry.** That constraint is
unchanged.
