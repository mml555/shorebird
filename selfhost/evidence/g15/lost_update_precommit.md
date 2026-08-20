# LOST-UPDATE INSTRUMENTATION — PRECOMMIT

Frozen before building. The question is one boundary wide.

## THE CANDIDATE BEING TESTED

> `report_launch_success` decides `WILL_EMIT`, queues the recovery event and saves
> it, but a later whole-file save from a DIFFERENT `UpdaterState` instance — one
> that loaded before the event existed — silently overwrites it.

Established already, so not re-litigated: the device tally reaches 2, the guard
decides `WILL_EMIT`, and the event exists in neither the queue nor the wire
(`observation_run_verdict.md`).

## WHAT IS RECORDED

`state_diag.log`, per `UpdaterState` instance, with `instance_id` assigned at
construction:

    LOAD        instance queue_len fingerprint
    QUEUE_EVENT instance event=Type/Outcome queue_len=before->after fingerprint
    SAVE_BEGIN  instance queue_len fingerprint
    SAVE_END    instance queue_len fingerprint result

`event=` carries the event's OWN identity: a queue that grew by one does not prove
which event it grew by.

## HEISENBUG CONSTRAINTS OBSERVED

* separate file, **outside** the persistence mechanism under investigation;
* opened and closed per line, append-only;
* **no lock taken that state operations take** — adding shared synchronisation
  could serialise the race and make the defect vanish;
* nothing heavier than one append between `QUEUE_EVENT` and `SAVE`.

**Residual risk, stated:** any write changes timing. If the defect stops
reproducing under instrumentation, that is itself informative and must NOT be read
as "fixed".

## THE TRACE CAN EXPRESS THE DEFECT — verified, not assumed

`state_diag_records_a_lost_update_between_instances` constructs the race (two
instances load, A queues, B saves last) and asserts the trace shows two `LOAD`s, a
`QUEUE_EVENT`, at least two `SAVE_END`s, and **a save writing a shorter queue than
a preceding one**. Without that last assertion an absence on device would prove
nothing. 290 tests pass.

## FROZEN ALTERNATIVES

| observation | verdict |
|---|---|
| recovery queued, saved by A, then a stale B save removes it | **lost update between instances CONFIRMED** |
| recovery `QUEUE_EVENT` present but reaches no save | mutation / save plumbing defect |
| recovery saved last and durable state still lacks it | persistence / write defect |
| **no recovery `QUEUE_EVENT` despite `WILL_EMIT`** | gap between classification and `queue_event` |
| single instance only, orderly queue/save, event later absent | **candidate REFUTED — stop and preserve** |
| anything else | stop and preserve; no attribution |

## PROCEDURE

Build -> publish one cell -> fetch-back gate on four surfaces -> producer tooling
published and audited -> release + patch -> **verify both diagnostics are in the
SHIPPED updater** -> device pre-state -> row 4 -> row 5 only -> pull
`state_diag.log` AND `success_diag.log` **before any subsequent launch**.

No semantic change to emission, counters, threshold or guard. Observation only.
