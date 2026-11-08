# run_007 validation control — VOID. Operator-induced termination, not a disappearance.

> **RESOLVED BY THE OPERATOR after this was written.** They force-quit the app.
> That is the whole explanation, and the syslog already said so: the
> `DismissSwitcherNoninteractive` + `SBWorkspaceDestroyApplicationEntity` pair
> below is an **app-switcher force-quit**. `UIAPP_WILL_TERMINATE` was present
> because the termination genuinely was orderly — the operator asked for it.
>
> **This run is VOID as an observation.** It is not a disappearance, not a
> reproduction, and it does not count in any population. The validation control
> must be re-run.
>
> What I got wrong: I treated "it crashed" as a spontaneous event and went hunting
> for a system terminator, when the first question should have been *did a human
> close it?* I even found the switcher-destroy evidence and reasoned around it —
> noting it lined up with the "previous" lifetime rather than asking whether my
> lifetime segmentation was the thing that was wrong. The unreconciled Route B /
> first-frame ordering below is very likely the same mis-segmentation.
>
> **Procedure gap this exposes:** the run protocol says "leave it visible ≥6 s,
> do not force-quit until collected", but nothing in the harness RECORDS whether a
> human closed it. A switcher force-quit is detectable in syslog, so `collect`
> should look for it and label the run OPERATOR_TERMINATED automatically rather
> than leaving it to be reconstructed by hand.

# (original analysis, retained)


The validation control disappeared. It is an **established-patch** launch (patch 5,
long since booted), not a first activation. Collected immediately; no further
launches.

## Furthest durable boundary

    16:45:29.059Z  APP_LIFECYCLE detached        <- END of the PREVIOUS Dart lifetime
    16:45:29.947Z  PROCESS_BEGIN  seq=0          <- new Dart lifetime, SAME pid 51041
    16:45:29.948Z  DART_MAIN_ENTERED  ACT-V6
    16:45:29.962Z  FIRST_FRAME        ACT-V6
                   heartbeats +0ms, +100ms, +250ms, +500ms
    16:45:30.515Z  MEMORY_PRESSURE
    16:45:30.518Z  APP_LIFECYCLE hidden
    16:45:30.519Z  APP_LIFECYCLE paused
    16:45:30.5xxZ  UIAPP_WILL_TERMINATE          <- PRESENT
    16:45:30.531Z  APP_LIFECYCLE detached

Dead ~585 ms after `PROCESS_BEGIN`, before the +1000 ms heartbeat. Dart restarted
**inside the same OS process** again (pid 51041, `seq` reset).

| | |
|---|---|
| new native crash report | **none** |
| new Jetsam report | **none** for this app |
| `WILL_TERMINATE` | **present** |
| lifecycle damage | **none** — `next_boot=5 last_booted=5 currently_booting=null attempts=0` |
| frozen surfaces | INTACT, engine bytes VERIFIED |

## Bucket **G**, same signature as run_006

`MEMORY_PRESSURE` → `hidden` → `paused` → `WILL_TERMINATE` → `detached` is an
orderly, system-initiated termination. Assigned on a positively observed callback,
not inferred from an absence.

## Syslog: covered the window, and shows a switcher destroy for the PRECEDING lifetime

At the corresponding local time (12:45:29 — the device logs local, the timeline
logs UTC):

    SpringBoard: DismissSwitcherNoninteractive
    SpringBoard: SBWorkspaceDestroyApplicationEntity  ... firstActivationProbe ...
    SpringBoard: Invalidating scene: sceneID:dev.selfhost.firstActivationProbe-default
    SpringBoard: [application<...>:51041] Unregistering scene

That is an **app-switcher force-quit**, and it lines up with the *previous*
lifetime's `detached` at 16:45:29.059Z — not with the death under investigation
0.6 s later. So the sequence was: switcher force-quit, relaunch ~0.9 s later,
then an orderly termination ~0.6 s after that.

## What I could NOT establish, stated rather than guessed

**No jetsam or watchdog line attributable to this app** appears in the termination
window. The capture contains many such lines across twelve hours and nine million
lines, but none I can tie to `firstActivationProbe` at 12:45:30. So the *agent* of
the termination is still not positively named — `WILL_TERMINATE` says it was
orderly, not who asked.

**The ordering of Route B activation against first frame does not reconcile** in
this run: the timeline puts `FIRST_FRAME` at 16:45:29.962Z while syslog puts
`ROUTEB: hook entered` at 12:45:30.001 local, which is ~39 ms *later* — yet Route B
runs before `main`. Either a clock offset between the two sources or a launch I
have mis-segmented. **Not resolved, and not asserted either way.** I made one
timezone error earlier in this same analysis (searching UTC against a local-time
log), which is exactly why this is being left open rather than reconciled by
assumption.

## Bearing on the experiment

This is the **second** G-classified termination in a row on this device, both with
`MEMORY_PRESSURE` immediately preceding, and both on established patches rather
than first activations. Neither matches the historical first-activation pattern.

Whether the validation control PASSES is a PM call. The gate asked for a clean
established-patch run; this one disappeared. Nothing indicates a harness fault —
frozen surfaces intact, engine bytes verified, syslog USABLE and covering the
window, timeline complete to the moment of death — so the harness arguably did
exactly what it was built to do, on the first run where it mattered.

## The run is NOT banked

The size guard tripped: `syslog.log` is 14 MB after filtering 9.1 M raw lines, and
it is not gitignored. Per the guard's design nothing was deleted. A trimmed window
around the event needs extracting before this run can be committed.
