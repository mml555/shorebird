# run_006 — a disappearance was reported. It classifies as **G**, and it is NOT clearly the historical phenomenon.

Reported by the operator as *"crashed on tap one"* — the **acquisition** tap of
generation 006, i.e. the launch that runs the already-established patch 4
(`ACT-V5`) while patch 5 downloads in the background.

**Reproduction phase stopped on report, per the stop rule. No further launches
were made before collection.**

## Furthest durable boundary reached

The Dart engine restarted **inside the same OS process**, which the timeline shows
plainly and which matters for reading everything below:

    01:27:40  PROCESS_BEGIN            pid 50643   (this is B_005's process)
              ... ACT-V5, FIRST_FRAME, heartbeats +0..+5000ms all present
    01:33:58  APP_LIFECYCLE inactive
              MEMORY_PRESSURE
              hidden / paused / hidden / inactive / hidden / paused
              MEMORY_PRESSURE
              APP_LIFECYCLE detached          <- Dart tears down. NO WILL_TERMINATE.
    01:33:59  FLUTTER_ENGINE_INITIALIZED      native mono_us=378,413,079
              PROCESS_BEGIN  seq RESET to 0   <- Dart restarts, SAME pid
              DART_MAIN_ENTERED   ACT-V5
              FIRST_FRAME         ACT-V5      +16ms
              heartbeat +0ms, +100ms, +250ms, +500ms
              MEMORY_PRESSURE
              APP_LIFECYCLE hidden
              APP_LIFECYCLE paused
              UIAPP_WILL_TERMINATE            <- PRESENT
              APP_LIFECYCLE detached

The native `mono_us` of 378 s at `FLUTTER_ENGINE_INITIALIZED` is the tell: the
native side's process-start static was **never reset**, so the OS process survived
while the Dart VM was torn down and rebuilt. `seq` restarting at 0 is the Dart
side of the same event.

| boundary | reached |
|---|---|
| engine preparation | yes |
| Route B entered / `rc=0` | yes — patch 4 trace, 3 records, latest `rc=0` |
| Dart `main` | yes, twice |
| first frame | yes, twice |
| launch success | **cannot be distinguished** — see below |
| +0 / +100 / +250 / +500 ms heartbeats | yes, in the second Dart block |
| +1000 / +2000 / +5000 ms | **no** in the second block |
| last Dart lifecycle callback | `detached` |
| last native lifecycle callback | **`UIAPP_WILL_TERMINATE`** |
| disappearance time | ~01:33:59.97, ≈610 ms after the second `PROCESS_BEGIN` |
| new native crash report | **none** |
| new Jetsam report | **none** |
| watchdog evidence | none observed |
| SpringBoard termination reason | not captured — see the gap below |

## Bucket: **G** — post-success system/lifecycle termination

`UIAPP_WILL_TERMINATE` is **present**, immediately preceded by `MEMORY_PRESSURE`
and the `hidden`/`paused` transitions. That is an **orderly, system-initiated
termination**: iOS asked the app to terminate and it did. It is not a crash — and
no crash or Jetsam report exists, consistent with a termination rather than a
signal.

This is assigned **G** on the strength of a positively observed termination
callback, not by inferring from an absence.

## Why this is NOT clearly the historical phenomenon

Stated plainly, because the temptation is to file it as a reproduction and it does
not fit:

| | historical (3×) | run_006 |
|---|---|---|
| launch type | first activation of a NEW patch | **acquisition** launch of an ESTABLISHED patch |
| `WILL_TERMINATE` | unknown (no instrumentation) | **PRESENT** |
| `MEMORY_PRESSURE` | unknown | **PRESENT**, twice |
| crash report | none | none |
| bucket | **H**, cause unclassified | **G**, orderly termination |

The historical occurrences were on first activations and left the following launch
clean. This was an acquisition launch, arrived with an explicit termination
callback, and followed ~6 minutes of the app sitting idle in the foreground while
I was writing commits — which is a plausible ordinary memory-pressure eviction.

**So run_006 does not count as a reproduction of the historical disappearance.**
Controlled population A remains 0 disappearance / 3.

## The certified runtime is UNDAMAGED — no hard-stop condition met

    pointers   next_boot_patch=4  last_booted_patch=4
               currently_booting_patch=null  boot_started_at=null
               boot_attempt_count=0  last_boot_attempt_patch=null
    patch 4    Installed, artifact present, 03b9af93ba00fb23… 1727 bytes
    patch 3    reclaimed earlier, correctly
    patch 5    ABSENT
    rbtrace    patch 4, 3 records, latest rc=0
    frozen surfaces  INTACT, engine byte identity VERIFIED

None of: wrong attribution · `currently_booting_patch` left set · `Bad{BootCrash}`
· consumed retry · deleted last-known-good · wrong patch selected · Route B
failure before main · frozen-surface or engine-byte failure.

**Patch 5 was never acquired.** The server still offers it, and there are **no
`__patch_download__` or `__patch_install__` events for patch 5** — so generation
006 never began. The termination happened before the download completed, which is
itself consistent with an eviction rather than anything patch-related.

## Two limits on this packet, both mine

**1. The acquisition tap was not armed.** I only armed captures for the A and B
runs, so this launch has **no syslog** and therefore no SpringBoard/jetsam
termination-reason line — the one piece of evidence that would separate F from G
positively rather than by callback. That is a real oversight: `ARM_C_EXECUTION_IDENTITY.md`
explicitly recorded one historical occurrence *"on the patch-2-install tap"*, so
acquisition launches were always in scope and I should have armed them. **Fix
before resuming: arm every tap, including acquisition.**

**2. Launch success is indeterminate for the second Dart block.** `report_launch_success`
is guarded once per PROCESS, and the OS process here was shared across both Dart
lifetimes — so the second block could not have re-reported success even if it
reached the trigger, and `success_diag`'s last entry (`pid=50643 patch=4`) belongs
to the first block. Correlating the timeline to `success_diag` **by pid** silently
breaks when Dart restarts in-process. That assumption is written into the harness
README and needs correcting.
