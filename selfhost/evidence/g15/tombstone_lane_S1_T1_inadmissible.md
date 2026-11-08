# Sequence 1, T1 — INADMISSIBLE for row 1, and it surfaced a different phenomenon

2026-08-18. Scored against `tombstone_lane_precommit.md`; that table is not edited.

## What was expected, and what happened

Row 1 expected a patch that ATTACHED and then failed to reach the success latch:
`cur=1, count=1, last_booted=None`, patch still `Installed`.

Observed after ONE manual tap (`hlglqm5li9`):

    patch 1   Bad{BootCrash}
    pointers  next=None  last=None  cur=None  count=0  lastAttempt=None
    queued    1 -> __patch_install_failure__
              "engine_report: patch 1 failed to launch"
    trace     ABSENT
    receipt   native launch / native engine / dart-main-entered /
              boot-probe-returned:boot-ok / arm:kill        (Dart DID run)
    witness   56/10 -> 61/11  (exactly one launch)

## VERDICT: INADMISSIBLE for row 1 — by this lane's own criterion

`tombstone_lane_precommit.md` admissibility item 2 requires *"the patch's attach
is established independently (`rc=0`, `bc_post=1`) so 'never attached' is
excluded."*

**It cannot be established here.** The Route B trace and the patch payload were
both deleted when the patch was marked `Bad`, so nothing survives that could show
an attach occurred. The criterion was written for exactly this ambiguity and it
does its job: **this is not row 1, and it is not scored as row 1.**

## The mechanism, read from the source rather than inferred

`UPDATER_CONTRACT.md:165-178` documents two paths to
`__patch_install_failure__`, distinguished by their message:

    path 1  crash-detected at next init  -> "crash_recovery: patch N failed to boot (…)"
    path 2  engine-reported              -> "engine_report: patch N failed to launch"
                                            fired when A PATCH LOAD FAILS

**Ours is path 2.** And `updater.rs:1213-1245` shows `report_launch_failure()`
marks the patch bad **immediately** — `record_boot_failure_for_patch`, no counter,
no threshold — then queues the event.

The engine's only two call sites (`shell.cc:543`, `shell.cc:849`) both fire
BEFORE Dart exists: `!vm_`, and `Engine::Run` returning `Failure`. Consistent with
everything observed: the patch failed to LOAD, the engine reported it, marked it
bad, fell back to the release, and Dart then ran unpatched — which is why the
receipt shows `dart-main-entered` in the same launch.

## THE FINDING THAT MATTERS MORE THAN THIS ROW

**`0010`'s threshold does not protect this path.** `BOOT_FAILURE_THRESHOLD = 2`
governs only the *crash-detected-at-next-init* inference — the one that reasons
from a stale breadcrumb. `report_launch_failure()` is **single-strike by design**
and bypasses the counter entirely.

So the lane's framing needs widening: there are TWO ways a patch is retired, with
very different safety properties, and only one of them was under study.

* **inference path** — breadcrumb still set; cannot tell a bad patch from a swipe-
  away; `0010` spends one extra boot before retiring. This is the row 6 concern.
* **positive-report path** — the engine states the patch did not load; retires it
  immediately, and immediacy is CORRECT here because the engine has direct
  evidence rather than an inference.

## ALSO: a first on-device observation

`UPDATER_CONTRACT.md:190-195` records that `__patch_install_failure__` had **NOT
yet been observed on device** (per `BEHAVIORAL_FINDINGS.md`) — it needs a real
failure. **This is that observation**, queued to disk exactly as documented, with
the documented message shape. Preserved at `tombstone_lane/S1_T1/`.

## OPEN, and NOT to be guessed

**Why did this patch fail to load?** The same patch (#1 for 1.0.8+1, 869 B
container) loaded and rendered `NEW-kill` in `routebvalue_repair_verdict.txt`.
Between then and now: the updater state was cleared with `afcclient rm` and the
patch was re-downloaded.

Candidates, none tested: a damaged/incomplete re-download; a base-snapshot or
inflate failure; state cleared at a granularity the updater does not expect
(individual files rather than the whole tree). **The `.routeb` report that would
have named the refusal was deleted with the payload.**

Next step is cheap and needs no tap: capture `idevicesyslog` during the next
launch — `report_launch_failure()` emits `shorebird_info!("Reporting failed
launch.")` and the load path logs its reason, which would name the cause directly.

## Sequence 1 must restart

The specimen is spent: patch `Bad`, payload deleted. Rows 1-4 need a fresh
install reached by real download, with attach confirmed via a surviving trace
BEFORE any deliberate kill.
