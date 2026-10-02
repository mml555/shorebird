# HYBRID-METHOD CONTROL — precommit

Written 2026-08-17, **before the control runs**, and before the `87130ae8` verdict
is written, because that verdict's meaning depends on this.

## The confound this exists to test

Every `OLD-kill` result in the bisect chain came from a **hybrid** I assembled:
release 91's `Runner.app` with a substituted `Flutter.framework`, re-signed by me.

The `NEW-kill` reference point — cell `80e493e4` — comes from `arm2_verdict.txt`,
which was **release 91 running its OWN shipped engine, not a hybrid, not
re-signed, on 2026-08-14.**

**So the comparison currently has TWO differences, not one:** the engine cell, and
the assembly method. If the hybridization itself (or today's device/OS state) is
sufficient to produce `OLD-kill`, then all three bisect results are artifacts and
the lineage attribution is worthless.

This was not noticed when the first hybrid was run. It is caught now, and it is
load-bearing.

## The control

Release 91's snapshot with **`80e493e4`'s engine** — the cell release 91 actually
shipped with — assembled and re-signed by the SAME procedure as the three bisect
runs. This reconstructs release 91's native configuration through the hybrid
pipeline.

Same admissibility requirements as `cd137db6_bisect_precommit.md`, unchanged:
rendered release-91 UI with no `launch <id>` line; trace delta attributable to the
launch; `Installed` bracketing; patch active with `rc=0`; pre-`0012` `v=4` trace
schema.

## THE OUTCOME TABLE, precommitted

| observation | what it licenses |
|---|---|
| **`NEW-kill`** | the hybridization procedure is **exonerated**. `arm2_verdict`'s result is reproduced through the identical method, so the only remaining difference across the chain is the engine cell. **The three `OLD-kill` results stand, and the flip is attributed between `80e493e4` and `87130ae8`.** |
| **`OLD-kill`** | **the method or the current device/OS state is itself sufficient to produce `OLD-kill`.** All three bisect results are CONFOUNDED and must be withdrawn as lineage evidence. The behavioral discriminator collapses, and `r91_behavioral_verdict.txt` must be corrected — its "one variable changed" claim would be false |
| **no admissible render while `Installed`** | no control result; the bisect chain stays UNATTRIBUTED rather than being trusted by default |

## Why this is not optional

`r91_behavioral_verdict.txt` claims *"One variable, and the outcome flips."* That
sentence is only true if this control renders `NEW-kill`. Until it runs, the
correct status of the entire bisect chain is **attribution pending**, and the
chain's three results are observations rather than lineage evidence.

Scoring restrictions carry over unchanged: structural `tpool_*`/pool fields do not
participate; boot-counter state is not read; arm A stays INCONCLUSIVE.
