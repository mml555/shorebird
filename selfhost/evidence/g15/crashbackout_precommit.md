# G15 crash-backout — precommitted BEFORE the run

The complementary arm to arm 2. **Do not edit to match reality.**

## What is being tested, and why it is a DIFFERENT mechanism

Arm 2 exercised the **ambiguous** path: the boot reported nothing, so
`boot_attempt_count` decides whether to tombstone. This arm exercises the
**positive** path: patch `0009` calls `ReportLaunchFailure` when `Engine::Run`
returns `Failure`, which routes to `record_boot_failure` and marks
`Bad{BootCrash}` **immediately**, without consulting the counter.

That asymmetry is deliberate and worth stating: *absence of evidence* gets retried,
*evidence of failure* gets acted on at once.

## Why a new target was needed

`routeBValue()` is called from `build()` — **after** `Engine::Run` has returned and
success has already been banked. A patch that throws there is a RUNTIME failure, not
a BOOT failure, and G15 deliberately does not back those out.

`bootProbe()` is called from `main()` before `runApp`, so it executes while
`Engine::Run` is still on the stack.

## Identity

| field | value |
|---|---|
| cell | `80e493e4…` (`0009` + `0010`) |
| release | `killswitch_probe` 1.0.3+1 |
| patch | `bootProbe()` replaced with a body that throws |
| device | `R1` iPhone 7, wired |

## Precommitted outcomes

**The genuinely uncertain part** is whether an unhandled exception thrown by `main()`
makes `Engine::Run` report `Failure` at all. `Run` may consider the entrypoint
successfully *invoked* and report success regardless of what the isolate does next.
Both readings are plausible from the source, so both are written down:

| observation | verdict |
|---|---|
| the patch is marked **`Bad{BootCrash}`** after ONE launch, and the next launch shows the RELEASE value (`boot: boot-ok`, `OLD-kill`) | **CRASH-BACKOUT WORKS.** A Dart-phase failure caused by a patch backs it out, immediately and without waiting for the threshold. This closes §15's "a Dart-phase crash backs the patch out" |
| the patch is marked `Bad` only after **TWO** un-succeeded launches | crash-backout works, but via the COUNTER rather than via `ReportLaunchFailure` — meaning `Engine::Run` did NOT report `Failure` and the throw registered merely as "no outcome". Still a pass for the gate, but the mechanism is not the one `0009` intended, and that distinction should be recorded rather than smoothed over |
| the patch stays **`Installed`** across repeated crashing launches | **CRASH-BACKOUT DOES NOT WORK.** A patch that breaks Dart is never backed out. §15's gate stays OPEN and `0009`'s seam is in the wrong place for this half — a real finding, and the most valuable failure available here |
| the app renders normally with `boot: boot-ok` | the patch did not apply. NOT a result — check the patch published and downloaded before interpreting |
| MARKER FAULT banner | fixture failure, not an arm result |

## How the answer will be read

From the device's own state, not the screen alone:

* `patches/2/state.json` — `Installed` vs `Bad{BootCrash}`
* `pointers.json` — `boot_attempt_count`, `last_boot_attempt_patch`, `next_boot_patch`
* `state.json` — `queued_events`, which should carry a `PatchInstallFailure` with
  `crash_recovery: patch 2 failed to boot` if a backout happened

**Pull `pointers.json` BETWEEN launches this time.** Arm 2's counter had already been
reset to 0 by a later success, so the threshold arithmetic was never caught in
flight. Reading between launches is the fix, and it is the one thing arm 2 could not
show.

## Not claimed regardless of outcome

Nothing about restart-required (§8). Nothing about `0009` in isolation — it ships with
`0010` in one cell.
