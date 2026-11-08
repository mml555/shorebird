# Crash-report preservation — ATTEMPTED, and the historical reports are LOST

Recorded as a negative result rather than dropped, because the Arm C crashes were
supposed to be classifiable and now are not.

## What was asked

Preserve the crash reports behind the three undiagnosed crashes observed during
the Arm C execution-identity reproduction (`ARM_C_EXECUTION_IDENTITY.md` §"Two
crashes"), before rebuilding the cell.

## What was found — 2026-08-27 16:1x, device wired

    device : 8cb4bc982ddf6437b1952520edee80f898196c74
             iPhone 7, iphoneos 15.8.8 (19H422), connected through USB

    idevicecrashreport --keep <dir>     (--keep: copy, do NOT remove)
      Copy: /SiriSearchFeedback-2026-08-27-155740.000.ips
      Copy: /SiriSearchFeedback-2026-08-27-155740.ips
      Done.

    total files retrieved            : 2
    matching sign_probe / Runner / probe / flavored / manual : 0
    host archive ~/Library/Logs/CrashReporter/MobileDevice/  : does not exist

Both retrieved files are unrelated system telemetry from today. The device's
CrashReporter store holds nothing from the Arm C window, and no host-side copy
was ever made — that directory is only populated by Xcode's *View Device Logs*,
which was never opened for this device.

## Consequence, stated plainly

**The three Arm C crashes cannot be diagnosed.** They were observed, described,
and are now unrecoverable. Whatever they were, the evidence is gone, and no
later reasoning may claim they were benign — `ARM_C_EXECUTION_IDENTITY.md` only
ever claimed they did not affect the measurements it recorded, which remains
true because the lifecycle state was pulled and checked after each one.

This is a preservation failure, not a device fault: the reports should have been
pulled during the Arm C session, while they existed.

## What this changes about the stopping rule

`BOX12_DEVICE_GATE_PRECOMMIT.md` states a three-way crash rule. Only the third
branch is now reachable for the historical crashes, so the rule is narrowed to
what the evidence can still support:

* the historical three: **UNCLASSIFIED, permanently.** Not "benign", not
  "external" — unclassified.
* any crash on the new box 12 run: pull the report **immediately, before the next
  launch**, and classify it then. The branches (updater/Route B/engine-init →
  blocker; external launch/permission → documented and outside Signing; recurring
  and unexplained → stop before P6 closure) apply to those.

## Procedure change, so this does not repeat

Pull crash reports as part of every device launch cycle, not at the end of a
lane:

    idevicecrashreport --keep <evidence-dir>

`--keep` matters: the default MOVES the reports off the device, which is fine for
archiving but destroys the only copy if the pull is interrupted.
