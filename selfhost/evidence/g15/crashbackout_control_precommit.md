# G15 crash-backout — THE MISSING CONTROL, precommitted 2026-08-14

Written BEFORE the launch. The verdict
(`crashbackout_verdict.txt`) closes with "that the PATCH causes the crash remains
INFERRED, not measured", and names this as the one launch that settles it.

## What is being asked

Does release `1.0.3+1` of `killswitch_probe` boot cleanly **on this device** with
the updater state wiped — i.e. with no patch in play?

If yes, the only difference between a healthy boot and the three observed crashes
is patch 1, and causality moves from inference to measurement **on the same
instrument, same device, same release bytes**.

## State at precommit — read, not assumed

`/Library/Application Support/shorebird/shorebird_updater/` on device holds
`state.json` ONLY. No `pointers.json`, no `patches/`:

```json
{ "client_id": "0792c791-c02f-4e2f-b6d3-b6b718902555",
  "release_version": "1.0.3+1",
  "queued_events": [] }
```

So the `--rmtree` wipe held, the updater has since re-initialized, and **no patch
is installed or selected**. This launch boots the pristine release.

## Outcomes, precommitted

| observation | meaning |
|---|---|
| screen renders `boot: boot-ok` **and** `OLD-kill` | **CONTROL CLOSES.** The release is healthy on this device. Patch 1 is the only difference from the crashing configuration, so "the patch caused the crash" becomes MEASURED. `crashbackout_verdict.txt`'s open control is struck and dated |
| screen renders the red **MARKER FAULT** banner | the fixture's marker path is broken independent of any patch. Attribution stays INFERRED and the fixture must be repaired before any further G15 arm — this is exactly the failure mode rule 2 of the handoff was written for |
| blank white screen again, no render | **the most valuable outcome, and it overturns the verdict's attribution.** The crash would then NOT be patch-caused; something in release `1.0.3+1` or the device state kills it. `crashbackout_verdict.txt`'s causal claim would need retraction, though its PRIMARY finding (success banked three times while Dart failed) is independent of attribution and would still stand |
| app does not launch, no process, no render | **instrument failure, NOT a result.** Per this session's rule 1, a negative device observation needs a positive control on the same instrument: launch `airgap_probe` (PROVEN on device) before interpreting anything. Nothing is concluded about the patch in this branch |

## What this control cannot do

It does not test crash-backout, does not touch the seam, and **upgrades no `G15`
gate**. It closes an attribution gap in an instrument that later seam experiments
will depend on. A clean render here is a precondition for trusting the A/B
experiment that follows, not evidence for any candidate seam.
