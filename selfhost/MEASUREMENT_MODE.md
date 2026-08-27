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
> **Two decisions are therefore open, and neither is taken here:**
>
> 1. whether the epoch CONTINUES across `f729f958e9be` → `af6e842ccf87` (the
>    argument for: behaviour is identical on the measured path) or whether the
>    sample restarts;
> 2. whether `af6e842ccf87` is added to `eligibleUpdaterRevisions` — which
>    requires this document's step 2 first: read the revision out of the SHIPPED
>    engine bytes, never the build log.
>
> Until (1) is answered, the Signing lane uses the new cell for its own fixture
> only and the measurement app stays on `2c4443ce…`. Nothing here has shipped.

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
