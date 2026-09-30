# G15 gate 5 — the three-arm hardware gate: PRECOMMITTED

Written **before** any patch is published and before any launch, 2026-08-16. Not
edited afterwards; the verdict goes in a separate file.

Baseline: `killswitch_probe` **1.0.6+1** = control-plane release **95**, on cell
`cd137db6`, carrying patch `0011`'s seam. Durability established by content read
across a restart (`gate5_baseline_verdict.txt`).

## What is under test

`0011` moved launch success to `success = earliest(main completion, first
framework frame)` and DELETED the `Engine::Run` success report. The arms ask
whether that seam can now do what `0009`'s could not: tell a Dart-phase failure
from a good boot, without tombstoning a good patch that merely died early.

## The reading rule, binding on every arm

**The receipt is read before the screen, and only lines carrying the launch id
printed on that screen count for that launch.** Updater state is pulled and read
BETWEEN launches, not only at the end — arm 2's earlier shortfall was a counter
already reset by a later success, so the arithmetic was never caught in flight.

## Publish discipline, binding on every patch

publish → **content-read `patches` + `audit_log`** → only then is it an
admissible device specimen. A disappearance is **evidence to preserve**, not a
trigger to alter authentication state.

## The arms

| arm | patch | mechanism under test |
|---|---|---|
| **A** | `routeBValue() => 'NEW-kill'` — a GOOD patch | success banks at `main` completion; patch stays `Installed` and runs |
| **B** | `bootProbe() => <String>[].first` — throws in `main` | the seam catches a synchronous throw, reports FAILURE **and rethrows**, and the updater marks `Bad{BootCrash}` |
| **C** | arm A's good patch, killed before success | `SIGKILL` inside `main` banks nothing; `0010`'s counter must RETRY rather than tombstone |

## PRECOMMITTED OUTCOMES

### Arm A — good patch

| observation | verdict |
|---|---|
| receipt reaches `first-frame`; screen shows `NEW-kill`; `pointers.json` has `last_booted_patch: 1`, `boot_attempt_count: 0`, `queued_events: []` | **PASS** |
| receipt reaches `first-frame` but patch is `Bad{BootCrash}` | **FAIL, and it is the worst outcome available**: the seam banks success and the updater tombstones anyway, i.e. the two halves disagree |
| receipt stops before `dart-main-entered` | not an arm result — the specimen never ran Dart; investigate the install |

### Arm B — bad patch (throws in `main`)

| observation | verdict |
|---|---|
| receipt shows `dart-main-entered` and **no** `boot-probe-returned`; patch marked `Bad{BootCrash}` after **ONE** launch; a `PatchInstallFailure` event is queued; next launch runs the RELEASE (`OLD-kill`) | **PASS by the intended mechanism** — positive failure reporting, not the counter |
| backed out only after **TWO** launches | **PASS by the COUNTER, not by the seam.** Closes the gate but means `ReportLaunchFailure` never fired — record as such, do not smooth it into a pass |
| patch never backed out, crashes every launch | **FAIL.** This is `0009`'s defect surviving the move, and the goal's blocking item |
| `boot-probe-returned` present | the patch did not take; not an arm result |

### Arm C — good patch killed before success

| observation | verdict |
|---|---|
| launch 1 receipt ends `arm:kill` (no `first-frame`); launch 2 renders `NEW-kill`; patch still `Installed`, never `Bad` | **PASS** — a good patch that died early is retried, and `0010` is re-earned at the NEW, later seam |
| launch 2 shows `OLD-kill` | **FAIL** — the patch was tombstoned for dying early. This is the false-backout `0010` exists to prevent, and the wider window `0011` introduced would be the cause |
| launch 1 reaches `first-frame` | the kill missed its window; not an arm result, re-run |

### Any arm

| observation | verdict |
|---|---|
| red **INSTRUMENT FAULT** banner | not an arm result; the receipt or marker mechanism failed |
| a published patch is absent on content read | **STOP.** Preserve; do not touch auth or CLI state |

## What would make the whole gate inadmissible

If arm A and arm C disagree about whether success banks at `main` completion —
i.e. if the same good patch banks in one and not the other with no kill
difference — the seam is non-deterministic and no arm's result may be reported.

## Not under test

The first-frame half of the policy. Every arm here uses `void main()`, which
returns synchronously, so **`main` completion always wins the `earliest()`** and
`_drawFrame`'s latch never decides anything. A fixture whose `main` never
completes would be needed to exercise it, and none exists. Recorded so a green
gate is not read as evidence for a branch it never entered.
