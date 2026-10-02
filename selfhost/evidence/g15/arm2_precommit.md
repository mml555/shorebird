# G15 arm 2 — the launch sequence, precommitted BEFORE it runs

Written before the device sequence. **Do not edit to match reality.**

## Identity

| field | value |
|---|---|
| cell | `80e493e4c5c9e4c418c433bf660392067a131dd5` (patches `0009` + `0010`), AUDIT CLEAN |
| release | `killswitch_probe` 1.0.1+1, app `014c8ed9-2dea-ec30-fe74-3a7f5e7a77e3` on `cps-ios` |
| device | `R1` iPhone 7 / iOS 15.8.8, **wired** (`8cb4bc98…`) |
| fixture | `selfhost/fixtures/killswitch_app`, marker alternation |

## What each launch is for

The fixture alternates: **marker absent → SIGKILL; marker present → consume it and
render.** So launches alternate kill / render without anyone touching the sandbox.

| # | expected | what it establishes |
|---|---|---|
| A | process dies, no UI | the kill mechanism works on device **at all**. Without this, nothing later is readable |
| B | renders `OLD-kill`, **no** MARKER FAULT banner | the fixture is sound: marker persisted, alternation works, and the fault surface is silent. **A red banner here voids every later arm** |
| — | cut patch 1 (`NEW-kill`) | — |
| C | process dies | patch downloads; the kill re-arms |
| D | renders `NEW-kill` | the patch is live and running. Baseline for the arm — without it, D showing `OLD-kill` means the patch never applied and arm 2 is untestable |
| **E** | process dies | **THE ARM.** The patch is active and the process dies before `Engine::Run` returns, so the boot records neither success nor failure and the breadcrumb is left set with `boot_attempt_count = 1` |
| **F** | **renders `NEW-kill`** | **THE VERDICT.** The good patch survived a death inside the success window |

## Precommitted verdicts for F

| observation at F | verdict |
|---|---|
| renders **`NEW-kill`** | **ARM 2 PASSES.** `boot_attempt_count` (1) is below `BOOT_FAILURE_THRESHOLD` (2), so `detect_boot_crash_on_init` cleared the breadcrumb and retried instead of tombstoning. This is what patch `0010` exists to do |
| renders **`OLD-kill`** | **ARM 2 FAILS, and the design is wrong.** The patch was marked `Bad{BootCrash}` for a death it did not cause — the exact false backout `0009` would introduce without `0010`. This is a failure OF THIS DESIGN, not a success of the safety mechanism |
| MARKER FAULT banner | **not an arm result.** The fixture broke; fix it and re-run rather than interpreting |
| does not render at all | **not an arm result.** Investigate the install first |

## Repeat requirement

G15's design says arm 2 must run **more than once** — a single survival is consistent
with the kill having landed outside the window by luck. Launches G and H repeat E and
F. **Both F and H must show `NEW-kill`**; one of two is not a pass.

## What no outcome here can claim

* Nothing about **crash-backout** — the other half of G15. That needs a patch that
  genuinely breaks Dart, which this fixture does not produce.
* Nothing about **restart-required** (§8).
* Nothing about a patch that SHOULD be tombstoned still being tombstoned; that is the
  complementary arm (a real Dart-phase failure reaching the threshold) and is not run
  here.
