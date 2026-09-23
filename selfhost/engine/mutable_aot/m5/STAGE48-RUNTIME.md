# STAGE48 — runtime gate: one VALID separable result, four VALID null results,
# one workload that cannot terminate, two not run

Artifact under measurement, pinned before the run:

```
shorebird       d5888ac82
fork            5878283d55e      fork_sources_match_head 1
gen_snapshot    1838aa405f256444d8bc9bd72d4a850478f623551fca144cdcc8b2f56b7758f9
dartaotruntime  dc0254ea1908408ad8c520902805aff9517b9ec5bc677900ba2e7dfe6ff41880
```

Preflight, recorded with the evidence as required:

```
launching gate at load=1.30 22:56:50
   preflight 1 at 22:56:50: load 1.30 / 2.54 / 7.03  competitors: none
   preflight 2 at 22:57:51: load 2.14 / 2.53 / 6.72  competitors: none
   two consecutive clean observations 60s apart; proceeding
repetitions per workload: 11
```

No workload reported `WORKLOAD INVALIDATED`: environmental conditions held for
every repetition that ran. No repetition was discarded.

## 1. Hot mutable instance-call loop — VALID and SEPARABLE

The measurement first: `cls:Hot::method:step` has `indirect_call_sites_emitted
= 1`, `installable = True`, `optimizer_escapes = 0`, so in arm C the timed call
goes through the dispatch cell and the declaration is genuinely replaceable.
`Cold.step` is not selected. Without that check the numbers below would mean
nothing.

```
rep       A hot     A cold      C hot     C cold    A ratio    C ratio
0        3.9246     2.0392     3.8616     2.0392     1.9246     1.8937
1        3.9447     2.0448     3.8569     2.0401     1.9291     1.8905
2        3.9248     2.0396     3.8723     2.0415     1.9243     1.8968
3        3.9451     2.0444     3.8594     2.0408     1.9297     1.8911
4        3.9343     2.0362     3.8622     2.0380     1.9322     1.8951
5        3.9261     2.0385     3.8802     2.0391     1.9259     1.9029
6        3.9277     2.0399     3.9173     2.0416     1.9254     1.9187
7        3.9211     2.0358     3.8784     2.0372     1.9260     1.9038
8        3.9139     2.0381     3.9022     2.0447     1.9204     1.9085
9        3.9240     2.0457     3.8845     2.0456     1.9182     1.8990
10       3.9139     2.0442     3.8711     2.0394     1.9147     1.8982

median hot/cold ratio   A 1.9254   C 1.8982
ratio min-max           A 1.9147-1.9322   C 1.8905-1.9187
C ratio / A ratio = 0.9859        ->  -1.41%
noise floor, arm A ratio spread over the same run = 0.91%
absolute: C hot - C cold = +1.8411 ns/call
```

**The cell indirection is 1.41% CHEAPER than the baseline call on this shape**,
against a 0.91% noise envelope. It separates, and it separates in the direction
of no cost.

That is mechanically plausible rather than surprising. The baseline call here
is a monomorphic instance call, which checks the receiver's class id before
branching; the cell path loads the cell from the object pool, loads the
implementation function and its entry point, and branches, with no class check.
The two are comparable and the cell path can be marginally shorter.

The `+1.8411 ns/call` figure is the gap between the mutable call and the plain
one in the **same** arm C process, and it is a property of the fixture -- `Hot`
and `Cold` differ by the never-inline pragma and by being selected -- not a
Mutable-AOT cost. The A-vs-C ratio comparison is what divides that out.

## 2. Startup — four VALID runs, all null results

```
workload                  median A   median C   C vs A     A' vs A (noise)   verdict
startup: smith             15.03 ms   15.91 ms   +8.61%    +10.79% envelope 30.29%   inside noise
startup: nst               14.93 ms   16.06 ms   +7.58%    +10.94% envelope 35.08%   inside noise
startup: gen_kernel        18.81 ms   19.91 ms   +7.14%     +5.90% envelope 15.72%   inside noise
startup: dart2wasm         21.90 ms   23.93 ms   +9.60%     +4.53% envelope 29.71%   inside noise
```

Every one is a valid run whose effect is not separable from the A-vs-A control.

**The control also exposes an ordering bias in the methodology.** Repetitions
run A, then C, then A'. The A'-vs-A median is **positive in all four
workloads** (+10.79%, +10.94%, +5.90%, +4.53%): the *third* run in each
repetition is systematically slower than the first. C occupies the second
position, so a part of every C-vs-A median above is position, not arm. The
A-vs-A control was included precisely so this could not be quoted as a result,
and it did its job.

The hot loop is immune to this because its statistic is a ratio taken **inside
one process**, between two loops run back to back; position bias moves both
loops together.

**Data quality note:** every repetition of `startup: smith` and
`startup: dart2wasm` exited non-zero -- those binaries reject `--help`. Those
two rows time "launch, load the snapshot, fail to parse arguments, exit", which
is still snapshot load and entry, but is not what "startup" normally means.
`nst` and `gen_kernel` exited zero.

## 3. `startup: analysis_server` — the workload cannot terminate

```
subprocess.TimeoutExpired: Command '[dartaotruntime, analysis_server.A.aot,
'--help']' timed out after 7200 seconds
```

`analysis_server` is a server: it starts and waits on stdin for LSP traffic,
so `--help` never returns. The process sat at **0% CPU** in
`_pthread_cond_wait` inside `RunMainIsolate` for two hours.

This is a workload-definition defect, not an environmental failure and not a
performance result. It is also what killed the run: the exception propagated
and the script exited.

## 4. `work: gen_kernel` and `work: dart2wasm` — NOT RUN

They are sequenced after the startup block and never executed.

## Status by workload

```
hot mutable instance-call loop   VALID, effect -1.41%, noise 0.91%   SEPARABLE
startup: smith                   VALID, null result (also rc != 0)
startup: nst                     VALID, null result
startup: gen_kernel              VALID, null result
startup: dart2wasm               VALID, null result (also rc != 0)
startup: analysis_server         DEFECTIVE WORKLOAD -- cannot terminate
work: gen_kernel                 NOT RUN
work: dart2wasm                  NOT RUN
```

## Three changes this argues for, none applied

The methodology is frozen; these are proposals.

1. **`analysis_server` startup needs a terminating invocation** -- `stdin` from
   `/dev/null`, or drop the application from the startup workload. As defined
   it cannot produce a measurement.
2. **`--help` is the wrong argument for `smith` and `dart2wasm`** -- they
   reject it. A no-argument invocation, or the application's own trivial
   command, would time the same snapshot load without a non-zero exit.
3. **The A/C/A' ordering biases against C.** The A-vs-A median is positive in
   all four startup workloads. Alternating the order per repetition, or
   randomizing it, would remove a bias the control can currently only detect.

None of these affects the hot-loop result, which is the one workload that
separated.

## Reproduce

```
selfhost/engine/mutable_aot/m5/lib/runtime_m5.py      the gate, unchanged
selfhost/engine/mutable_aot/m5/lib/noisefloor_m5.py   instrument characterization
```
