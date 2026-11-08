# THE MISSING RECOVERY EVENT — host path exonerated, device count unmeasured

Follow-up to `layer3_verdict.md`. Narrow question: why did the device recover a
patch and report no `recovered_after_ambiguity`?

## THE HOST PATH IS CORRECT — measured across a real process boundary

`diag_tally_across_process_boundary` drives the production entrypoints with a fresh
updater loaded from the same disk between the two "processes", as the device does:

    [0] after install                          count=0 last_attempt=None
    [1] A: after report_launch_start            count=1 last_attempt=Some(1)
    [2+3] B: after init (crash detection ran)   count=1 last_attempt=Some(1)
    [4] B: immediately before success           count=2 last_attempt=Some(1)
    [5] count at success=2 -> prior_ambiguous = 1
    [6] B: after success                        count=0 last_attempt=None

So the `count - 1` interpretation **holds** here: the tally at success includes the
current boot, the retry branch deliberately preserves it across the process
boundary, and `prior_ambiguous_attempts = 1` emits the recovery. **The suspected
arithmetic is not guilty on this path.**

## WHAT THE DEVICE SYSLOG SHOWS

    12:32:03.570  pid 19272  Reporting successful launch      <- setup tap B (patch 2 healthy)
    12:33:03.778  pid 19283  Reporting launch start           <- ROW 4, then SIGKILL
    12:39:42.5698 pid 19333  boot 1 of patch 2 did not record success; retrying (threshold 2)
    12:39:42.5698 pid 19333  Reporting launch start           <- ROW 5
    ... patch check, "No update" ...
    (no success report for pid 19333)

**The retry branch confirms `count == 1` on device at row 5's init** — matching the
host exactly. The divergence is later.

## THE UNRESOLVED CONTRADICTION, stated rather than explained away

* row 5's process logged **no** `Reporting successful launch`;
* yet the captured state is `cur=None, count=0, last_boot_attempt_patch=None`,
  which **only a recorded success produces** — a retry would have kept the count,
  and reaching the threshold would have marked patch 2 `Bad`, which it is not;
* the patched value rendered, so the patch did execute.

Both readings are individually unsupported:

| reading | problem |
|---|---|
| success was never recorded | cannot explain `count=0`, `cur=None`, patch still `Installed` |
| success was recorded | the log line is missing, and `prior_ambiguous` must have been 0 despite the count reaching 2 |

The syslog capture was **191 MB and live**; `idevicesyslog` line loss under that
volume cannot be excluded, and two adjacent lines from the same pid ~100 ms apart
survived while a third did not would be consistent with loss. **Not asserted — the
point is that this evidence cannot decide it.**

## WHY THE EXISTING PASSING TEST IS NOT A CONTRADICTION

`prod_telemetry_success_after_ambiguity_reports_recovery` passes, and the diagnostic
above shows why: the sequence it models produces `prior_ambiguous_attempts = 1`.
It is therefore **not** wrong — it simply does not model whatever the device did.
The coverage gap is real but its shape is still unknown, so inventing a new
assertion now would be guessing.

## WHAT WAS DONE INSTEAD OF GUESSING

`report_launch_success` now logs the decisive number:

    Launch success for patch N: prior_ambiguous_attempts=K (recovery event WILL be emitted | suppressed: no prior ambiguity)

That converts the next device run from inferential to decisive: it distinguishes
"no ambiguity to report" from "the tally was wrong" directly, at the moment the
guard runs. Requires an engine rebuild to reach the device.

## WHAT IS NOT YET KNOWN — do not skip past these

* whether the device's `boot_attempt_count` was 1 or 2 when success ran;
* whether `report_launch_success` ran at all on that process;
* therefore whether the defect is in the tally, the guard, or the reporting seam.

**Do not spend another device run until the instrumentation ships**, or the same
ambiguity recurs.

## STATE

* updater: instrumentation + diagnostic committed (`288 passed`).
* server: fix deployed and preflight-PROVEN; the dedupe collision cannot recur.
* device: patch 2 `Installed` and healthy, `g15_mode = success`, untouched since
  row 5 — **still a usable specimen** for the re-run.
* Layer 3 remains **open**, now for a client-side reason, not a server one.
