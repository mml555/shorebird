# Non-booting state-read primitive — PRECOMMIT

2026-08-18, **before a primitive is chosen and before it is used to score
anything.** The lifecycle experiment cannot start until this is settled, because
its row 6 asks whether teardown is distinguishable from app failure — and a
capture that boots the app would manufacture the very transition being measured.

**The property to prove is ABSENCE OF LIFECYCLE ACTIVATION, not "reads files".**
`ios-deploy --download` reads files and still relaunched the app
(`arm2_verdict.txt`; 7 activations against 6 taps this cycle). Those are not the
same property.

## QUALIFICATION CRITERIA — all six, or the candidate is refused

1. **No launch API/path invoked.** Inspection of the tool must show only
   persisted container/sandbox access — no launch, no `debugserver`, no
   `instruments`.
2. **No install, attach, debugger or updater action occurs.**
3. **Repeated reads are idempotent** — two consecutive captures change no
   lifecycle state.
4. **The app remains non-running** across the read, measured by a launch witness
   (below), not asserted.
5. **The EXACT scored command line is tested** — wrappers, flags and bundle-id
   forms count, not "this tool is normally read-only".
6. **Failure is visible.** If container access cannot be had without something
   that may launch the app, **REFUSE the observation** rather than substitute a
   more convenient command.

## THE LAUNCH WITNESS — already exists, no new instrumentation

`killswitch_probe`'s receipt is APPEND-ONLY and its NATIVE half writes
`native launch` / `native engine` on **every** launch, before any Dart runs
(`prepare_killswitch_fixture.sh` injects it). The Route B trace appends one line
per patch activation, and `_launchId` is regenerated per process.

So the invariant is: **receipt line count and trace line count must not move
across two consecutive captures.**

This detects a booting primitive even if the boot happens after its file read:
capture 2 would carry capture 1's appended lines.

## TWO-STAGE PROOF

**Stage 1 — host-side inspection selects the candidate.** Establish from the tool
itself whether its path is container-only. Candidates present on this host:

    afcclient        references house_arrest + com.apple.afc   <- leading
    idevicebackup2   full-backup service, heavier, may alter state
    ios-deploy       KNOWN to relaunch on --download            <- disqualified as scored primitive

**Stage 2 — explicit negative control before the first scored sequence.** With the
app NOT running: capture, capture again, and prove receipt and trace line counts
are identical across the pair.

## PRECOMMITTED OUTCOMES

| observation | verdict |
|---|---|
| stage 1 shows container-only path AND stage 2 shows both witnesses unmoved | **PRIMITIVE QUALIFIED** — usable for inter-launch capture in the lifecycle experiment |
| either witness moves across the pair | **REFUSED.** The tool boots the app; it may not be used to score lifecycle |
| stage 1 shows any launch/attach path | **REFUSED** without running stage 2 |
| no candidate qualifies | **RECORD THE RESULT, do not work around it**: *"Current harness cannot observe inter-launch updater state without potentially changing the lifecycle being measured."* That is a real finding about the observation apparatus, not a tooling inconvenience, and it bounds what the lifecycle lane can claim |

## Note on scope

This precommit qualifies a MEASUREMENT INSTRUMENT. It scores no lifecycle
transition and says nothing about `0010`. Release 96's tombstone remains a
HYPOTHESIS — the corpus explains how it could have happened and removes the
earlier contradiction, but causation is not established until the teardown path
is reproduced with uncontaminated between-launch state.
