# Tombstone lane — CLOSED instrumentation findings

2026-08-19. Four results from the failed attempt, banked BEFORE the replacement
specimen runs so they stand on their own regardless of what it shows.

## 1. The synchronous-`main` fixture is not manually actionable

Measured from `Reporting launch start` to the Dart-phase outcome, three launches:

    pid 3518   66 ms
    pid 3545   52 ms
    pid 3548   59 ms

Gate 4 banks success at `earliest(main completion, first framework frame)`, and
`void main()` returns synchronously, so the pre-success window is **~50-66 ms**.
A force-quit takes seconds. **No human can act inside that window**, and any
attempt produces only discarded misses.

`gate5_arms_precommit.md`'s "Not under test" section had already recorded the
underlying fact — *"`main` completion always wins the `earliest()`… a fixture
whose `main` never completes would be needed"* — before this attempt proposed a
manual stimulus straight into it.

## 2. Self-SIGKILL is not a valid process-death instrument on this device

`Process.killPid(pid, ProcessSignal.sigkill)` returned control and the process
continued executing Dart, reaching the guard on the next line and throwing
`Bad state: G15: SIGKILL did not terminate the process`.

**The return value was discarded**, so this does NOT distinguish:

* `killPid` returned `false` — the signal was never delivered (ordinary); from
* `killPid` returned `true` — a delivered signal 9 failed to terminate (a much
  stranger platform finding).

Either way the arm delivers a **Dart-phase exception**, not a process death, and
those exercise different retirement paths. The arm is disqualified as an input
generator until it records that boolean.

## 3. Syslog lifecycle logging — CORRECTED 2026-08-19

**The original claim here was wrong and is retracted.** It read: *"'Reporting
successful launch' NEVER appears (0 occurrences) … syslog can prove a failure but
cannot prove a success."*

That was inferred from `run3.log`, where zero success lines appeared. `run4.log`
records **nine**:

    "[shorebird] Reporting launch start."      11 occurrences
    "[shorebird] Reporting successful launch."  9 occurrences
    "[shorebird] Reporting failed launch."      (present in run3)

Both seams log. The absence in `run3` reflects which banking condition fired
under that fixture shape, not a missing log call.

**What stands:** `pointers.json` remains the authoritative success witness, and
the engine's reporting seam must not be modified during a lifecycle experiment.
Both were correct for the wrong reason; they are still correct.

## 4. Device state churns faster than memory of it

Syslog recorded **seven** launch starts across the session where two taps were
scored — five unaccounted launches inside ~25 seconds
(00:12:08 → 00:12:31), three of them failing.

**Consequence, now a standing rule for this lane:** device state must be
MEASURED immediately before a scored transition, never carried forward from the
last remembered capture.

## What survives from the accidental run, unscored

A healthy replacement attached (`rc=0`, `bc_post=1`, `TPOOL_UNIQUE` idx 4211,
`NEW-kill` on screen); Dart startup then failed; the updater produced
`Bad{BootCrash}` with the expected `engine_report` event; and the process did not
automatically exit or recover. Corroboration only — see
`tombstone_lane_S2_verdict.md`.
