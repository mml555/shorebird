# LAYER 3 CLOSED — the full chain survives end to end

Closure cycle. All three layers required, all three met.

    client   updater fe51f225 (queue acknowledgement fix)
             engine cell 986e088019dc7c59a10ab568fd69dccd9b788765
             arm64 LC_UUID 4C4C4462-5555-3144-A11E-11E07BD5F384
    server   cps-assets:local-m9 (migration 9 + outcome-aware dedupe)
    specimen release 107 / 1.7.0+1, patch 1, 5,843 patchable sites

**The halves are only correct together**, and this is the first run where both shipped.

## GATES BEFORE DEVICE WORK

1. **server first** — migration 9 columns present; two lifecycle outcomes for the
   same client/app/release/patch **in the same timestamp-second** both accepted and
   both persisted (ids 144, 145) with 7-field keys; no `duplicate event ignored`.
2. **coherent cell, no cache surgery** — published through `publish_ios_overlay.sh`;
   fetch-back gate on the CONSUMED bytes passed all four surfaces (engine `4C4C4462`
   carrying `ACK_EVENT`, universal `gen_snapshot`, product SDK and `dart-sdk` both
   `9e8c898a4d`); producer tooling **AUDIT CLEAN**, fetched over HTTP and probed
   (`dart2bytecode` runs); updater revision tied mechanically — `ACK_EVENT` is in
   the shipped engine and exists at `fe51f225` but not at its parent; a **real patch
   build succeeded** before anything was stamped.
3. **only then stamped** `compatibility.yaml`, describing exactly this client/server
   pair.

## DEVICE — rows 4-5 only

Fresh identity, `g15_mode` verified by read-back before each scored launch, state
wiped so no prior diagnostic could masquerade as current (`CL_pre`: both logs
ABSENT).

**Row 4 `hard-kill`** — checkpoint persisted, nothing after it, SIGKILL landed,
breadcrumb left `cur=1 count=1`, patch `Installed`, no explicit failure.

**Row 5 `success`** — the concurrency was left to production behaviour, not
serialised:

    LAYER 1 · device / client
      patch 1             Installed          <- survived the ambiguous death
      last_booted_patch   1                  <- the patch booted
      breadcrumb / tally   None / 0
      success_diag        raw_boot_attempt=2 prior_ambiguous_attempts=1 WILL_EMIT
      queued_events       1  -> recovered_after_ambiguity STILL QUEUED
      ACK_EVENT           AmbiguousBootRetry removed=true queue_len=1->0

**That last line is the fix, observed directly**: the flusher removed ONLY the retry
it had sent and left the recovery intact. The old `clear_events()` wiped both, which
is exactly how this event was destroyed in three previous runs.

    LAYER 2/3 · wire and server, after the next check-in
      ACK_EVENT   RecoveredAfterAmbiguity removed=true queue_len=1->0
      client queue 0
      id=147 outcome=ambiguous_boot_retry       attempts=1 threshold=2 patch=1
      id=149 outcome=recovered_after_ambiguity  attempts=1 threshold=2 patch=1
      correlation identity identical across both rows:
        client 15abaf39-9167-4ded-b91d-f2319408a298 / patch 1 / 1.7.0+1

Both persisted as **distinct rows**, neither lost to dedupe, under one identity.

    LAYER 3 · metric — bootLifecycleMetrics()
      release    patch  1st_amb  2nd_amb  recovered  retired
      1.4.0+1        2        1        0          0        0
      1.5.0+1        1        1        0          0        0
      1.6.0+1        1        1        0          0        0
      1.7.0+1        1        1        0          1        0

**P(recovery | first ambiguity) = 1/1** for this release.

## THE HISTORICAL ROWS ARE THE BEFORE PICTURE — and must not be pooled

`1.4`, `1.5` and `1.6` each show one ambiguity and **zero** recoveries. Those zeros
are not device behaviour; they are the two defects:

* `1.4.0+1` — the recovery arrived and the pre-fix server discarded it as a
  duplicate (same second, outcome absent from the dedupe key);
* `1.5.0+1` and `1.6.0+1` — the recovery never left the client, destroyed by
  `clear_events()` wiping a queue it had not sent.

**They are evidence, not data.** Any future ratification of the threshold must
exclude releases before `1.7.0+1`, because their recovery numerator was
systematically zeroed while their denominator survived. Pooling them would bias the
result in exactly the direction the defects created.

## WHAT IS NOW ESTABLISHED

> An uncatchable pre-success disappearance is classified as AMBIGUOUS, the healthy
> patch is retried rather than retired, the next launch boots the patch, and BOTH
> lifecycle outcomes reach the control plane as distinct records that the fleet
> metric counts correctly.

C3/C4 are device-proven at all three layers. The lifecycle telemetry is no longer
knowingly biased.

## KNOWN FOLLOW-UPS, deliberately not folded in

* **Head-of-line starvation.** A failed send now stays queued (intended), and
  `copy_events` takes the FIRST n, so a permanently failing event at the head can
  starve later ones. Correctness was proved first, as scoped.
* **`isRouteBEngine()` cold-cache false negative** — absence of a not-yet-downloaded
  artifact is read as "not a Route B engine", which silently suppresses
  `--patchable_static_calls` AND the verification that would catch it. Needs
  absence = unknown, plus a behavioural test starting from an absent artifact.
* **Threshold 2 is still unratified** — now answerable from fleet data, from
  `1.7.0+1` onward only.
* Diagnostics (`state_diag.log`, `success_diag.log`) are observation scaffolding and
  should be reviewed before any wider ship.

## STATE

cell `986e0880` in service; earlier cells intact. Release 107 / patch 1 healthy,
`last=1`, tally 0, client queue empty. Device `g15_mode = success`.
`compatibility.yaml` **stamped** for this pair.
