# OBSERVATION BUILD — FREEZE AND FROZEN INTERPRETATION

Banked before the rig mutation. **The interpretation below is fixed now, so the
result cannot be classified after seeing it.**

## THE QUESTION, and it is the only one

> Why did a device recover a patch — `Installed`, `last_booted_patch` set, tally
> cleared, patched value rendering — and report no `recovered_after_ambiguity`?

Three unknowns remain from 2026-08-20: whether `report_launch_success()` ran at all
for pid 19333, what tally it observed, and whether the emission branch executed.

## BUILD INPUTS — what the new cell must contain

    updater   0474e2fc04c2e508f6704a671c28937f032ed9e7   tree clean
    flutter   2c7b8c3ea59253d3cda5a7d3f73ac3fa20f71a9f   only untracked .gcs_entries
                                                         (gclient artifact, NOT a source change)
    dart      9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c
    selfhost  492fc51d7a4e7f2ad36b1fdfc998fd2f04694f9e   tree clean

The engine binary changes because the updater changed, so the cell address changes
and producer tooling must be republished for the new address.

## WHAT THIS BUILD DOES AND DOES NOT CHANGE

**Adds only observation.** `success_diag.log` appended at the success seam, and
`BootSuccess.raw_boot_attempt_count` captured independently — nothing branches on
it. The independence matters: deriving it as `prior + 1` would make the diagnostic
incapable of contradicting the computation under investigation.

**Unchanged:** counter arithmetic · retry threshold · recovery guard · telemetry
emission · host tests. Nothing currently disproves them.

The writer is verified, not assumed —
`success_diag_record_is_written_and_distinguishes_the_two_cases`, mutation-checked
by disabling the writer. So **absence of the file on device means the seam did not
execute**, not that the writer was broken. 289 tests pass.

## FROZEN INTERPRETATION — decided before building

| `success_diag.log` after row 5 | conclusion |
|---|---|
| **absent** | success seam did not execute |
| `raw=1 prior=0 SUPPRESSED` | device lifecycle/state ordering differs from the host model |
| `raw=2 prior=1 WILL_EMIT`, no recovery event | reporting / emission path defect |
| `raw=2 prior=1 WILL_EMIT`, recovery event present | the missing event does not reproduce; the earlier observation remains **unexplained** |
| anything else | **STOP and preserve. No attribution.** |

## RIG STATE AT FREEZE

    cell              ac8d843451f0bb8524932db2bc1fe6ee58c03c0f (wired engine 4C4C447D)
    release           104 / 1.4.0+1, App EEE8AC0F, 5,843 patchable sites
    patch 1           Bad{BootCrash} — never mutated, and must stay that way
    patch 2           Installed, healthy (booted cleanly, last_booted=2, tally 0)
    device g15_mode   success
    server            cps-assets:local-m9, migration 9 applied, dedupe fix live
                      and preflight-PROVEN; rollback container cps-ios-prem9-keep
    compatibility.yaml UNSTAMPED

## PATCH 2 ADMISSIBILITY — criteria frozen, decision deferred

Patch 2 may be reused for the rerun **only if, re-checked at that moment**:

* state `Installed` (not `Bad`, not `Unknown`);
* `boot_attempt_count == 0` and `last_boot_attempt_patch == null`;
* `currently_booting_patch == null`;
* no `__patch_boot_lifecycle__` rows already stored server-side for patch 2 other
  than the single `ambiguous_boot_retry` from the 2026-08-20 run — which must be
  accounted for when reading the rerun, not silently mixed in;
* `g15_mode` set explicitly and verified by read-back.

**Otherwise use a fresh patch identity.** The decision is deliberately NOT made now.

## PROCEDURE

1. build the coherent engine/tool set;
2. publish one new cell through the normal path;
3. fetch back and verify the consumed bytes on all four surfaces;
4. publish and audit matching Route B producer tooling;
5. cut the diagnostic release and patch;
6. **before any device work, mechanically verify `success_diag` is in the SHIPPED
   updater** — the whole run is void otherwise;
7. re-check device pre-state;
8. patch 2 only if it still satisfies the criteria above;
9. run the minimum row-4 -> row-5 sequence only;
10. pull `success_diag.log` **before any subsequent launch**.
