# OBSERVATION RUN — the tally is CORRECT on device; the defect is in the emission path

Scored against `observation_build_precommit.md`, whose interpretation table was
frozen before the build. **Result: row 3 — reporting / emission path defect.**

## THE DECISIVE RECORD

`success_diag.log`, pulled before any subsequent launch:

    pid=19702 patch=1 raw_boot_attempt=1 prior_ambiguous_attempts=0 recovery_event_decision=SUPPRESSED
    pid=19765 patch=1 raw_boot_attempt=2 prior_ambiguous_attempts=1 recovery_event_decision=WILL_EMIT

Line 1 is the **on-device control** (clean patched boot). Line 2 is row 5.

| layer | result |
|---|---|
| device tally | **raw=2, prior=1** — exactly what the host model predicts |
| guard decision | **WILL_EMIT** |
| client queue after row 5 | **0 events** |
| server | `ambiguous_boot_retry` stored (id 140, attempts=1); **`recovered_after_ambiguity` ABSENT** |

**So the tally and the guard are exonerated on real hardware.** The event was decided
on, and never reached the queue or the wire.

## WHAT THIS ELIMINATES

* `count - 1` arithmetic — measured correct on device, not just on host;
* device lifecycle/state ordering — `raw=2` proves `record_boot_start` incremented
  over the retained tally exactly as modelled;
* the success seam not executing — it executed and wrote its record;
* server-side dedupe — the fix is deployed and preflight-proven, and in any case
  nothing arrived to be deduped;
* observation-specific loss in a huge syslog — this run used a fresh capture and
  the durable file agrees with it.

## THE DEFECT, LOCATED

Between `recovery_event_decision=WILL_EMIT` and the event existing anywhere.

The code path has no early return between the two:

    if success.prior_ambiguous_attempts > 0 {
        state.queue_event(PatchEvent::boot_lifecycle(...))?;   // saves state.json
    }

`queue_event` persists immediately, so a queued event should survive. It did not.

### CANDIDATE MECHANISM — labelled as such, not concluded

**A lost update between concurrent `UpdaterState` instances.** `report_launch_success`
loads its own `UpdaterState`; the update thread started at init holds another. Both
write the whole `state.json`. If the update thread saves after the success path
queued its event, last-writer-wins silently discards it.

Consistent with everything observed:

* the retry event was queued during **init**, before the update thread's own writes,
  and it survived and was sent;
* the recovery event is queued at **success**, concurrent with or after the update
  thread's activity, and vanished;
* **it explains the intermittency** — patch 1 in the 2026-08-20 AFTER run DID emit
  its recovery, and a race is exactly the kind of thing that succeeds sometimes.

**Not proven.** What would settle it: log the queue length immediately after
`queue_event`, and log every `UpdaterState::save` with its instance identity and
queue length. If a save with a shorter queue follows the success-path save, the race
is confirmed.

## WHAT WAS ALREADY VERIFIED THIS RUN, before the device was touched

* four-surface fetch-back gate on cell `f8654294c253a132ae5da9e38ddf9aa85d6a257e`;
* producer tooling published and **AUDIT CLEAN**, including "served platform dill is
  the one the address was computed over";
* the shipped app's engine contains `prior_ambiguous_attempts`, `success_diag.log`
  and `recovery_event_decision` — the run would have been void otherwise;
* release 105 verified **PATCHABLE, 5,843 sites**, with artifacts warmed first so the
  `isRouteBEngine` cold-cache defect could not silence them;
* fresh patch identity by construction (new release), so the patch-2 admissibility
  question did not arise;
* fixture `main.dart` digest identical to the freeze.

## A MISTAKE OF MINE, AND WHY THE CONTROL MATTERED

`capture.sh` reported `success_diag: ABSENT` for the prime AND control launches. That
was **my path bug** — `storage_dir` on device is the `shorebird_updater` directory and
my edit stripped that suffix. Probing all three candidate paths found the file with
the correct control line.

Had I not insisted on an on-device control line before row 5, an `ABSENT` at row 5
would have been read as "the seam did not execute" — the wrong row of the frozen
table, from my own bug. **The control is what made absence interpretable.**

## STATE

* cell `f8654294…` published, audited, in service; previous cell `ac8d8434…` intact.
* release 105 / `1.5.0+1`, App `2B1851FF`, engine `4C4C442E`, patch 1 `Installed`.
* device: `g15_mode = success`, patch 1 healthy, `last=1`, tally 0.
* server: `cps-assets:local-m9`, dedupe fix live.
* `compatibility.yaml` still **unstamped**.

## NEXT — one narrow step

Instrument `queue_event` / `save` as above and re-run **only row 4 -> row 5**. Do not
change emission semantics until the race is either confirmed or excluded.
