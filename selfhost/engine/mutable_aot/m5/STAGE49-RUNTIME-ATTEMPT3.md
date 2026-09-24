# STAGE49 — runtime gate, attempt 3: one VALID/UNRESOLVED, four INVALIDATED

First run under the revised methodology (`86dd71e3c`): load ceiling retired,
arm order balanced, startup batched at 100 launches per sample, real work at 20
paired samples, A-vs-A floor as the measurement-quality gate.

```
startup: smith        VALID / UNRESOLVED
startup: nst          INVALIDATED
startup: gen_kernel   INVALIDATED
work: gen_kernel      INVALIDATED
work: dart2wasm       INVALIDATED
```

Preflight was clean at 13:13:49, load 2.96 recorded as context.

## The one valid measurement, and why it decides nothing

```
startup: smith   100 consecutive launches per sample, 12 balanced samples
    EFFECT  C vs A   median +4.11%   (min -0.31%, max +22.23%)
    FLOOR   A vs A   median -2.15%   envelope 20.87%
    VERDICT: inside the noise, not quotable
```

Arms verified identical before timing: `rc 0/0`, 192,596 / 192,596 bytes of
stdout, byte-identical. No sample discarded.

The supported conclusion is **no startup effect could be resolved on this host
in this run** -- not "no startup regression". A 20.87% floor cannot support an
equivalence claim.

The load column shows why the floor stayed wide despite batching:

```
sample 0    load  2.5
sample 10   load 31.8
sample 11   load 47.0
```

Batching 100 launches per sample suppresses per-launch jitter, which is what it
was authorized for. It does nothing about the machine itself ramping twenty-fold
across the samples. **Batching addresses the wrong variance when the host is
changing underneath the run**, and the A-vs-A floor is what made that visible.

## The four invalidated workloads

A competing build appeared three minutes into the run and escalated:

```
13:21:09  flutter_tools x1                                  startup: nst
13:23:24  flutter_tools x1, xcodebuild x1                   startup: gen_kernel
13:26:57  flutter_tools x5, xcodebuild x1                   work: gen_kernel
13:27:37  flutter_tools x2, xcodebuild x1                   work: dart2wasm
13:28:20  final observation, load 203.13
```

Every arm-output check passed in all four (`181/181`, `4711/4711`, `0/0`,
`0/0` bytes, all `rc 0/0`) and no sample was discarded. **Passing output checks
do not override environmental invalidation**, so no arm comparison is derived
from any of them. Each must be rerun from the beginning.

The final load of 203.13 is context. The named build processes are the
fail-closed trigger.

## Harness changes this forced

`f53a13d8a`:

* **early abort** -- a workload stops at the first observation showing a
  competing build. The verdict is identical either way, so completing the
  remaining samples spent ten minutes to reach it. Samples already taken stay
  printed; nothing is quoted from them.
* **paired-delta sign distribution** -- positive/negative pair counts alongside
  the median, so a consistent small cost is distinguishable from unstable
  noise on the eventual valid real-work rows.

A scheduling threshold was added to the **launcher**, not the gate: it waits
for load <= 15 with no build processes before attempting. That is a choice of
when to try, not a validity criterion -- validity remains the competitor
detector, the exit and output checks, and the A-vs-A floor. It exists because
two attempts fired at load 227.97 and 194.42, where the gate would have spent
ten minutes producing a correctly-unresolved verdict.

## Outstanding

```
Hot mutable call      ACCEPTED -- no regression detected, C/A -1.41%
startup: smith        VALID / UNRESOLVED
startup: nst          OUTSTANDING
startup: gen_kernel   OUTSTANDING
work: gen_kernel      OUTSTANDING
work: dart2wasm       OUTSTANDING
Runtime gate          OPEN
```

Raw log: `evidence/RUNTIME-GATE-ATTEMPT3-RAW.log`.
