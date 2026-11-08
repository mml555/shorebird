# Tombstone / retry lane — PARKED, ready to resume at one tap

2026-08-18. Parked awaiting operator taps. **Nothing here is scored.** The
instrument is qualified and the specimen is staged; only the manual launches are
missing.

## Why it needs a human finger, recorded so it is not re-litigated

Every launcher on this rig carries a process-control surface, and this experiment
measures whether tool-driven process death is distinguishable from a bad patch:

* `idevicedebug` attaches a debugserver and SIGKILLs at its timeout — that SIGKILL
  IS a pre-success process death, the thing under test;
* `ios-deploy --justlaunch` quits the app as lldb detaches;
* `devicectl` does not see this device (iOS 15); XCUITest would need a test-runner
  target compiled into the fixture, which changes the specimen.

A tool-driven run would prove that my launcher kills apps, not that the updater
mis-scores real process deaths. **The taps are load-bearing evidence.**

## STAGED STATE — verified 2026-08-18, do not disturb

    device            iPhone 7 / iOS 15.8.8, 8cb4bc98…, wired
    app installed     release 1.0.8+1 (control-plane id 99, preserved as 99), LC_UUID b68032df…
                      the REPAIRED specimen — known to render NEW-kill
    patch             #1 on stable for 1.0.8+1
    updater state     CLEARED via afcclient (no processcontrol tool touched it)
    alternation       g15_armed PRESENT -> the next tap RENDERS
    witness baseline  receipt 50 lines / native launch x9

## QUALIFIED OBSERVER (see nonbooting_capture_verdict.md)

    /Volumes/build/route-b/tombstone/capture.sh <label>

Uses `afcclient --container` (house_arrest/AFC only). Emits the frozen row fields,
`queued_events`, trace line count, receipt tail, and a witness before/after the
read that self-certifies the capture added no activation. `quit` terminates the
session — without it afcclient holds the connection until timeout.

Between-launch marker control, also non-booting:

    printf 'rm Documents/g15_armed\nquit\n' | afcclient -u <UDID> --container <BID>
    printf 'put armed Documents/g15_armed\nquit\n' | ...

## THE SEQUENCE TO RUN, tap by tap

| tap | expected screen | capture after | scores |
|---|---|---|---|
| T0 | blue, `OLD-kill` | `S1_T0_post` | none — downloads the patch |
| T1 | white, vanishes | `S1_T1` | row 1 — first failed boot (`cur=1 count=1`, still `Installed`) |
| — | *delete marker via afcclient* | — | forces a SECOND kill instead of the fixture's render |
| T2 | white, vanishes | `S1_T2` | rows 2-3 — retry kept the tally, `count` reaches 2 |
| T3 | blue | `S1_T3` | row 4 — `Bad{BootCrash}` + `__patch_install_failure__` at init |

Record the operator's reported screen for each tap — the precommit requires the
manual outcome preserved beside each capture.

**Sequence 2 (row 5, reset semantics) needs a FRESH equivalent specimen**, never
the tombstoned one: clear state again, let it re-download, then kill → render.

## What a landed row 6 would mean, and what it would not

Two SIGKILLs of a patch known to render `NEW-kill`, ending in `Bad{BootCrash}` +
queued failure, would show `0010`'s counter cannot distinguish the SHAPE of a
pre-success process death from a bad patch — a product-level safety statement
deserving a design response.

It would NOT prove an operator swipe-away produces it. The kill arm's cause is
internal; its shape is identical. That confirmation is a separate follow-up.

## Unscored corroboration already in hand

`nonbooting_capture_verdict.md` records a tombstone reached exactly this way
during instrument validation — `Bad{BootCrash}` plus
`__patch_install_failure__ "engine_report: patch 1 failed to launch"`, on the
healthy repaired patch, after an `idevicedebug` teardown. Unscorable **because** a
debugger was in the loop, and useful because it tells the controlled run what it
must be capable of disproving.
