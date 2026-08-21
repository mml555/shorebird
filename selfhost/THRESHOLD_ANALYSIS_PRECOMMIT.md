# THRESHOLD POLICY ANALYSIS — PRECOMMIT

Written **before** any fleet data exists, so a threshold cannot be chosen after
seeing a convenient sample. The mechanism is closed
(`evidence/g15/layer3_closure_verdict.md`); this is measurement and policy.

## TELEMETRY VALIDITY EPOCH

> **Lifecycle recovery metrics are valid only for client releases that shipped BOTH
> outcome-aware server dedupe (migration 9) and exact event acknowledgement in the
> client. Releases before `1.7.0+1` are EXCLUDED from threshold-policy analysis.**

Encoded, not left to dashboard hygiene: `Repository.preEpochReleaseVersions` is
applied inside `bootLifecycleMetrics()`, with a test asserting a pre-epoch row does
not reach the estimator and a post-epoch row does.

Pre-epoch rows stay queryable as evidence of the instrumentation failures. They must
never enter an estimator: both bugs zeroed the recovery NUMERATOR while leaving the
ambiguity DENOMINATOR intact, so including them biases the answer toward zero rather
than adding noise.

**Known limitation.** The correct predicate is the client's updater revision, and
events do not carry it. Until they do, the epoch is enforced by naming releases for
this deployment. **Adding an updater-revision field to the event envelope is the
durable fix** and would retire the list.

## THE FOUR NUMBERS

| metric | question |
|---|---|
| ambiguity incidence | how often does a healthy-looking patch hit an ambiguous pre-success disappearance? |
| `P(recovery \| first ambiguity)` | if it happens once, how often does the next attempt succeed? |
| `P(retirement \| first ambiguity)` | how often does one ambiguity end in backout? |
| repeated-ambiguity distribution | among affected clients, how many see 1, 2, 3+ before recovery or retirement? |

## THE ACTUAL POLICY QUESTION

Not "what percentage recover", but:

> **Given one ambiguous boot, how much expected user harm do we create by retiring
> immediately versus allowing one more attempt?**

Retiring too early silently removes a working patch from that device, permanently,
and reports itself as the safety mechanism working. Retiring too late costs one more
crashed launch and self-corrects. The costs are asymmetric, so the decision rule is
asymmetric.

## INCLUSION / EXCLUSION — fixed now

* **eligible epoch**: client release `>= 1.7.0+1` (by the encoded list, not string
  comparison).
* **primary unit: DISTINCT CLIENTS, not event rows.** A chatty client must not
  outvote a quiet one. `bootLifecycleMetrics` already counts
  `COUNT(DISTINCT client_id)`.
* **minimum sample**: no threshold conclusion from fewer than **100 distinct clients
  with a first ambiguity**. The current `1/1` is an integration proof and is
  explicitly NOT evidence about the fleet.
* **development/test clients excluded**: the rig's own `client_id`s and the
  `preflight-*` / `pf*` / `gate1` synthetic ids used while proving the pipeline.
  Recorded because they exist in the same table.
* **recovery** = a `recovered_after_ambiguity` record for the same
  (client, app, release, patch) as a preceding `ambiguous_boot_retry`.
* **retirement** = `retired_after_ambiguity`, or a `PatchInstallFailure` carrying the
  `crash_recovery:` prefix for that patch.
* **clients that never launch again**: counted in the denominator, in NEITHER
  recovery nor retirement. Reported as a third bucket — "no further observation" —
  and never silently folded into non-recovery. Absence of a later launch is not
  evidence of failure to recover, and this is exactly where an estimator can lie.
* **multiple episodes from one client**: the client counts **once** for the primary
  policy unit. Episode-level counts may be reported separately, clearly labelled,
  and must not be the basis of the threshold decision.
* **an explicit Dart failure is not ambiguity** and never enters these populations.

## WHAT WOULD CHANGE THE POLICY

* recovery on the next attempt is **common** -> single-strike retirement is
  destructive; threshold 2 is justified, and 3 becomes worth evaluating;
* recovery is **rare** and repeated ambiguity almost always ends in retirement ->
  the extra attempt buys little, and threshold 2 needs re-argument on the cost of
  one more crashed launch;
* **repeated ambiguity without retirement is common** -> the tally or its reset is
  wrong, and this is an instrumentation finding, not a policy one.

## OBSERVATION-INTEGRITY BLOCKERS — both resolved before measurement

**Head-of-line starvation — FIXED, was a censorship risk.** `copy_events` takes the
FIRST n, so with retain-on-failure, n permanently-failing events at the head formed a
permanent batch and nothing behind them was ever sent. With n = 3 that silently
censors queued lifecycle records — the same class of failure as the dedupe collision
and the queue wipe, reached a third way. Failed sends now rotate to the BACK of the
queue: nothing is dropped, and every event eventually reaches the head. Proven by
`rotation_stops_stuck_events_from_censoring_a_lifecycle_event`, mutation-checked.

Queue growth while the server is unreachable is still unbounded, and is NOT an
observation-integrity issue: it delays events, it does not censor them.

**`isRouteBEngine()` cold-cache false negative — PARKED, cannot censor.** Determined
by tracing the chain rather than assuming:

    artifact absent -> capability false -> --patchable_static_calls omitted
      -> release not patchable -> the CLI REFUSES to build a patch for it
      -> no patch ever boots -> report_launch_start sets no breadcrumb
      -> NO lifecycle events at all

Such a client contributes to neither numerator nor denominator: it is absent from the
population, not distorted within it. So it cannot suppress or misclassify telemetry
for an otherwise-eligible client, and it does not block unbiased measurement.

**Residual caveat, recorded:** if cold caches correlate with a population (fresh CI
environments, first-time installs), that population is missing from the sample
entirely. That is a REPRESENTATIVENESS risk, not a bias in
`P(recovery | first ambiguity)`. It remains a real product defect worth fixing —
absence should read as unknown, never as "not a Route B engine" — just not a
prerequisite for measurement.

## STOPPING RULE

No more bespoke device specimens unless production telemetry exposes an
inconsistency the host tests do not reproduce. The lifecycle project has crossed from
"prove what the system does" to "measure how often reality exercises each path".
