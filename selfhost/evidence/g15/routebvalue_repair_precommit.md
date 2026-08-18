# `routeBValue` REPAIR — mechanism confirmation, PRECOMMIT

2026-08-17, **before the fixture is edited and before any build.**
Confirms on the target that drove the whole investigation what
`foldability_verdict.txt` isolated on a synthetic pair.

## SCORING RULE, settled BEFORE the run

`gate5_arms_precommit.md` was read first. **It contains NO provision for fixture
repair** — its arm A row requires *"receipt reaches `first-frame`; screen shows
`NEW-kill`; `pointers.json` has `last_booted_patch: 1`, `boot_attempt_count: 0`,
`queued_events: []`"* and says nothing about changing the release body.

Therefore, and deliberately:

* **ORIGINAL ARM A REMAINS INCONCLUSIVE.** It is not re-scored, not rewritten,
  and not retroactively passed by this run. Changing the release body produces a
  REPAIRED OBSERVATION SPECIMEN, not the specimen arm A was precommitted against.
* **This run is scored as arm A's CONFIRMING SUCCESSOR**, in its own file, under
  the mechanism question — not under `gate5_arms_precommit.md`'s table.
* **Mechanism confirmation does not require arm A's PASS**, and arm A's PASS is
  not claimed by it.

## THE CHANGE — one body, one line, nothing else

    // release, BEFORE (foldable constant — the failing shape)
    String routeBValue() => 'OLD-kill';

    // release, AFTER (the established opaque guard)
    String routeBValue() => DateTime.now().millisecondsSinceEpoch == -1
        ? 'UNREACHABLE-KILL'
        : 'OLD-kill';

    // patch (unchanged intent: NEW-kill)
    String routeBValue() => DateTime.now().millisecondsSinceEpoch == -1
        ? 'UNREACHABLE-KILL-PATCH'
        : 'NEW-kill';

Held constant, all of it: the target's NAME, its signature, its caller
(`build()` at the same site), its display row, its release-visible baseline
`OLD-kill`, the patch's `NEW-kill`, the absence of pragmas (killswitch has none
and gains none), and the entire boot/killswitch/alternation/receipt machinery.

**Only the release-side observation channel changes** — whether the release's
call to `routeBValue` survives compilation.

## THE STATIC DISCRIMINATOR — required BEFORE the device run

This is what made the paired control load-bearing and it is not optional here.

    BEFORE (release 95/96): assert_result_consumed.sh --symbol routeBValue
                            -> NOT LOCATED (0 call sites)
    AFTER  (this release):  MUST report a SURVIVING, CONSUMED call site

**If the repaired release still shows NO surviving call site, the repair did not
take** and the run is reported as unrun rather than scored. A screen collected
without this check would not distinguish "the repair worked" from "something else
changed".

## THE CAUSAL CHAIN UNDER TEST

    foldable release body -> call eliminated/substituted -> target ABSENT
                          -> attach succeeds -> OLD value remains
    opaque   release body -> call survives/CONSUMED      -> target UNIQUE
                          -> attach succeeds -> PATCHED value renders

The first line is already measured, twice: on `foldConst` (deliberately) and on
`routeBValue` itself (release 96: `TPOOL_ABSENT`, `rc=0`, `OLD-kill`). This run
tests the second line **on the same target**, which converts a correlation across
specimens into a repair-and-restore on one.

## OUTCOME TABLE, precommitted

| observation | verdict |
|---|---|
| static shows a CONSUMED call site; attach `rc=0`; `tpool ABSENT → UNIQUE`; screen `NEW-kill`; controls unchanged | **MECHANISM CONFIRMED on the investigation's own target.** The full chain, end to end, on one specimen |
| screen `NEW-kill` but `tpool` still `ABSENT` | mechanism confirmed BEHAVIOURALLY; **pool presence is then NOT necessary** for execution and is demoted from the chain to a correlate |
| static CONSUMED, attach `rc=0`, but screen `OLD-kill` | **the repair did not restore execution.** Foldability is then insufficient to explain this target, and something specific to `killswitch_probe` remains — a genuinely new finding |
| static shows NO surviving call site | repair did not take; **report as UNRUN**, do not score |
| any `UNREACHABLE-KILL*` on screen | body/control defect; **INVALIDATE** |

## Admissibility — unchanged from every prior run

1. screen shows `route B value: NEW-kill` **with the patch `Installed`**, bracketed
   before AND after (`Bad` is terminal, so `Installed` after proves `Installed`
   throughout);
2. trace delta attributable to that launch; `rc=0`, `bc_post=1`,
   `uep_post_is_interpret_call=1`;
3. the receipt shows that launch reaching `arm:render` and `first-frame`
   (killswitch carries receipts, unlike release 91);
4. release preserved, LC_UUID asserted; patch content verified to carry
   `NEW-kill`;
5. the static pre-check above passed.

**Attachment evidence does not substitute for the screen.**

## Deliberate interventions, declared in advance

* updater state DELETED (`--rmtree`) and re-reached by a real download — nothing
  asserted, same rule as every prior run;
* the render arm may be FORCED by uploading the fixture's own `g15_armed`
  marker, which selects which arm a launch takes and touches neither the target,
  the patch, the engine, nor the displayed value. Needed because
  `BOOT_FAILURE_THRESHOLD = 2` makes the admissible window narrow;
* the app is **NOT uninstalled** — that would reset iOS Local Network consent, a
  mistake already made once this cycle.

## Standing claims, unchanged by this precommit

* Route B iOS end-to-end execution: **PROVEN** (seven specimens).
* Target kind: **REFUTED** as a discriminator.
* Foldability: **ISOLATED** as the discriminator (`foldability_verdict.txt`).
* release-91 `NEW-kill`: **contradicted**; not a working baseline.
* **Arm A: INCONCLUSIVE — and this run does not change that.**
* Claim 1: instrument established **and** positive locator proven; `AMBIGUOUS`
  still unexercised.
