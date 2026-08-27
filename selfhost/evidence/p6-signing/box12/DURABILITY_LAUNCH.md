# Box 12, durability half — PASSED. Criterion 12 is closed.

pid **49259 @ 18:24:19**, a fresh process with patch 2 already tombstoned.

## Primary evidence — durable artifacts

    Preparing next boot.
    Verifying patch signature...
    Patch signature is valid
    Prepared boot of patch 1.
    active path: …/shorebird_updater/patches/1/dlc.vmcode
    active patch is a Route B container
    Patch 2 is known bad, skipping.
    Update thread: Update available but previously failed to install. Not installing.

    pointers      next_boot_patch=1  last_booted_patch=1
                  currently_booting_patch=null  boot_attempt_count=0
    patch 1       Installed, dlc.vmcode PRESENT, 1687 B
                  c97c93f10b3248082fd5f54fe59274f042cd03a6b0189db552c7a2db71ac5a7e
                  identical to the pre-acquisition anchor and to the post-rejection
                  value — the artifact has never changed
    patch 2       Bad{ValidationFailed}, artifact absent, NO activation trace
    rbtrace       5 records, all patch 1; latest rc=0 bc_post=1 interp_post=1
                  tpool_matches=1
    success_diag  pid=49259 patch=1 raw_boot_attempt=1 prior_ambiguous_attempts=0

## Behavioural corroboration — render, objectively captured

`durability_render_SIGN-V2.png`, taken with `idevicescreenshot` while the process
was on screen at 18:24:

    release:     SIGN-REL-1
    sign state:  SIGN-V2

Captured rather than reported. `SIGN-V3` — patch 2's marker — appears nowhere: not
on screen, not in seven launches of syslog, and patch 2 never produced a Route B
activation record.

A capability note worth keeping: `idevicescreenshot` works on this device.
`BEHAVIORAL_FINDINGS.md` records screenshots as unavailable, but that was for a
**network-paired** phone; wired, it works. Render evidence therefore no longer
depends on anyone reading a screen.

## The call-path row, final aggregate

    "Preparing next boot."      7      across 7 distinct Flutter pids
    "Reporting launch start."   0
    "SIGN-V3"                   0

The three-call sequence is absent from the running engine, measured over seven
processes.

## Criterion 12, row by row

| # | requirement | result |
|---|---|---|
| 1 | `Prepared boot of patch 1` | PASS |
| 2 | active path == P1 | PASS |
| 3 | rbtrace P1 `rc=0` | PASS |
| 4 | `success_diag` credits patch 1 | PASS |
| 5 | `last_booted_patch = 1` | PASS |
| 6 | `currently_booting_patch = null` | PASS |
| 7 | patch 1 `Installed` | PASS |
| 8 | `patches/1/dlc.vmcode` present | PASS |
| 9 | P1 digest unchanged | PASS |
| 10 | patch 2 `Bad{ValidationFailed}` | PASS |
| 11 | patch 2 has no activation trace | PASS |
| 12 | render `SIGN-V2` | PASS (screenshot) |
| 13 | `SIGN-V3` absent everywhere | PASS |
| 14 | `Reporting launch start.` absent | PASS |

## What the pair of launches proves together

> A patch whose only defect was a signature invalid under the release's baked-in
> public key was downloaded, installed, refused at boot, and tombstoned — and the
> last-known-good patch continued to run, on that launch and the next, with its
> artifact intact.

That is the defect `ARM_C_DEVICE_SIGNATURE.md` box 12 recorded as FAILING, closed
on hardware with the same fixture, the same device and the same intentional
defect. Only the runtime changed.

## Carried forward, unresolved

The **launch disappearance** (`crash_reports/setup_crash_2026_08_27/CLASSIFICATION.md`)
is a real reliability defect, tracked outside Signing. It did not recur across the
rejection or durability launches. Evidence places it downstream of every stage
Signing certifies, and it produced no crash report on two pulls.
