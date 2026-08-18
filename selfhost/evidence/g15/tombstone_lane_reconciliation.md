# Tombstone / retry lane — RECONCILIATION FROM PRESERVED EVIDENCE

2026-08-18. **No device run.** Written before any new evidence is generated,
because the G15 lesson was that retrieval precedes hypothesis: the corpus already
contains the states that looked contradictory, and they must be reconciled
against `0010`'s actual transitions before a mechanism is invented.

## `0010`'s state machine, read from the patch rather than inferred

    record_boot_start(n)          if last_boot_attempt_patch != Some(n):
                                      count = 0; last_boot_attempt_patch = n
                                  count += 1
                                  currently_booting_patch = n

    record_boot_success()         count = 0; last_boot_attempt_patch = None

    detect_boot_crash_on_init()   if breadcrumb set:
                                      if count < 2:  clear breadcrumb ONLY,
                                                     KEEP count and last_attempt
                                                     -> RETRY
                                      else:          mark Bad{BootCrash}

**The counter increments at BOOT START, not at crash detection**, and a success
zeroes it. So a tombstone requires **TWO CONSECUTIVE un-succeeded boots**. One
un-succeeded boot followed by any successful boot can never tombstone, because
the success resets the tally to zero.

`BOOT_FAILURE_THRESHOLD = 2`.

## The apparent contradiction, and it dissolves

| run | pattern | outcome | consistent? |
|---|---|---|---|
| `arm2_device_state` (rel 91, by hand) | kill, render, kill, render — ALTERNATING | `Installed`, count 0 | YES — every kill is followed by a success that zeroes the tally, so 2 is never reached |
| `manual_launch_control/state_after` (rel 91 original app, by hand, 6 taps) | kill, render ×3 — ALTERNATING | `Installed`, count 0 | YES — same reason |
| `cycle96_device/state_final` (rel 96) | see below | **`Bad{BootCrash}`** | YES, once tool-induced boots are counted |

**These never disagreed.** Alternating kill/render cannot tombstone under
`0010`; only consecutive failures can. The earlier reading — "apparently similar
kills produced different tombstone behaviour" — compared an alternating sequence
against one that was not alternating.

## What made release 96's sequence non-alternating — the load-bearing suspect

`cycle96_device` ran to `arm:render` + `first-frame` on its last recorded launch
(L6, `hlfn90ouek`), and its state was then pulled with `ios-deploy --download`.
**`arm2_verdict.txt` documents that pulling files can itself relaunch the app**
("pulling the state files relaunched the app after the taps"), and this cycle
independently confirmed it: the manual-launch run recorded **7 activations against
6 taps**.

A tool-induced relaunch that is torn down before the success latch is an
**un-succeeded boot that the counter cannot distinguish from a patch that broke
Dart.** Two of them in a row tombstone a healthy patch.

**Three preserved states are exactly that shape, caught mid-flight:**

    cd137db6_bisect/state_after     cur=1  count=1  last=None
    r91_behavioral/state_after      cur=1  count=1  last=None
    r91_hybrid_device/state         cur=1  count=1  last=None

All three come from runs whose app was SIGKILLed by `idevicedebug`'s own timeout.
And the contrast is preserved too: `cell87130ae8_bisect/state_after` ran the same
procedure and shows `count=0, last=1` — it banked success before teardown. **Same
tooling, different timing, different lifecycle outcome.**

## AMENDMENT 2026-08-18 — one supporting mechanism MEASURED AND WEAKENED

Written after `nonbooting_capture_verdict.md`, whose positive control tested the
claim this section rests on.

**`ios-deploy --download` did NOT relaunch the app when measured.** Immediately
after `ios-deploy --bundle_id … --download=/Documents`, the launch witness was
unmoved (receipt 45 lines, `native launch` ×8) — and the same witness was then
shown to MOVE (+1) on a real launch, so it was not insensitive.

So `--download` is **not reliably a relauncher**, and the "7 activations against 6
taps" observation below is NOT safely attributed to it. What caused the extra
activation is now unexplained.

**What survives:** tombstoning still requires two consecutive un-succeeded boots;
alternating kill/render still cannot reach it; the three mid-flight
`cur=1, count=1` states are still externally-terminated boots. **What weakens:**
the specific attribution of release 96's extra boots to file-pull relaunches.
Release 96's causation is a HYPOTHESIS with one fewer mechanism behind it.

`ios-deploy` is still disqualified as a scored primitive — it carries a
`processcontrol` surface — independently of whether it launched on any given
invocation.

## THE HYPOTHESIS THIS PRODUCES, to be tested and not assumed

> Tombstoning is driven by CONSECUTIVE un-succeeded boots, and **process/tool
> teardown is indistinguishable from app failure to `0010`'s counter.** Release
> 96's `Bad{BootCrash}` is therefore explained by harness-induced boots rather
> than by engine lineage or by the patch being bad.

It is a hypothesis. It is consistent with every preserved state above, and it has
NOT been tested by a controlled run.

**If true it is an operational-safety finding, not merely a harness artifact:**
the same counter runs in production, where swipe-away, the launch watchdog and
jetsam produce exactly this shape — which is the false-backout risk `0010` was
written to reduce, reappearing one level up. Two such events in a row retire a
healthy patch.

## What must NOT be concluded yet

* NOT that `0010` is defective. Its documented intent is to spend one extra crash
  rather than single-strike, and it does that. Whether TWO is the right threshold
  against real-world process death is the open question.
* NOT that release 96's patch was healthy — it was, but that is established by
  `foldability`/`repair`, not by this file.
* NOT any engine-lineage claim. Those were withdrawn (`STATUS.md`).
