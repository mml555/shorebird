# MEASUREMENT MODE — the system is now stable by intent

Lifecycle engineering is finished. The five operational prerequisites are met and
**lifecycle behaviour must not change again until the precommitted sample threshold
is reached** (`THRESHOLD_ANALYSIS_PRECOMMIT.md`).

> ### ⚠ ADDITION — 2026-08-27. A lifecycle fix landed for Signing. Read this before it ships.
>
> `af6e842ccf87` makes boot attribution atomic with boot selection
> (`evidence/p6-signing/ATTRIBUTION_FIX.md`). It is a **lifecycle-behaviour
> change**, so it meets this document's own "not allowed while collecting" line,
> and it is raised here rather than quietly absorbed.
>
> **What it changes.** Only the REJECTION path. When a next-boot candidate fails
> validation, the launch is now credited to the patch that actually booted instead
> of to the rejected one. On the path the estimator measures — a candidate that
> validates — preparation returns the same patch the old three-call sequence
> returned, records the same `record_boot_start`, and emits the same events. The
> `boot_attempt_count` / threshold / retry semantics are untouched.
>
> **Why the current sample is not disturbed.** The measured population is release
> 108 / 1.8.0+1 on cell `2c4443cedd654fad8eebd877bbc215edbdd11615` with updater
> `f729f958e9be`. Those clients are not re-cut; a new cell is additive. And
> `af6e842ccf87` is **not** in `eligibleUpdaterRevisions`, so any client on it is
> excluded — the under-counting direction this document already calls deliberate.
>
> **DECIDED 2026-08-27: the sample RESTARTS. Two epochs, never pooled.**
>
> And the reasoning above was **wrong where it mattered**. "Behaviour is identical
> on the measured path" understated the change: what moved is *when a boot becomes
> attributable*. Under `f729f958e9be`, `report_launch_start` ran BEFORE validation,
> so a process that died during validation left a breadcrumb and was counted as an
> ambiguity. Under `af6e842ccf87`, validation precedes attribution, so the same
> death leaves no breadcrumb and is not an ambiguity at all.
>
> Counters, retry threshold and emission are untouched — but the **definition of
> the measured population** is not, and that population is the denominator of the
> only number the threshold decision rests on. With a 100-distinct-client minimum
> and a documented sample of 1, there was never any upside to accepting even a
> small comparability ambiguity.
>
> See the two-epoch section below.

## THE SHIPPED COMBINATION

    client   updater f729f958e9be
               exact event acknowledgement  (no whole-queue wipe)
               failure rotation             (no head-of-line censorship)
               revision stamped into every event
             engine cell 2c4443cedd654fad8eebd877bbc215edbdd11615
             arm64 LC_UUID 4C4C4496-5555-3144-A132-BC57AC16BED0
    server   cps-assets:local-m10
               migration 9  outcome-aware dedupe
               migration 10 updater_revision column + index
             rollback container: cps-ios-prem10
    specimen release 108 / 1.8.0+1, patch 1, PATCHABLE

**The halves are only correct together.** They were shipped together this time only
after a mistake: the client half was published first, and the server running
`local-m9` had no `updater_revision` column at all. Caught by querying for the
column rather than assuming the deploy had matched.

## THE FIVE STEPS, as verified

1. **engine built and published** with the rotation fix, through the normal cell
   pipeline — fetch-back gate passed, producer tooling **AUDIT CLEAN**.
2. **revision verified in the SHIPPED bytes**, not the build log: `f729f958e9be`
   present in the app's own engine, alongside `REQUEUE_FAILED` and `ACK_EVENT`.
3. **that exact revision added** to `eligibleUpdaterRevisions`. `fe51f225c686` is
   deliberately NOT listed — it has acknowledgement but predates rotation, so a
   stuck batch head could still censor its lifecycle events. Eligibility requires
   every known loss mode closed.
4. **a real client event verified end to end**:

       id=152 ambiguous_boot_retry       rev=None           <- EXCLUDED
       id=154 ambiguous_boot_retry       rev=f729f958e9be   <- eligible
       id=156 recovered_after_ambiguity  rev=f729f958e9be   <- eligible

       estimator: 1.8.0+1 patch 1 — 1st_amb=1 2nd_amb=0 recovered=1 retired=0

   `id=152` is the same client, release and patch as `id=154` and is still excluded,
   because it predates the revision field. That is the predicate working: eligibility
   follows the behaviour-bearing client code, not the release name.
5. **stop changing lifecycle behaviour.** This document is that line.

## TWO STAMP DEFECTS FOUND BY VERIFYING BYTES

Both would have produced an engine that could never match an eligible revision —
indistinguishable, in the data, from "no eligible clients exist".

* the first stamp shelled out to `git`, which is not on PATH inside the ninja action
  that builds this crate, so it silently fell back to `"unknown"`;
