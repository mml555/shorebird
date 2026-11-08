# cd137db6 bisect — PRECOMMIT

Written 2026-08-17, **before the run.** Splits `0011` (the `_runMain` seam) from
`0012`/`0013` as the cause of the behavioral flip established in
`r91_behavioral_verdict.txt`.

## The controlled comparison

Identical hybrid, identical patch, identical target. **Only the engine cell
changes**, and it is the only thing that has ever changed across these three
runs:

    80e493e4   0009 + 0010          NEW-kill x2   (arm2_verdict.txt, historical)
    cd137db6   0011 _runMain seam   ???           <- THIS RUN
    50bdae36   0012 + 0013          OLD-kill      (r91_behavioral_verdict.txt)

## THE OUTCOME TABLE, precommitted

| observation | what it licenses | what it does NOT license |
|---|---|---|
| **cd137db6 → `OLD-kill`** | the flip is ALREADY PRESENT with `0011`. Focus goes directly to the `_runMain` seam and the other engine changes introduced in that cell | NOT a mechanism, and NOT that `0012`/`0013` are irrelevant to anything else |
| **cd137db6 → `NEW-kill`** | `0011` is **exonerated behaviorally**. The flip lies AFTER it — in the `0012`/`0013`/current-cell lineage, **despite those patches being intended as pure-read diagnostics** | NOT that a diagnostic cannot have effects; that would be the finding, not an objection to it |
| **no admissible screen while `Installed`** | **NO bisect result.** Preserve without interpretation | NOT substitutable by a screen taken after tombstoning |

## Admissibility — UNCHANGED from r91_behavioral_precommit.md

All four, same launch:

1. release 91's UI **visibly rendered** — `G15 arm 2` + `route B value:`, and NO
   `launch <id>` line (that line would mean a release-96 frame);
2. **trace line-count DELTA** attributable to that launch;
3. `patches/1/state.json` = `Installed`, bracketed BEFORE and AFTER;
4. patch active on that boot — `pointers.json` shows it booting/booted, and the
   trace line carries `rc=0`.

**The trace will be `v=4`, not `v=5`, and that is expected**: `cd137db6` predates
`0012`, so it has no `tpool_*` fields. The trace mechanism itself exists at v4
(see `g5_armA_rbtrace.txt`), so requirement 2 is unaffected. A `v=5` line would
mean the wrong engine is installed and **invalidates the run**.

### Feasibility precondition, checked before installing

`SNAPSHOT_HASH` of `cd137db6`'s engine must equal `21139db2770724220da55c72db00acdc`,
or release 91's published snapshot will not load and the run is outcome 3.

## Scoring restrictions

* **`TPOOL_ABSENT` DOES NOT PARTICIPATE IN SCORING.** It has been shown invariant
  across both behavioral outcomes (`NEW-kill` and `OLD-kill` on release 91, and
  ABSENT on release 96). It is a consistency check only — and at `cd137db6` it is
  not even measurable, since `tpool_*` does not exist before `0012`.
* **Arm A stays exactly where it is: INCONCLUSIVE, engine-lineage-localized.** A
  bisect narrows which change to study. It does not produce a mechanism, and
  `gate5_arms_precommit.md` still requires `NEW-kill` on screen for release 96's
  specimen.
* **Claim 1 is untouched**: instrument established; positive locator not yet
  proven. This run cannot bear on it — the instrument does not exist in this
  engine.
* The boot-counter state this run produces belongs to the **separate**
  tombstone/retry lane and is not read here.

## The prior expectation, stated so the result cannot quietly confirm it

`0012`/`0013` are pure-read diagnostics; `0011` moves where `main` is invoked. So
`OLD-kill` at `cd137db6` is the expected outcome. **Two leading explanations in
this investigation have already died on measurement** — the fold, and inlining —
both of which were equally plausible when proposed. The expectation is recorded
here so that if `cd137db6` renders `NEW-kill`, that result is read as the finding
it would be rather than as an anomaly to be explained away.
