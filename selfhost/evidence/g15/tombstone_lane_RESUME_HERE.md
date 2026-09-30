# Tombstone lane — IN FLIGHT, resume at ONE TAP

2026-08-18. Paused mid-sequence to switch to upstream-integration work. **Nothing
below is scored.**

## Exactly where it stopped

Specimen 1 was spent (see `tombstone_lane_S1_T1_inadmissible.md`: the patch failed
to LOAD, was retired single-strike via `report_launch_failure`, and the payload +
trace were deleted with it, so attach could never be established). A SECOND
specimen was then staged and is live:

    updater state   cleared with `ios-deploy --rmtree` (the method that worked for
                    the repair run — NOT the file-by-file afcclient rm used on the
                    specimen that failed to load; that granularity difference is
                    the leading suspect)
    download tap    DONE — receipt hlgmahlhk6 -> arm:render -> first-frame
    patch 1         Installed,  next_boot_patch=1,  count=0,  trace ABSENT
                    (downloaded, arms on the NEXT boot)
    marker          g15_armed PRESENT  -> the next tap RENDERS
    witness         receipt 73 lines / native launch x13

## THE ONE TAP OUTSTANDING

Tap KillswitchProbe, ~20 s, close. It renders WITH the patch active:

* `NEW-kill` on screen -> a known-good, attach-confirmed specimen; the scored
  kills (rows 1-4) start from there;
* `OLD-kill` -> the load failure reproduced, and the syslog names the cause.

**Restart the syslog capture BEFORE that tap** — it was stopped when this was
parked, and it is the only thing that can name a load failure now that the
payload gets deleted on tombstone:

    nohup idevicesyslog -u 8cb4bc982ddf6437b1952520edee80f898196c74 \
      > /Volumes/build/route-b/tombstone/syslog/run3.log 2>&1 &

Do NOT use `-p killswitch_probe` — the process is `Runner` and the filter matched
nothing. Capture unfiltered and grep afterwards. `idevicesyslog` is safe inside a
scored sequence: its services are `os_trace_relay` + `syslog_relay` only, with
zero launch/attach paths (verified).

## Capture command between taps

    /Volumes/build/route-b/tombstone/capture.sh <label>

Uses the qualified non-booting primitive and self-certifies with a
witness-before/after. See `nonbooting_capture_verdict.md`.

## Why the taps must be manual

Every launcher here carries a process-control surface; a tool-driven launch would
manufacture the pre-success process death the experiment is measuring. See
`tombstone_lane_PARKED.md`.

## What this lane already produced, and it stands

* `0010`'s state machine reconciled from preserved evidence — tombstoning needs
  TWO CONSECUTIVE un-succeeded boots, so the earlier "similar kills, different
  behaviour" was comparing an alternating sequence against one that was not;
* a qualified non-booting observer, with the positive control that overruled my
  own `--download` inference;
* **the two-mechanism finding**: `0010`'s threshold protects only the
  breadcrumb-INFERENCE path; `report_launch_failure()` retires a patch
  single-strike and bypasses the counter entirely. Only one was under study.
* the first on-device `__patch_install_failure__`, which `UPDATER_CONTRACT.md`
  had recorded as never observed.
