# Execution identity — RESOLVED: the rejected patch never executed

The open security question from `ARM_C_DEVICE_SIGNATURE.md` is closed. The
outcome is **P1**: on the rejection boot the engine handed the VM **patch 1's**
artifact. Patch 2's bytes never reached execution.

Reproduced from a fresh scenario rather than reasoned from the old one: the
previous device state could not answer the question at all, because patch 1's
artifact had been deleted and patch 2 was tombstoned and skipped, so P1 was not
even a possible outcome there. Release **1.1.0+1** with fresh updater state (app
uninstalled first), patch 1 signed K1, patch 2 signed K2.

## Anchors, recorded BEFORE the rejection boot

    next_boot_patch          : 2
    last_booted_patch        : 1
    currently_booting_patch  : null
    patch 1 : Installed   P1 = 296b988004e6db05366895f77e6e403c82529cec5ffb34f20c57becc883926dc
    patch 2 : Installed   P2 = a23ebb4e4f535d631825b5065793b710fceb98d7a3521227bd17603a1fc3ce17

Both digests equal the server's recorded patch hashes, so the on-disk artifacts
are the published ones.

## The rejection boot, in order

    15:21:13.164  Reporting launch start.                     <-- records next_boot = 2
    15:21:13.165  Verifying patch signature...                    BEFORE validation runs
    15:21:13.176  Patch signature is invalid
    15:21:13.176  Patch 2 failed validation: Patch signature is invalid
    15:21:13.178  Error validating next_boot_patch: Patch signature is invalid
    15:21:13.178  Shorebird updater: active path:
                    …/shorebird_updater/patches/1/dlc.vmcode  <-- SELECTION IS CORRECT
    15:21:13.192  ROUTEB: applied 1/1 targets, entering main
    15:21:13.208  Launch success for patch 2                  <-- ATTRIBUTION IS WRONG

    active path digest = 296b988004e6db05…  ==  P1     (patch 1)
                                          !=  P2     (patch 2)

Rendered: `release: SIGN-REL-1` / `sign state: SIGN-V2` — patch 1's code.

## The verdict on each candidate

| candidate | result |
|---|---|
| **P1** | **CONFIRMED.** Patch 2 never executed. False boot attribution, which then caused destructive cleanup |
| P2 | **EXCLUDED.** The active path digest is P1, not P2, and `SIGN-V3` was never rendered on any launch of either scenario |
| base release | **EXCLUDED.** A patch artifact was selected and applied |

**There is no security defect.** Validation rejects the patch *before* selection,
and selection correctly falls back to the last-known-good patch. The engine is
never handed a `Bad{ValidationFailed}` artifact.

## The real defect, now proven rather than hypothesised

`report_launch_start` records whatever `next_boot_patch` is **at that moment** —
before validation has run. When validation then rejects that patch,
`currently_booting_patch` is never corrected, so `report_launch_success` credits
the rejected patch:

    POST-REJECTION state
      next_boot_patch   : 1
      last_booted_patch : 2          <-- the REJECTED patch
      patches/          : only patches/2/state.json survives
      patch 2           : Bad{ValidationFailed}
      success_diag      : pid=47935 patch=2

`record_boot_success` promotes `currently_booting_patch` to `last_booted_patch`
and then runs `cleanup_older_than(n)` (`lifecycle.rs:633`). With `n = 2`, that
deletes patch 1 — the artifact the fallback depends on. Hence the earlier
observation: a subsequent launch logs *"Patch 1 is not Installed: None"* and drops
to the base release.

So the failure is **not** that cleanup is too eager, and it is not that
`record_boot_success` misbehaves — that function did exactly what its contract
says. The failure is that it was **told the wrong patch succeeded**.

> Launch attribution is not transactionally coupled to validated boot selection.

## What the fix must satisfy, and what it must not be

The invariant:

> the patch recorded as `currently_booting` == the patch whose artifact the
> engine actually boots

Keeping patch N−1 around longer would hide this rather than fix it: the pointer
would still be wrong, `last_booted_patch` would still name a patch that never
booted, and any later reasoning built on that pointer would still be false.

The robust shape is one atomic operation that validates, tombstones, recomputes,
selects, records, and returns the same patch — rather than today's independent
`report_launch_start` → `validate_next_boot_patch` → `next_boot_patch_path`
sequence, where a state change between steps can recreate the same class of
disagreement.

Not implemented here. Choosing between an atomic `prepare_next_boot()` and a
narrower engine-side reordering is a design decision, and the evidence for it is
now complete enough to make that decision deliberately.

## Two crashes, recorded because they were observed

Three by-hand launches in this reproduction ended in a crash before the app
rendered (once during the patch-1 establishment sequence, once on the
patch-2-install tap). In both cases the following launch succeeded and the
lifecycle was undamaged — `patch 1: Installed`, `boot_attempt_count: 0`, no
`Bad{BootCrash}` tombstone — so they did not affect any measurement above. They
are not diagnosed and are not claimed to be harmless in general; they are recorded
because an undiagnosed crash on a signing rig is worth someone's attention.

## Checklist movement

    [x] prove which bytes the rejection process executed  -> P1, patch 2 never ran
    [ ] preserve/restore last-known-good correctly         -> still open, cause now proven
