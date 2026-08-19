# Patch lifecycle policy — the product contract

2026-08-19. **This file is the contract. Code conforms to it, not the reverse.**

Written because the investigation method that found the mechanisms became the
wrong method for validating behaviour. The question is no longer *"can we
reproduce this device state?"* but *"what do we guarantee, and how do we know?"*

## 0. THE PRINCIPLE THE WHOLE POLICY RESTS ON

> **An explicit failure report and a process that merely disappeared are not
> equally strong evidence, and must never produce the same action.**

An explicit Dart error 37 ms into startup is strong evidence against the patch.
A watchdog kill, jetsam, a phone reboot, a user swipe, a harness timeout or a
freak termination is not evidence against the patch **at all** — it is evidence
that something ended the process, which patches do not have a monopoly on.

The two error directions are asymmetric, and this asymmetry is why the policy is
shaped the way it is:

| error | cost |
|---|---|
| retire too LATE | one more crashed launch on a device already crashing; **self-corrects** |
| retire too EARLY | a **working** patch permanently tombstoned on that device, invisibly, and reported as the safety mechanism working correctly |

**The cheap error is to retry. The expensive error is to tombstone.**

## 1. THE CONTRACT — four rows, and nothing else

| # | situation | REQUIRED behaviour |
|---|---|---|
| **C1** | patch reaches the success boundary | stay `Installed`. **Later ordinary exits, however violent, must not affect it.** |
| **C2** | patched Dart explicitly fails during startup | retire **immediately**, single strike. Next launch runs the release. |
| **C3** | process disappears before success, **no** explicit failure report | **ambiguous.** Retry. **Never** treat as proof the patch is bad. |
| **C4** | repeated ambiguous pre-success deaths | retire under an **explicitly chosen** threshold policy |

C3 is the row that matters. Everything else is comparatively easy.

## 2. STATUS AGAINST THE CONTRACT — measured, not assumed

| row | implemented? | where | device-proven? |
|---|---|---|---|
| C1 | **yes** | `record_boot_success` clears breadcrumb + tally; a later kill leaves nothing for `detect_boot_crash_on_init` to find | **yes**, twice — `arm2_verdict.txt` |
| C2 | **yes** | `report_launch_failure()` → `mark_bad` immediately | **yes** — `armB_crash_backout_verdict.txt`, 2026-08-19 |
| C3 | **yes** | `0010`: below threshold, clear ONLY the breadcrumb and retry | **NO** — never exercised deterministically |
| C4 | **yes**, threshold = 2 | `BOOT_FAILURE_THRESHOLD` in `0010` | **NO** |

**The policy is largely already built.** That was not obvious and was nearly
missed: `0010-g15-boot-attempt-threshold.patch` implements exactly this split,
and its own doc comment already contains the asymmetry argument above.

### WHICH TREE TO READ — this trap has now cost time twice

    AUTHORITATIVE (builds the device engine):
      /Volumes/build/route-b/flutter/engine/src/flutter/third_party/updater/
        library/src/cache/lifecycle.rs
      -> BOOT_FAILURE_THRESHOLD: u32 = 2      line 187
      -> pub boot_attempt_count: u32          line 164
      -> the retry branch                     line 659

    PINNED UPSTREAM COPY — has none of the above:
      vendor/updater/library/src/cache/lifecycle.rs

Reading the pinned copy and concluding from its absence produced a confident,
wrong "both retirement paths are single-strike" on 2026-08-19, corrected the same
day. **An absence claim about updater behaviour is only valid against the
`third_party/updater` tree in the engine checkout.** The device's own
`pointers.json` is the ground truth about which code ran: it carries
`boot_attempt_count`, which exists only because `0010` added it.

### The two paths, stated once

| path | trigger | evidence strength | policy |
|---|---|---|---|
| `report_launch_failure()` | Dart seam / engine **blames the patch** | strong | **single strike** |
| `detect_boot_crash_on_init()` | breadcrumb still set at next init | **weak — absence of evidence** | **threshold 2** |

## 3. THE THRESHOLD IS A PRODUCT DECISION, AND IT IS NOT YET RATIFIED

`BOOT_FAILURE_THRESHOLD = 2` is currently an engineering inference living in a
patch-file comment. Its reasoning is sound — *"2 is the smallest value that
discriminates at all, and costs exactly one extra crash in the genuine-failure
case"* — but **soundness is not ratification.**

Ratify it, change it, or add conditions deliberately. Specifically decide:

* **is 2 right**, given C4's cost is one extra crashed launch?
* **should the tally decay with time?** Today it is purely consecutive-since-last-
  success. Two ambiguous deaths a month apart count the same as two in a row.
