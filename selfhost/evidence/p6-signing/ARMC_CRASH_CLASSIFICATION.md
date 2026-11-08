# The three unexplained launch crashes — classified, kept outside Signing

Three by-hand launches during the Arm C reproduction ended before the app
rendered. Classified before the cell is replaced, so the evidence could not be
lost.

## What the device holds

`idevicecrashreport` pulled **51** reports. For 2026-08-27:

    SpringBoard-2026-08-27-143822.ips
    SiriSearchFeedback-2026-08-27-114112{,.000}.ips
    xp_amp_app_usage_dnu-2026-08-27-121333.ips
    Retired/xp_amp_app_usage_dnu-2026-08-27-002040.ips
    awdd-2026-08-27-051940-*.consolidated.metriclog*

* **No report names `signProbeApp`** — `grep -rl signProbeApp` over all 51 finds
  nothing.
* **No `Runner-2026-08-27-*` report at all.** The only `Runner` reports are
  2026-08-25 and 2026-08-26, from earlier lanes.
* **No jetsam event** was pulled.

## Classification per the four categories

| category | verdict |
|---|---|
| actual app/native crash | **NO** — a native crash in updater/Route B/engine init would have produced a `Runner-*.ips` with a stack. None exists for today |
| OS kill / jetsam | **NO evidence** — no jetsam report |
| launch-service failure | **PLAUSIBLE for at least one.** `SpringBoard` itself crashed at **14:38:22** with `EXC_BREAKPOINT` — SpringBoard going down tears the foreground app with it, and 14:38 is inside the first Arm C sequence. That report does not mention our bundle, consistent with the app being collateral rather than the cause |
| no crash report | **YES, for all three** |

The SpringBoard crash accounts for at most one of the three; the two at
~15:19–15:21 have no corresponding report of any kind.

## Why this is independent of the proven attribution result

Across all three, the lifecycle was undamaged and the following launch succeeded:

    patch 1 : kind=Installed, reason=None
    boot_attempt_count : 0
    Bad{BootCrash}     : never produced

`detect_boot_crash_on_init` tombstones a patch when
`currently_booting_patch` survives a process, so its silence means the crashes
occurred **before the updater considered a patch boot underway**. Every
measurement in `ARM_C_EXECUTION_IDENTITY.md` came from launches that completed
and logged their full sequence.

## Disposition

Documented and kept **outside** Signing: there is no evidence pointing into
updater, Route B, or engine initialization, and the one report that exists in the
window is a SpringBoard failure that does not name our app.

**Not** declared harmless. The standing rule: if these recur on the new-cell
rejection run, stop and investigate before P6 closes. Three unexplained launch
failures on the signing rig is a real signal even when no single one is
attributable.
