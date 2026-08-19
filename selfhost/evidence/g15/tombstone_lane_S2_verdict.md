# Tombstone lane, sequence 2 — row 1 INADMISSIBLE, and a product-safety finding

2026-08-19. Scored against `tombstone_lane_precommit.md`; that table is not edited.

## The two manual taps

### Tap 1 (`hlh82qurh4`) — the specimen is confirmed healthy

    screen     NEW-kill                       (screen_NEW-kill_hlh82qurh4.png)
    receipt    dart-main-entered -> boot-probe-returned:boot-ok
               -> arm:render -> first-frame
    trace      v=5  rc=0  bc_post=1  uep_post_is_interpret_call=1
               tpool_status=4 (UNIQUE)  index=4211  scanned=12480
    pointers   next=1  last=1  count=0        (booted AND banked success)
    patch      Installed

**The load failure from sequence 1 did NOT reproduce.** The only procedural
difference was how updater state was cleared — `ios-deploy --rmtree` here versus
file-by-file `afcclient rm` there. That makes clearing granularity the leading
suspect for the earlier `engine_report` load failure, on ONE observation.

This is the attach-confirmed, known-good specimen sequence 1 never had.

### Tap 2 (`hlh867i2df`) — the kill arm DID NOT KILL

    receipt    dart-main-entered -> boot-probe-returned:boot-ok -> arm:kill
    patch      Bad{BootCrash}
    queued     __patch_install_failure__  "engine_report: patch 1 failed to launch"
    pointers   next=None  last=1  cur=None  count=0

Syslog names the cause exactly:

    ROUTEB: activated routeBValue in package:killswitch_probe/main.dart before main
    ROUTEB: applied 1/1 targets, entering main
    [shorebird] Reporting failed launch.
    Unhandled Exception: Bad state: G15: SIGKILL did not terminate the process

**`Process.killPid(pid, SIGKILL)` did not terminate the process.** The fixture's
own failsafe fired — the one whose comment reads *"if SIGKILL were ever not
delivered, falling through to `runApp` would render a screen that looks like a
normal launch, so the arm would silently become vacuous. Fail loudly instead."*

It did exactly that, and it is why this is a finding rather than a false row.

## VERDICT: row 1 INADMISSIBLE — wrong stimulus, not a failed prediction

Row 1 requires a pre-success **process death** standing in for swipe-away,
watchdog or jetsam. What occurred was an unhandled **Dart-phase exception**, which
is a different input exercising a different retirement path.

**The tombstone was CORRECT for the input it received.** The message discriminates
the path: `engine_report:` (the engine states the patch's launch failed) rather
than `crash_recovery:` (breadcrumb inference). `report_launch_failure()` retires
single-strike by design, and that is right — the engine has direct evidence, not
an inference. `0010`'s threshold governs only the inference path and correctly
did not apply.

**Rows 1-4 are unreachable with this fixture as written**, because it cannot
produce a clean pre-success process death on this engine.

## THE PRODUCT-SAFETY FINDING, which outranks the blocked row

**A patch that activates and then hits a Dart-phase failure leaves the app HUNG at
the launch screen — not crashed — and iOS does not reap it.**

Measured: the process was still alive **three minutes** after the exception,
still servicing UIKit background tasks (`syslog_hung_process_3518.txt`). No
watchdog (`0x8badf00d`), no jetsam. At the system level the app is responsive; it
simply never draws, because `runApp` was never reached.

Consequences for a real user:

1. the app shows a white launch screen indefinitely;
2. the updater has ALREADY retired the patch correctly (`next_boot_patch=null`),
   so the next launch runs the release;
3. **but the user must force-quit to get that next launch.** Self-healing works,
   and it is gated behind manual intervention.

That is a genuine operational-safety gap and it was found by an arm that failed
to do what it was designed to do.

## What this does NOT establish

* NOT that the engine regressed. `arm2_verdict.txt` (2026-08-14) recorded the kill
  arm working — "blank white screen, then gone". Either it genuinely worked then
  and something changed, or the process always died from the exception rather
  than the signal and looked identical from outside. **The two cannot be
  separated from here**, and the earlier observation was an operator screen report.
* NOT that `Process.killPid` never works on iOS — only that it did not here.
* NOT anything about rows 2-6, which remain unrun.

## Next step for this lane

A genuine pre-success process death needs a mechanism that is not the fixture
killing itself. The candidate is the OPERATOR force-quitting during the launch
window — which is also the most production-realistic stimulus for row 6, since
swipe-away is exactly what row 6 is about.

That is a different experimental design and needs its own precommit.
