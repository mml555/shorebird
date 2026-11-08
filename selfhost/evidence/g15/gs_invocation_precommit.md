# gen_snapshot INVOCATION CAPTURE — PRECOMMIT

Written before the instrumented release. Measures ONE thing: what the real iOS
release build actually invoked for the app's AOT step.

## CORRECTION CARRIED IN

The prior note said "the flag did not reach the app AOT step". **That was not
proven.** What is proven is narrower:

> the same snapshotter emits ~935 sites on a controlled input, while release 103's
> real app build produced 8. The differentiator is somewhere in the real
> invocation / input / configuration path.

This measurement is what tells us whether a missing `--patchable_static_calls` is
that differentiator.

## WHAT IS CAPTURED, per invocation

executable path · digest of the REAL binary behind the wrapper · full argv,
NUL-delimited and hex-encoded so nothing is lost to quoting · working directory ·
timestamp and PID · input kernel/dill path **and digest** · output path.

Then the real binary is exec'd with arguments **unchanged**.

**ALL invocations are recorded**, not just an assumed single one. The app AOT step
is identified afterwards from its actual input/output paths.

**The input dill digest is load-bearing**: if the flag is present but the real
build feeds a materially different kernel than the direct A/B did, argv alone
would not isolate the cause.

## FROZEN INTERPRETATION

| observation | meaning |
|---|---|
| app-AOT argv **lacks** `--patchable_static_calls` | **invocation plumbing defect isolated** |
| flag **present**, expected snapshotter ran, still 8 sites | **missing-flag hypothesis REFUTED**; another argument or input property suppresses emission |
| a **different** snapshotter ran | **binary-selection defect isolated** |

**If the flag is present, do NOT resume reading compiler code.** The next step is
the replay below.

## REPLAY PLAN, if the flag is present

Using the exact captured argv against the exact captured dill, offline:

1. replay unchanged → **must reproduce ~8**;
2. remove only `--patchable_static_calls` → establishes the scanner baseline;
3. diff the captured real argv against the known ~935 direct invocation;
4. vary one differing argument at a time.

If unchanged replay does NOT reproduce the artifact, there is an unrecorded
input/environment dependency, and **that** is the finding.

## WHAT NOT TO PRIVILEGE

Output format is exonerated — the new snapshotter emits through BOTH elf and
assembly paths (935/936 either way). Compare whole-program inputs and optimization
flags first. The 8 surviving sites may be perfectly real incidental calls while the
application's relevant calls were eliminated by a build-mode or config difference.

## SCOPE

No release 104 as a specimen (the instrumented build's output is evidence only).
No lifecycle work. No compiler hypothesis until this lands. Rig to be restored to
cell `50bdae36` afterwards and verified by real work.
