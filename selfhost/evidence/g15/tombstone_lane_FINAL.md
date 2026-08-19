# Tombstone / retry lane — one result banked, one question parked

2026-08-19. Final state. **Two conclusions, deliberately kept separate.**

---

## PROVEN — ordinary termination after success does not retire a healthy patch

Operator sequence, executed by hand on release 100 (`1.0.9+1`, LC_UUID
`d748bb65…`) with patch 1 active and healthy.

> **Nine consecutive ordinary manual terminations during the fixture's
> delayed-main window produced ZERO false backouts.** The patch remained
> `Installed`, `boot_attempt_count=0`, `currently_booting_patch=None`, no failure
> events accumulated, and the final let-it-run launch completed normally.

### TWO WINDOWS, AND THEY ARE NOT THE SAME THING

This distinction is the whole reason the finding is stated as it is:

| window | duration | what proves it |
|---|---|---|
| **the fixture's delayed-main window** | 5 s, `delayed-main-entered` → `window-survived` | **the RECEIPTS.** Nine launches recorded `delayed-main-entered` with NO `window-survived` — terminated during the delay, not merely closed afterwards |
| **the pre-success window** | ~60-70 ms | **NOT what was hit.** The updater state proves success had already banked before each termination |

**The operator terminated during the delayed-main window. The operator did NOT
terminate before success.** Saying "inside the pre-success window" would claim the
second from evidence for the first.

### The nine

    first four   hlh8sdvr5c  hlh8wrznsu  hlh8wosy4i  hlh8shetor
    then five    hlh92mujgh  hlh92o7qoj  hlh92plos4  hlh92qmlt7  hlh92rjnfp

The second five were the operator's fastest attempts. **No per-launch syslog
timing exists for them** — the capture had been stopped — so no millisecond figure
is assigned to them here.

### Why success had banked anyway, without that timing

`BOOT_FAILURE_THRESHOLD = 2`. Five genuinely pre-success deaths in a row could not
end with a healthy `Installed` patch and a clean counter — the third would have
tombstoned it. The final state was:

    patch 1     Installed          (never Bad)
    pointers    next=1  last=1  count=0  cur=None
    queued      0 events
    final tap   NEW-kill rendered normally

The state machine, not the clock, is what rules out pre-success deaths here.

For the first four, syslog DID record timing: launch start → successful launch in
**56-129 ms**, with the operator acting ~2 s in.

### What it answers

"Does swiping my app away break my patch?" — **measured no, nine times.**

## UNMEASURED on this rig — termination BEFORE success

The lane's actual question — do two consecutive PRE-success process deaths retire
a healthy patch — **remains unanswered, and cannot be answered here.**

### The correction that closed it

The 5-second window was REAL: the receipt shows `delayed-main-entered` →
(5 s) → `window-survived`, and the operator's force-quits landed inside it.

**But that delay was never the success window.** Success is
`earliest(main completion, first framework frame)`, and the fixture change only
postponed the first condition. Measured on pid 3701:

    43.0339  ROUTEB: applied 1/1 targets, entering main
    43.0960  [shorebird] Reporting successful launch      <- 62 ms

Success banked 62 ms in, while Dart was still awaiting. Across the sequence the
interval was **56-129 ms**.

`_drawFrame` — the frame seam — banks success on the engine's frame pump and is
**independent of `runApp()`**. Delaying `runApp` therefore cannot widen the
pre-success window by any amount. The frame seam had already won before the
delay mattered.

### Why no operator can close this

~60-70 ms versus a human visual reaction floor of ~250 ms, and a force-quit
gesture (swipe up, flick card) costing 1-2 s. **The gap is roughly thirty times
the theoretical human limit.** This is not an operator-skill problem and no
amount of practice changes it.

---

## PREREQUISITE for ever running rows 1-4

One of these must exist first. **More taps will not answer it.**

1. **A non-debugger external killer able to act within ~60 ms of launch.** Every
   launcher on this rig carries a process-control surface (`idevicedebug`,
   `ios-deploy`), and a debugger-attached launch manufactures the very
   pre-success death being measured — see `nonbooting_capture_verdict.md`.
2. **A separately designed experiment that intentionally changes the
   frame-success seam** (`_drawFrame`). That modifies the mechanism under test,
   so it must be its own claim with its own precommit — not folded into this one.

Until one exists, this lane is parked.

---

## Status of the whole lane

| item | status |
|---|---|
| post-success termination is safe | **PROVEN** (above) |
| rows 1-4 (pre-success deaths) | **UNMEASURED — structurally unreachable here** |
| row 5 (counter reset) | unrun |
| row 6 (teardown masquerade) | unrun |
| `0010`'s threshold arithmetic | never observed in flight |

## Instrument findings banked separately

`tombstone_instrument_findings.md` — the synchronous-`main` 52-66 ms window;
self-SIGKILL disqualified as a process-death primitive (and the discarded
`killPid` boolean); device-state churn; and the RETRACTED claim that success is
never logged natively (it is — nine occurrences in `run4.log`).

## What the fixture keeps

`killswitch_probe` now has an async `main` with a 5-second pre-`runApp` window and
a `delayed-main-entered` witness. **It does not widen the success window** — but it
is what made the operator's in-window terminations attributable rather than
guessed, and it is what produced the PROVEN result above. Worth keeping for that.
