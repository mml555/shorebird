# Non-booting state-read primitive — VERDICT: QUALIFIED

2026-08-18. Scored against `nonbooting_capture_precommit.md`; that table is not
edited here.

## VERDICT: `afcclient --container` IS QUALIFIED for inter-launch capture.

    afcclient -u <UDID> --container dev.selfhost.killswitchProbe   (stdin: get ...)

## Stage 1 — host-side inspection, and it gives ios-deploy's relaunch a MECHANISM

Services each binary references:

    afcclient    com.apple.afc, com.apple.mobile.house_arrest        <- container access ONLY
    ios-deploy   com.apple.afc, com.apple.debugserver,
                 com.apple.instruments.remoteserver,
                 com.apple.instruments.server.services.processcontrol <- PROCESS CONTROL

`afcclient` shows no launch, attach, debugserver or instruments path; its only
install-adjacent string is the error `InstallationLookupFailed`, from the
house-arrest lookup rather than an install action.

**`processcontrol` is the launch service.** That is why a "file download" could
ever start a process — not folklore, a service surface.

## Stage 2 — negative control, and the sensitivity proof that makes it non-vacuous

Launch witness: `killswitch_probe`'s append-only receipt, whose NATIVE half writes
`native launch` on every launch before any Dart runs; plus the Route B trace,
which appends per activation.

    capA   receipt=45  native_launch=8   trace=1
    capB   receipt=45  native_launch=8   trace=1     <- two consecutive captures, UNMOVED

**A control that cannot fail proves nothing**, so the witness was then shown to
MOVE on a real launch:

    capD   receipt=50  native_launch=9               <- +5 lines, +1 launch

The witness is sensitive; the primitive's stillness is therefore a measurement and
not an insensitivity artifact.

All six criteria met: no launch path (1), no install/attach/updater action (2),
idempotent across repeats (3), app not activated as measured by a sensitive
witness (4), the EXACT scored command line tested (5), and failure would have been
visible via the witness (6).

## A CORRECTION TO MY OWN RECONCILIATION, forced by the positive control

`tombstone_lane_reconciliation.md` leaned on the claim that
`ios-deploy --download` relaunches the app. **Measured here, it did NOT:**

    capC (immediately after `ios-deploy --bundle_id … --download=/Documents`)
         receipt=45  native_launch=8  trace=1        <- UNMOVED

So `--download` is **not reliably a relauncher**, and the "7 activations against 6
taps" observation is NOT safely attributed to it. What produced the extra
activation is now **unexplained** — candidates include iOS prewarming, a launch not
counted by the operator, or a different tool invocation in that sequence.

The reconciliation's core finding is unaffected: tombstoning still requires two
consecutive un-succeeded boots, and alternating kill/render still cannot reach
it. What weakens is only the specific attribution of release 96's extra boots.
**Release 96's causation remains a HYPOTHESIS**, now with one fewer supporting
mechanism than when it was written.

`ios-deploy` remains DISQUALIFIED as a scored primitive on stage-1 grounds — it
carries a process-control surface — regardless of whether it launched on any
particular invocation.

## AN UNSCORED OBSERVATION, obtained during validation

The deliberate launch used for the sensitivity proof (`idevicedebug`, 40 s
timeout, SIGKILL at teardown) left, read via the qualified primitive:

    patches/1/state.json   Bad{BootCrash}
    pointers.json          next_boot_patch=null, last_booted=1, count=0
    state.json             queued_events: [ __patch_install_failure__,
                             "engine_report: patch 1 failed to launch" ]

Three things are notable and NONE of them is a scored row:

1. **Row 4's full expectation is met**, including the `PatchInstallFailure` event —
   the first queued failure event observed in this investigation. `arm2_verdict.txt`
   cited `queued_events: []` as evidence that NO backout had occurred; this is the
   positive counterpart.
2. **The patch retired was the REPAIRED, HEALTHY one** — the specimen that rendered
   `NEW-kill`. It was not bad.
3. It was retired following externally-terminated boots.

**This is corroboration, not a result.** It was not precommitted, its launch
sequence was not controlled, and no state was captured between the launches that
produced it. It is recorded because it happened and preserving it costs nothing —
and because it is exactly the shape row 6 predicts, which is a reason for
suspicion of my own reading, not for confidence.

The scored lifecycle sequence still has to be run properly, by hand, with this
primitive between launches.
