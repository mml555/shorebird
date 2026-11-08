# LOST UPDATE — CONFIRMED, and the code documents the window as an accepted trade-off

Scored against `lost_update_precommit.md`, frozen before the build.
**Verdict: row 1 — lost update between updater instances CONFIRMED.**

## THE TRACE, row 5, pid 20042

    tid=1 LOAD        inst=1 queue_len=0 fp=6594876a
    tid=1 QUEUE_EVENT inst=1 event=PatchBootLifecycle/Some(AmbiguousBootRetry)      0->1  fp=d3e31910
    tid=1 SAVE_END    inst=1 queue_len=1 fp=d3e31910 result=ok
    tid=2 LOAD        inst=5 queue_len=1 fp=d3e31910          <- flusher READS: one event
    tid=1 LOAD        inst=6 queue_len=1 fp=d3e31910
    tid=1 QUEUE_EVENT inst=6 event=PatchBootLifecycle/Some(RecoveredAfterAmbiguity) 1->2  fp=f699fd15
    tid=1 SAVE_END    inst=6 queue_len=2 fp=f699fd15 result=ok
    tid=2 LOAD        inst=7 queue_len=2 fp=f699fd15          <- sees BOTH
    tid=2 SAVE_BEGIN  inst=7 queue_len=0 fp=6594876a          <- writes ZERO
    tid=2 SAVE_END    inst=7 queue_len=0 fp=6594876a result=ok

Durable state afterwards: `queued_events: 0`. Server received **only**
`ambiguous_boot_retry` (row id 143). `success_diag` for the same pid:
`raw_boot_attempt=2 prior_ambiguous_attempts=1 recovery_event_decision=WILL_EMIT`.

## THE MECHANISM, exactly

`updater.rs` around line 466:

    let events = with_state(|state| Ok(state.copy_events(3)))?;   // READ (inst 5): 1 event
    for event in events { send_patch_event(event, &config) }      // SEND: that 1 event
    with_mut_state(|state| {
        // This will clear any events which got queued between the time we
        // loaded the state now, but that's OK for now.
        state.clear_events();                                     // CLEAR (inst 7): ALL events
    })

**The flusher sends what an earlier read captured and then clears everything.** Any
event queued between the read and the clear is destroyed without ever being sent.
`clear_events()` is `queued_events.clear()` + `save()` — a whole-queue wipe, not a
removal of the events actually transmitted.

**The window is acknowledged in the source**: *"This will clear any events which got
queued between the time we loaded the state now, but that's OK for now."* So this is
a KNOWN trade-off, not an accident — and it was defensible while queued events were
coarse install/download counters where one lost sample did not matter.

**It is not defensible for the lifecycle events.** `recovered_after_ambiguity` is
queued at `report_launch_success`, which lands squarely inside that window, and it is
the NUMERATOR of `P(recovery | first ambiguity)`. Losing it does not blur a
statistic; it drives the measured recovery rate toward zero while the denominator
(`ambiguous_boot_retry`, queued earlier at init, before the read) survives.

**It also explains the intermittency exactly.** Whether the recovery survives depends
on whether it is queued before the flusher's read or between its read and its clear.
Patch 1 in the 2026-08-20 AFTER run emitted its recovery; patch 2 and this run did
not. A race is exactly that.

## WHY THE PREDICTED SHAPE WAS SLIGHTLY WRONG

The precommit's leading candidate was a **stale snapshot** — instance B loading
before the event existed. The trace refutes that specific shape: instance 7 loaded
`queue_len=2` and saw both events. The lost update is real, but it happens because
the clear is derived from an EARLIER read (instance 5), not because the writer's own
load was stale. Recorded because the distinction changes the fix: guarding on
"reload before save" would not help; the flusher must remove only what it sent.

## SCORING, and the other rows

Row 1 of the frozen table. Not row 4 (`QUEUE_EVENT` is present), not row 5
(multiple instances, and the final save is not orderly), not row 3 (the recovery
never reached a save that survived), not the REFUTED row.

## INSTRUMENTATION DID NOT MASK THE DEFECT

The Heisenbug risk was recorded in advance. It did not materialise: the defect
reproduced on the first instrumented attempt, and the trace is what localised it.

## WHAT WAS VERIFIED BEFORE THE DEVICE WAS TOUCHED

cell `70e12f1af5a1bec63a3621c0032e3c94500057df` — four-surface fetch-back gate passed
(engine `4C4C4408`, both diagnostics present in the FETCHED engine, product SDK and
dart-sdk at `9e8c898a4d`); producer tooling **AUDIT CLEAN**; both diagnostics
confirmed in the SHIPPED app engine; release 106 / `1.6.0+1` verified **PATCHABLE,
5,843 sites** with artifacts warmed first; fresh identity by construction; fixture
`main.dart` digest identical to the freeze; updater state wiped so no prior
diagnostic could masquerade as current (`LU_pre` shows both logs ABSENT).

Raw logs were pulled and preserved BEFORE any interpretation, and before any further
launch.

## THE FIX — not applied here

`clear_events()` must remove **only the events that were actually sent**, not the
whole queue. Options, in preference order:

1. drain-and-send atomically: take the events out under one load/save, send, and
   re-queue any that failed;
2. remove-by-identity: after sending, delete exactly those events (dedupe key or a
   per-event id), leaving anything queued since untouched.

Either way the regression test is behavioural: **an event queued between the
flusher's read and its clear must still be sent.** The existing
`state_diag_records_a_lost_update_between_instances` provides the shape; the new test
should drive the real flush path.

Note `copy_events(3)` also caps a flush at three events; not the defect here, but it
means a burst can defer events indefinitely and should be looked at with the fix.

## STATE

* cell `70e12f1a…` in service; `f8654294…` and `ac8d8434…` intact.
* release 106 / `1.6.0+1`, App `F747290F`, engine `4C4C4408`, patch 1 `Installed`.
* device: `g15_mode = success`, patch healthy, `last=1`, tally 0.
* `compatibility.yaml` still **unstamped** — the client still cannot be trusted to
  report a recovery it decided to emit.