* it emitted `rerun-if-changed` for `.git/HEAD`, whose contents are
  `ref: refs/heads/<branch>` and do **not** change when a commit lands — and emitting
  any `rerun-if-changed` disables cargo's default heuristics, pinning the stale value.

Now read from the git files directly, resolving symbolic HEAD, packed refs and
detached HEAD, watching every file actually read. Unreadable yields `"unknown"`,
which the server treats as ineligible rather than trusting.

## WHAT IS NOT ALLOWED WHILE COLLECTING

* no lifecycle-behaviour changes: counters, threshold, guard, emission, retry;
* no threshold ratification below **100 distinct eligible clients** with a first
  ambiguity — the current `1` is an integration proof;
* no pooling of `1.4`-`1.6`, which stay as historical instrumentation evidence;
* no bespoke device specimens unless production telemetry shows an inconsistency the
  host tests cannot reproduce.

## PARKED PRODUCT ISSUES — neither alters the eligible population

* **unbounded queue growth** while the server is unreachable. Delays events, does not
  censor them.
* **`isRouteBEngine()` cold-cache false negative.** Traced: a non-patchable release is
  refused a patch, so no patch boots, so no breadcrumb and no lifecycle events at
  all. Such a client is absent from the population rather than distorted within it.
  Residual **representativeness** caveat if cold caches correlate with a population.
* **the revision allow-list** must gain each new eligible revision explicitly. A
  missing entry under-counts; it cannot fabricate a recovery. That direction is
  deliberate.

## THE QUESTION THIS EXISTS TO ANSWER

> Among real clients experiencing a first ambiguous boot, does allowing one retry
> reduce expected user harm compared with immediate retirement?

Not technical any more. The instrumentation whose loss modes are now understood and
controlled is what makes the answer trustworthy — which is the whole point of the
1.4-1.6 rows being kept where anyone can see them.

## THE TWO EPOCHS — decided 2026-08-27

    Epoch A — CLOSED / historical
      updater   f729f958e9be
      cell      2c4443cedd654fad8eebd877bbc215edbdd11615
      sample    PRESERVED. Never pooled into a later threshold decision.

    Epoch B — CURRENT
      updater   af6e842ccf87
      cell      4792f0eca461f3761001a1adbe131b4b115e3684
      sample    starts from ZERO
      threshold unchanged: 100 distinct clients with a first ambiguity

Epoch A is **not deleted**. It remains the instrumentation and behavioural
evidence that made the loss modes visible in the first place. It simply may not
contribute clients to Epoch B's 100.

### Enforced in code, not by convention

`Repository.PolicyEpoch` replaces the flat `eligibleUpdaterRevisions` allow-list.
A flat set had one fatal property: adding a revision **silently pools** its
clients with every earlier one, and nothing complains. Epochs are closed, not
extended.

`Repository.activePolicyEpoch` is `PolicyEpoch.b`, and **`b.updaterRevisions` is
empty** until the checklist below is discharged. An unactivated epoch reports zero
eligible clients — the correct reading of *this epoch has not started*, not an
error. `bootLifecycleMetrics` returns early on an empty set rather than
interpolating `IN ()`, which is a SQL syntax error; the tempting "fix" for that
error is dropping the predicate, which would pool every revision, so the early
return is deliberate and pinned by test.

Mutation-checked: setting `b.updaterRevisions` to `{'f729f958e9be'}` — precisely
the careless extension this shape exists to prevent — fails
*epoch A's clients never count toward epoch B* and *the ACTIVE epoch is
unactivated, so it reports nothing*.

### PRECOMMITTED: what activates Epoch B

Recorded **before** any Epoch B outcome rate is looked at, so the activation
cannot be shaped by what the numbers say.

The Signing fixture proving `af6e842ccf87` exists in fetched engine bytes is
necessary but **not sufficient** — it is not the production measurement specimen.

1. cut the actual measurement/production release on `af6e842ccf87`;
2. fetch the **published** release artifact from the control plane;
3. read `af6e842ccf87` out of **that app's** shipped engine bytes, never the build
   log — the two stamp defects in this document are why;
4. verify the server receives a **real client event** carrying
   `updater_revision=af6e842ccf87`;
5. verify that event is accepted by the current dedupe/schema path;
6. exclude the rig/test client;
7. only then add `af6e842ccf87` to `PolicyEpoch.b.updaterRevisions`.

Until step 7, Epoch B has not started and the estimator says so.

### What is NOT allowed while Epoch B is established

Everything in *WHAT IS NOT ALLOWED WHILE COLLECTING* above, plus: the
**first-activation launch disappearance** investigation must not change lifecycle
policy semantics. Its first objective is classification and reproduction, not a
fix. A fix that moved the attributability boundary again would end Epoch B the way
`af6e842ccf87` ended Epoch A.
