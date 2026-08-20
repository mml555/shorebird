# SIX-LAUNCH AFTER-RUN — row 5 PROVEN on device and wire; server layer blocked by an undeployed fix

Scored against `sixlaunch_precommit.md`, frozen before the BEFORE run and unchanged
since. Same fixture source (`main.dart` sha256 `b284143628441e50…`, identical to the
freeze), same checkpoints, same FFI SIGKILL primitive, same `afcclient` observer,
same scoring rules. **Only the engine changed.**

    BEFORE  release 102  engine 4C4C44C0  (no wiring, 0 lifecycle strings)
    AFTER   release 104  engine 4C4C447D  (wired, 4 lifecycle strings), cell ac8d8434
                         5,843 patchable sites — verified before the run

## THE PAIRED COMPARISON — row 5 is the only row that changed

| # | mode | BEFORE (release 102) | AFTER (release 104) |
|---|---|---|---|
| 1 | `success` | patch boots, state clean | **same** — `last=1`, `count=0`, **0 events** |
| 2 | `success-then-kill` | `success-observed`, breadcrumb already clear | **same** |
| 3 | `success` | no ambiguity from #2 | **same** — 0 events across 1-3 |
| 4 | `hard-kill` | breadcrumb SET, no explicit failure | **same** — `cur=1 count=1`, 0 events |
| **5** | `success` | **patch RETIRED single-strike; release rendered (`OLD-kill`)** | **patch SURVIVES; patch boots (`NEW-kill`); `recovered_after_ambiguity`** |
| 6 | `dart-fail` | explicit, terminal, immediate | **same** — `Bad{BootCrash}`, `engine_report:` |

Rows 1-4 and 6 are stable controls. **Row 5 flipped, and only the engine differed.**

## ROW 5 — three layers

### LAYER 1 · device / updater — PASS

    patch 1            Installed        <- survived the ambiguous death, NOT Bad
    last_booted_patch  1                <- the PATCH booted successfully
    breadcrumb (cur)   None             <- cleared by success
    boot_attempt_count 0                <- tally reset by success

Operator observed **`NEW-kill`** — the patch, not the release. On the BEFORE engine
the same sequence rendered `OLD-kill` off a `Bad{BootCrash}` patch.

### LAYER 2 · client wire — PASS

    __patch_boot_lifecycle__
      outcome                 = recovered_after_ambiguity
      ambiguous_attempt_count = 1
      boot_failure_threshold  = 2
      patch_number            = 1

and, earlier in the same launch, `outcome = ambiguous_boot_retry`. Both emitted
under the existing correlation identity — no new identifier.

### LAYER 3 · server — **FAILS, by the bug already fixed in source but not deployed**

    stored: id=126  __patch_boot_lifecycle__  outcome=ambiguous_boot_retry
    absent: recovered_after_ambiguity

The server log shows it arrived and was discarded:

    "outcome": "recovered_after_ambiguity",
    duplicate event ignored
    POST /api/v1/patches/events -> 204

**Cause is exactly the collision found and fixed on 2026-08-19.** The deployed
container predates that fix: its `dedupe_key` is
`client|app|release|patch|type|timestamp` with **no `outcome`**, verified directly
on the stored row, and `SELECT ... outcome` fails with *no such column* — migration
9 is not applied either.

Both lifecycle events for one patch landed in the **same second** of launch 5
(retry at init, recovery at success), so their keys were identical and the recovery
was dropped.

> **The predicted harm occurred on real hardware: `P(recovery | first ambiguity)`
> was driven to zero by deduplication, on the very run that produced the first real
> recovery.** Had the fix been deployed, this is the row that would have proved the
> metric works.

The client is correct; the fix is written, tested (299 server tests) and committed.
**It is simply not running.** Deploying it requires rebuilding the `cps-ios` image —
a shared-rig change, deliberately not done here.

## WHAT THIS ESTABLISHES

> **C3 and C4 are now device-PROVEN at the device and client layers.** A
> deterministic, uncatchable pre-success disappearance is classified as AMBIGUOUS,
> the healthy patch is retried rather than retired, the next launch boots the patch,
> and the client reports `recovered_after_ambiguity` with the ambiguity that
> preceded it.

Combined with the BEFORE run, the wiring — not any fixture or device condition — is
what changed the outcome: one variable, paired runs, five stable controls.

## WHAT THIS DOES NOT CLAIM

* NOT that the server-side metric works end to end. Layer 3 is unproven and
  currently BROKEN on the deployed container.
* NOT that the threshold value 2 is ratified — that still needs fleet data, which
  needs layer 3.
* NOT anything about a synchronous `main`, or a throw after `runApp()`.
* The `dart-fail` hang (white screen, no crash) reproduces arm B again: the error is
  forwarded rather than consumed, so §15's "crash" wording remains wrong.

## NEXT, in order

1. **Deploy the server fix** (dedupe `outcome` + migration 9), then re-run rows 4-5
   only, to close layer 3.
2. Fix `isRouteBEngine()`'s cold-cache false negative, with a behavioural regression
   test that starts with the engine artifact absent: **absence = unknown, never
   "not Route B"**, and a release must not escape unverified merely because
   detection could not complete.
3. Ratify or revise the threshold from fleet data.

## RIG STATE

On cell `ac8d8434` with the wired engine. Release 104 and patch 1 preserved.
Device holds `g15_mode = dart-fail` from launch 6 and patch 1 is
`Bad{BootCrash}` — both expected, and both must be reset before any re-run.
`compatibility.yaml` still unstamped.
