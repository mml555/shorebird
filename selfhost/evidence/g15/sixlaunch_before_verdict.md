# SIX-LAUNCH SEQUENCE — BEFORE RUN (pre-wiring engine), 2026-08-19

Scored against `sixlaunch_precommit.md`, frozen before the first launch.
Specimen: release **102** (`1.2.0+1`), App `D06B410E-9C99-38BD-952E-AD4A345A7908`,
engine `LC_UUID 4C4C44C0-5555-3144-A1DD-7EB2A7564480` — **byte-identical to the
engine preserved as BEFORE** (`engine_lineage/BEFORE_engine.txt`), so the paired
after-run will differ in the engine and nothing else.

## RESULT: 5 VALID rows PASS, 1 BASELINE row as predicted

| # | mode | class | outcome |
|---|---|---|---|
| 1 | `success` | VALID | **PASS** — 4 consecutive patched launches, each `first-frame`, `cur=None count=0 last=1` |
| 2 | `success-then-kill` | VALID | **PASS** — `first-frame` → `success-observed`, breadcrumb already cleared, `queued 0` |
| 3 | `success` | VALID | **PASS** — no ambiguity attributable to launch 2; `queued_events: 0` |
| 4 | `hard-kill` | VALID | **PASS** — all four qualification conditions |
| 5 | `success` | BASELINE | single-strike retirement, **exactly as pre-labelled** |
| 6 | `dart-fail` | VALID | **PASS** — explicit, in-process, 73 ms |

## THE SHIM QUALIFICATION — the veto condition, all four met

    [1] hard-kill-checkpoint:hli6atsp6t persisted     YES
    [2] nothing written after it                      YES (checkpoint IS the last line)
    [2b] no hard-kill-DID-NOT-LAND line               YES — SIGKILL landed
    [3] no explicit failure event queued              YES
    [4] breadcrumb still set                          YES — cur=1, count=1, lastAttempt=1

**The shim models the intended condition.** An uncatchable pre-success
disappearance leaves an unfinished boot and blames nobody. The FFI primitive is
now qualified on DEVICE, not merely on the host.

## THE TWO PRODUCTION PATHS, SEPARATED ON HARDWARE

This is the run's central result, and it does not depend on the engine version:

| | launch 4 — disappearance | launch 6 — explicit Dart failure |
|---|---|---|
| in-process report | **none** | `Reporting failed launch`, **73 ms** after launch start |
| breadcrumb after | **left set** (`cur=1`) | cleared |
| when classified | **next process** | same process |
| event message | `crash_recovery: patch 1 failed to boot (…)` | `engine_report: patch 1 failed to launch` |
| evidence class | **INFERRED** | **EXPLICIT** |

An unreported disappearance and a self-blaming failure enter **different
production paths**, distinguishable on the wire — which is exactly what the
`failure_class` schema work makes queryable instead of prose.

## ROW 5 — BASELINE, NOT A FAILURE

`patch 1: Bad{BootCrash}`, `next_boot_patch: None`, release rendered (`OLD-kill`
confirmed by the operator), `__patch_boot_lifecycle__` events: **0**.

**Pre-labelled BASELINE ONLY before the run.** This engine predates the C3 wiring
(artifact 2026-08-17, wiring 2026-08-19 14:50) and its binary contains zero
occurrences of `__patch_boot_lifecycle__`. The recovery half was *structurally
incapable* of passing here. This is the hardware counterpart of the known
pre-wiring behaviour and **must not be read as evidence against C3.**

The after-run must show, on the same fixture and the same checkpoint:
`ambiguous_boot_retry` → successful launch → `recovered_after_ambiguity`.

## UNEXPECTED OBSERVATION — banked, not brushed past

During the re-arm, ONE PROCESS (pid 12508) ran `main()` twice:

    20:50:15  Patch 1 successfully downloaded. It will be launched when the app next restarts.
    20:50:47  Error initializing updater: Shorebird has already been initialized.
    20:50:47  ApplicationExited / Terminated

A second FlutterEngine was created in a surviving process and shorebird's init
hit its already-initialised guard ~0.7 s before the app exited. **Correlated, not
proven causal** — a force-quit also produces `Terminated`, and this evidence
cannot separate the two.

**It created NO false ambiguity**: `cur=None`, `boot_attempt_count=0`, patch
`Installed`. Adjacent to `multi_engine_false_positive_rollback`, so it is
recorded rather than discarded. Not investigated further in this lane.

## TOOLING DEFECT CAUGHT BEFORE IT COST ANYTHING

`afcclient`'s `put` **does not overwrite an existing file** — it fails silently
and leaves the previous contents. The mode-setter's read-back caught it on the
first transition. Without that check, launches 2-6 would have run in `success`
mode and been scored as results. Fixed with `rm` before `put`, then proven across
four verified transitions in both directions.

**A write that is not read back is not a mode selection.**

## WHAT THIS RUN DOES NOT CLAIM

* NOT that C3 works — this engine cannot run it. Row 5 is baseline only.
* NOT anything about threshold arithmetic; the host suite owns that.
* NOT that the double-`main` exit is a defect; causation is unproven.
* NOT anything about a synchronous `main`, untested here.
* The `dart-fail` hang (white screen, no crash) reproduces arm B's finding: the
  error is forwarded rather than consumed, so the process survives. §15's gate
  wording remains wrong in the same way.
