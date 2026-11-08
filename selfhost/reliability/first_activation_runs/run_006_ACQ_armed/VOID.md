# VOID — armed under a mistaken premise, never used for an observation

Armed as an **acquisition** run for generation 006. Its own `pre_state` then showed
`next_boot_patch=5` with patches 4 and 5 both present — i.e. the acquisition had
**already happened**, so a launch here would have been a FIRST ACTIVATION recorded
under an acquisition label.

## What actually happened, from this run's own pre_state

    01:33:59  pid 50643  terminated (run_006, classified G)
    01:39:51  pid 50736  PROCESS_BEGIN            <-- UNOBSERVED launch
              ran patch 4 (success_diag pid=50736 patch=4)
              server: __patch_download__ patch=5 at ts 1787881191 (01:39:51)
    01:43:43  pid 50736  UIAPP_WILL_TERMINATE     <-- orderly termination again

That launch fell between the run_006 collection and this arm, so it has no armed
capture. It is the second consecutive orderly `WILL_TERMINATE` on this device,
which strengthens the ordinary-memory-pressure reading of run_006 rather than the
historical phenomenon.

## Why this folder is kept rather than deleted

Nothing was observed through it, so deleting it would cost nothing evidentially —
but the audit trail of *what was armed and why it was abandoned* is worth more than
a tidy directory. Runs are immutable; a voided run stays voided.

Superseded by `run_006_A_first_activation`.
