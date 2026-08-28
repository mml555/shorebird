# First-activation disappearance — NOT REPRODUCED

Reproduction phase closed. Ten controlled new-patch first activations completed
without a disappearance, alongside matched established-patch controls.

## The closure statement

> The historical first-activation disappearance was **not reproduced** under the
> controlled investigation setup. Ten controlled new-patch first activations
> completed without disappearance, alongside matched established-patch controls.
> The historical events **remain unexplained** and cannot be classified causally
> from the available evidence. **No certified-runtime defect was demonstrated.**

### What this does NOT say, deliberately

* not "the bug is fixed"
* not "it never existed"
* not "the new cell solved it"
* not "Route B was the cause"
* not "iOS killed it"

None of those is established by this evidence.

## The controlled sample

| population | disappearances | observations |
|---|---|---|
| **A** — first activation of a new patch | **0** | **10** |
| **B** — established patch, matched control | **0** | 10 |
| **ACQ** — acquisition launch, armed | **0** | 3 |

Every observation: frozen surfaces PASS, engine byte identity VERIFIED against the
published cell, syslog `USABLE`, render captured, 7/7 post-frame heartbeats through
+5000 ms, Route B `rc=0`, `success_diag` crediting the patch that actually ran, and
**zero** new crash reports on both the immediate and delayed pulls.

Generations 003–010 on patches 1–9 (`ACT-V2` … `ACT-V10`), each with a unique
marker so no generation can be confused for another, on the frozen base release
1.3.0+1 / server id 138, cell `4792f0ec`.

## Terminations observed, and why none is bucket G

Three terminations occurred outside the controlled runs. **Positively classified G
events: zero.**

| event | finding |
|---|---|
| `run_006` acquisition tap | orderly termination PROVEN; initiator **UNKNOWN**. Unarmed, so no syslog. NOT G |
| unobserved launch 01:39:51 | orderly `WILL_TERMINATE`; not an armed observation, counts in no population |
| `run_007` validation control | **operator force-quit** — `DismissSwitcherNoninteractive` + `SBWorkspaceDestroyApplicationEntity` in the capture. VOID |

`run_007` is the load-bearing one. It carried exactly the signature — `MEMORY_PRESSURE`
then `UIAPP_WILL_TERMINATE` — that had been read as system-initiated, and it turned
out to be a human closing the app. **`WILL_TERMINATE` proves a termination was
orderly; it never proves who asked.** G requires positive evidence of
system/lifecycle termination, and none was ever obtained.

## The three categories, never pooled

    controlled A/B/ACQ    the reproduction sample above
    incidental            run_006, the 01:39:51 launch, run_007 (void)
    historical            3-for-3, a different observational regime

The historical 3-for-3 is evidence that *something happened*. It is not pooled
into a rate with the controlled sample, and this exercise was classification, not
incidence measurement.

## What the harness cost, and what that is worth

Nine defects were found in the instrumentation and repository hygiene during this
phase — **none in the runtime**:

1. `UInt64` underflow → `SIGTRAP` in the native probe (an instrument that crashed
   its subject)
2. the Dart timeline wrote nothing, silently (`HOME` unset on iOS, plus a `catch`
   defended in a comment)
3. the wrong binary installed (`patch ios` reuses the archive path)
4. acquisition taps left unarmed
5. pid treated as a Dart-lifetime boundary
6. eleven orphaned `idevicesyslog` readers starving the syslog service
7. `tail -f` race making the liveness probe refuse valid arms
8. `pipefail` + SIGPIPE false negative
9. an 80 MB raw device syslog committed to a public repo

Every one of them would have biased results toward *finding* a problem, or toward
mislabelling a benign event as one. That is the argument for the review gates: the
first controlled disappearance we "found" was my own instrument trapping, and the
second was the operator closing the app.

## Standing state

    certified runtime     UNCHANGED throughout; frozen surfaces verified at every arm
    Epoch B               collecting, untouched
    base release          1.3.0+1 / id 138, never recut
    cell                  4792f0eca461f3761001a1adbe131b4b115e3684

## If it recurs

The harness is validated and idle. `armauto` derives the run label from device
state, so a recurrence can be captured without deciding in advance what kind of tap
it is. Retain the raw capture for any anomalous run until its classification closes
— that is what turned `run_007` from a finding into a void.
