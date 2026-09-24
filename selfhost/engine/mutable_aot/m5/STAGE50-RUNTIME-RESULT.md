# STAGE50 — runtime gate: four valid completions, one separation

Harness `f53a13d8a`. Artifact `shorebird d5888ac82` / `fork 5878283d55e`.
Preflight 14:24:53 load 12.89, 14:25:54 load 9.36, no competing builds.
Every workload completed. No sample discarded. No workload invalidated.

```
workload              effect C/A    direction    floor median   envelope   verdict
startup: nst            +1.77%       7+ / 5-       -0.59%        3.61%     UNRESOLVED
startup: gen_kernel     +7.17%      11+ / 1-       -0.61%        6.17%     SEPARATES
work: gen_kernel        -0.08%      10+ / 10-      +1.47%       17.09%     UNRESOLVED
work: dart2wasm         +0.84%      13+ / 7-       -0.83%       14.19%     UNRESOLVED
```

Arms verified identical before every workload: `rc 0/0` and byte-identical
stdout (181, 4711, 0, 0 bytes respectively).

## 1. The +2.10% on real compile work did not reproduce

This was the question the rerun existed to answer.

```
work: gen_kernel, 20 balanced pairs
    EFFECT  median -0.08%   min -3.19%   max +3.30%
    direction 10 of 20 pairs positive, 10 negative
    FLOOR   median +1.47%   envelope 17.09%
```

A perfect 10/10 directional split and a median of −0.08%. The forty timed
runs span 331–348 ms. The earlier exploratory +2.10% was the edge of a
six-sample floor, not a persistent cost.

`work: dart2wasm` agrees: +0.84% median, 13/7 direction, well inside a 14.19%
floor envelope.

**No real-work runtime cost is detectable in either compiler workload.**

## 2. Startup on gen_kernel separates — with a caveat that must travel with it

```
startup: gen_kernel, 100 launches per sample, 12 balanced samples
    EFFECT  median +7.17%   min -1.07%   max +51.79%
    direction 11 of 12 pairs positive, 1 negative
    FLOOR   median -0.61%   envelope 6.17%   direction 5+ / 7-
    VERDICT: separates -- |7.17%| exceeds the 6.17% envelope
```

The directional evidence is the strong part: 11 of 12 pairs positive, against a
floor that is balanced at 5/7 and centred on −0.61%. Arm order is balanced, so
this is not the positional artifact that ruined the first attempt.

**The caveat.** The effect block and the floor block run sequentially, not
interleaved with each other, and the load differed between them:

```
effect samples   load 140.7 - 167.9
floor samples    load 115.5 - 137.6
```

The floor was measured on a quieter machine than the effect. It may therefore
understate the noise applicable to the effect block, and the margin is only
1.0 percentage point. I would not promote +7.17% to a startup cost figure on
this evidence; the defensible statement is **a consistent positive startup
effect on gen_kernel, direction 11/12, magnitude not established**.

`startup: nst` does not separate: +1.77% against a 3.61% envelope, direction
7/5.

## 3. What the run says about the methodology

The whole run executed at load 86–168, far above the retired 2.5 ceiling, and
produced the tightest floors this lane has measured: **3.61% and 6.17%** on the
batched startup workloads, against 9.40–20.87% for the same workloads
unbatched. Batching 100 launches per sample is what bought that, not a quiet
machine.

The two work workloads have wider floors (17.09%, 14.19%) than their effects'
own spreads, each driven by a single outlier sample. Their effect samples are
tighter than their floor samples, which makes the nulls robust rather than
marginal.

## 4. One methodological weakness to fix before any future run

Effect and floor are measured as consecutive blocks. On a machine whose load
drifts during a run, that lets the two be taken under different conditions --
exactly what happened to `startup: gen_kernel`. Interleaving them
sample-by-sample, in the same balanced rotation, would remove it.

**Not applied, and the affected workload is not rerun**: it completed validly,
and rerunning a valid workload because its result is inconvenient is condition
selection.

## Status

```
Hot mutable instance call   ACCEPTED -- no regression detected, C/A -1.41%
startup: smith              VALID / UNRESOLVED   envelope 20.87%
startup: nst                VALID / UNRESOLVED   +1.77% vs 3.61%
startup: gen_kernel         VALID / SEPARATES    +7.17% vs 6.17%, 11/12 positive
work: gen_kernel            VALID / UNRESOLVED   -0.08%, 10/10 split
work: dart2wasm             VALID / UNRESOLVED   +0.84% vs 14.19%
```

Raw log: `evidence/RUNTIME-GATE-FINAL-RAW.log`.
