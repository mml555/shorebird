# SIX-LAUNCH DETERMINISTIC SEQUENCE — PRECOMMIT

2026-08-19, written **before** the first launch and before Xcode signing was
restored. Scores the four-mode harness against the real device seams.

## THE AMENDMENT THAT MATTERS MOST

> **The shipped engine cannot exercise the recovery policy. On the BEFORE
> specimen the recovery half is STRUCTURALLY INCAPABLE of passing, and a
> single-strike retirement at launch 5 is the CORRECT baseline observation — not
> a failed test, and not evidence against C3.**

Measured, not inferred (`engine_lineage/BEFORE_engine.txt`):

| fact | value |
|---|---|
| engine in release 101 | cell `mintstage_0013`, arm64 `LC_UUID 4C4C44C0-…-7EB2A7564480` |
| `__patch_boot_lifecycle__` in that binary | **0 occurrences** |
| `"did not record success; retrying"` | 1 occurrence — `0010` compiled in |
| C3 wiring commit | 2026-08-19 14:50 — **postdates** the 2026-08-17 artifact |

So the threshold code is present but unreachable, and the telemetry does not
exist in the binary at all. Anyone reading the before result later must read it
as the hardware counterpart of the known pre-wiring behaviour.

## EVIDENCE CLASSES — PRE-LABELLED

| # | mode | class |
|---|---|---|
| 1 | `success` | **VALID** — real success seam clears boot state |
| 2 | `success-then-kill` | **VALID** — death only after success is persisted |
| 3 | `success` | **VALID** — proves launch 2 created no ambiguity |
| 4 | `hard-kill` | **VALID** — unfinished boot, no explicit failure report |
| 5 | `success` | **BASELINE ONLY** — old-engine classification of launch 4. **NOT a test of the new wiring.** |
| 6 | `dart-fail` | **VALID** — explicit in-process failure, terminal; last because it retires the patch |

## SHIM QUALIFICATION — RUN FIRST, AND IT CAN VETO EVERYTHING AFTER

From launch 4, all four required:

* `hard-kill-checkpoint:<launchId>` present in the receipt;
* **no** line after it — in particular no `hard-kill-DID-NOT-LAND`;
* **no** explicit launch-failure event queued;
* breadcrumb (`currently_booting_patch`) still set.

**If an explicit failure event appears, the shim is not modelling the condition
it claims to** and every hard-kill result in this run and the next is measuring
something else. Stop and re-qualify rather than score.

Host pre-qualification already done: identical FFI lookup exits 137 (128+9) and
never reaches the line after the call.

## PRE-STATE — ESTABLISHED MECHANICALLY, NEVER INFERRED

Before launch 1, capture and assert: release/patch identity (App LC_UUID against
the preserved release); patch `Installed`; `currently_booting_patch: null`;
`boot_attempt_count: 0`; `queued_events: []`; and the exact contents of
`Documents/g15_mode`. **No value carried over from a previous run.**

State is captured with the qualified `afcclient` path after EVERY launch, before
`g15_mode` is changed.

## FROZEN EXPECTATIONS

| launch | receipt | state |
|---|---|---|
| 1 | `mode:success` → `first-frame` | breadcrumb cleared, `last_booted_patch` set, tally 0 |
| 2 | `mode:successThenKill` → `first-frame` → `success-observed` | breadcrumb cleared **before** the kill |
| 3 | `mode:success` → `first-frame` | no ambiguity attributable to launch 2, tally 0 |
| 4 | `mode:hardKill` → `hard-kill-checkpoint`, nothing after | breadcrumb SET, no failure event |
| 5 BEFORE | `mode:success`, patch retired so the RELEASE runs | patch `Bad{BootCrash}`, `PatchInstallFailure` queued |
| 5 AFTER | `mode:success` → `first-frame` on the PATCH | `ambiguous_boot_retry` then `recovered_after_ambiguity` |
| 6 | `mode:dartFail`, no `first-frame` | explicit failure, terminal, distinct from 4's inferred path |

Row 5 is the only row that differs between engines, and that is the entire point
of running the sequence twice.

## WHAT THE PAIRED RUN WILL AND WILL NOT SHOW

Same checkpoint, same fixture source, same observation method, same device.
**Only the engine changes.** That makes the row-5 difference attributable to the
wiring rather than to fixture or device conditions.

It will NOT show: anything about threshold arithmetic (host suite owns that);
anything about non-boot-phase crashes; anything about a synchronous `main`.

## BLOCKED ON

Xcode account session for team `SK85S6YZP9`. `CODE_SIGN_STYLE = Automatic` with
no account yields `exportArchive No Accounts`, so release 102 cannot be built.
**Not to be worked around** with manual profiles or altered signing settings —
that would change the specimen to dodge an environment problem.