* **should `boot_started_at` age gate it?** A death 40 ms in and a death 40 s in
  are not equally suspicious, and the timestamp is already recorded.
* **should repeated ambiguity be reported before it retires?** Today the control
  plane learns only at retirement.

Until ratified, the threshold is **BUILT, not contracted.**

## 4. KNOWN GAPS AGAINST THIS CONTRACT

1. **Classification is not in the event schema.** Both paths queue the same
   `EventType::PatchInstallFailure`, distinguished only by a free-text prefix
   (`engine_report:` vs `crash_recovery:`). The control plane cannot separate
   "the patch blamed itself" from "we inferred it" without string-parsing.
   **Fix: put the class in the schema.** This directly serves C3 — a fleet-level
   view of ambiguous-vs-explicit is how the threshold gets ratified with data.
2. **One hung launch per bad patch.** C2 retires the patch, but backout takes
   effect on the NEXT launch, so the user eats one white-screen launch they must
   force-quit by hand. See `armB_crash_backout_verdict.txt`.
3. **A Dart-phase failure does not crash.** `hooks.dart:492` forwards the error
   rather than consuming it — deliberately, so the app's own reporting survives —
   and an uncaught root-zone error on iOS logs and continues. §15's gate says
   *"a Dart-phase **crash** backs the patch out"*; the word is wrong. **Correct
   the wording rather than marking the gate closed.**
4. **C3 and C4 have no deterministic test at any level.**
5. **Synchronous `main`** takes `hooks.dart:476`'s `catch`/`rethrow`, not the
   `onError` path arm B measured. Untested.

## 5. HOW THIS GETS PROVEN — three layers, smallest device surface possible

The device must stop being used to test signal generation **and** policy at the
same time. Split them.

### Layer 1 — host state machine, exhaustive, no device

The updater consumes a small conceptual alphabet:

    boot_started(patch)
    launch_succeeded(patch)
    launch_failed_explicitly(patch, reason)
    next_process_started()
    (implicit) previous boot began, produced neither success nor explicit failure

Hundreds of transitions can run deterministically on the host. This is where C1-C4
are actually **proven**, including sequences no device test would ever reach:
ambiguity interleaved with success, target changes mid-tally, threshold boundaries
off by one, tally inheritance across patches.

### Layer 2 — deterministic fixture harness, on device, no human timing

A launch mode selected **before** startup:

| mode | behaviour |
|---|---|
| `success` | normal patch, reaches the success boundary |
| `dart-fail` | throw from patched Dart before `runApp()` |
| `hard-kill` | terminate the process at a precise pre-success checkpoint |
| `success-then-kill` | reach success, then terminate |

`hard-kill` is the crucial one, and it must be a **test-only native**
`kill(getpid(), SIGKILL)` at an exact checkpoint — **not** Dart's `Process.killPid`,
which already failed as an experimental primitive: it returns a bool the fixture
discarded, making an undelivered signal indistinguishable from an ignored one.

SIGKILL is uncatchable, so there is no graceful cleanup and no Dart failure
report. **From the state machine's perspective the origin of the SIGKILL is
irrelevant** — which is exactly why it is a valid stand-in for watchdog, jetsam
and user swipe.

This removes every variable the manual method introduced: human timing, debugger
behaviour, launch tooling, USB state, lifecycle timing, file-copy side effects,
device scheduling. **The effort spent qualifying `afcclient` was itself evidence
that the harness had begun to dominate the experiment.** `afcclient` remains
useful — as the non-booting observer, which is what it was qualified for.

### Layer 3 — device conformance, a few specimens only

One question, and only this one:

> **Do the real Dart and native seams emit the state-machine events we believe
> they emit?**

Arm B is already one such specimen: `dart-fail` → Dart seam reports failure →
`Bad` → event reaches the control plane → next launch runs the release.

## 6. WHAT IS EXPLICITLY NOT WORTH DOING

**No further manual tombstone experiments.** Attempting to kill an iPhone by hand
inside a ~60 ms window is not validation; it introduces precisely the variables
the policy is trying to reason about. The pre-success termination rows are parked
as unmeasurable **by that method**, and the harness above is how they get answered
instead.

## 7. ORDER OF WORK

1. **Ratify §3** — the threshold and its conditions. Product decision, blocks nothing else.
2. **Layer 1** — host state-machine suite for C1-C4. Cheapest, highest coverage, no device.
3. **Classification in the event schema** (§4.1) — small, and it is what makes §3 ratifiable with fleet data rather than argument.
4. **Layer 2** — the four-mode fixture harness.
5. **Layer 3** — the handful of conformance specimens.
6. **Correct §15's gate wording** (§4.3).
