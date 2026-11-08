# STAGE51 — prospective replication with interleaved effect and floor

Harness `ab07bc9d1`. Artifact unchanged: `shorebird d5888ac82`,
`fork 5878283d55e`. Preflight 00:30:33 load 12.79, 00:31:33 load 7.28, no
competing builds. Four workloads, all valid completions, no invalidation, no
sample discarded.

Dataset 1 (`92589f5e5`) is retained unchanged. This supplements it.

## The two datasets side by side

```
                      dataset 1 (block floor)        dataset 2 (interleaved floor)
workload           effect   dir    floor env      effect   dir    floor env
startup: nst       +1.77%   7+/5-    3.61%        -1.12%   6+/6-   18.10%
startup: gen_kernel +7.17%  11+/1-   6.17%        +3.03%   8+/4-   36.23%
work: gen_kernel   -0.08%  10+/10-  17.09%        -1.20%   8+/12-   2.76%
work: dart2wasm    +0.84%  13+/7-   14.19%        +0.56%  11+/9-   16.92%
```

Every workload verified identical arms before timing: `rc 0/0`, stdout
byte-identical (181, 4711, 0, 0 bytes).

## 1. Real work: the null is now measured at high resolution

```
work: gen_kernel, 20 interleaved rotations
    EFFECT  median -1.20%   direction 8 positive / 12 negative
    FLOOR   median +0.20%   envelope 2.76%   direction 14+/6-
```

The floor is the tightest this lane has recorded — **2.76%**, with forty A-vs-A
runs spanning 332-349 ms — and it was taken at load 115-160. The effect median
is **negative** and its direction favours negative 12 to 8.

Dataset 1 said -0.08% at a 17.09% floor; dataset 2 says -1.20% at a 2.76%
floor. **Both datasets agree, and the second one had the resolution to detect
a 2% effect and did not find one.** `work: dart2wasm` agrees at +0.56%.

## 2. `startup: gen_kernel` — the signal did not replicate

```
                      dataset 1        dataset 2
effect median          +7.17%           +3.03%
direction              11+ / 1-         8+ / 4-
floor envelope          6.17%           36.23%
effect block load    140.7 - 167.9    163.2 - 200.4
floor block load     115.5 - 137.6    163.2 - 200.4   (same rotation)
```

Interleaving did what it was authorized to do: effect and floor now share a
rotation and a load reading, so the 25-point load gap that made dataset 1's
separation untrustworthy is gone.

Three things moved together: the effect halved, the directional consistency
weakened from 11-of-12 to 8-of-12, and the contemporaneous floor widened six
fold.

**The honest reading, and the limit of it.** The prospective rule says a signal
that collapses inside the contemporaneous floor is attributed to environmental
variance, and literally +3.03% sits inside 36.23%. But a 36% floor cannot
refute a 7% effect -- this replication had roughly an order of magnitude less
resolving power than the effect it was testing, because it ran at load 163-200
against dataset 1's 140-168. "Inside the floor" here mostly means "could not
resolve", not "shown to be absent".

What does not depend on floor width is direction. Under a null of no effect,
11-of-12 positive is striking; 8-of-12 is unremarkable. That evidence weakened
materially, and it points the same way as the median.

**Recommended disposition: unresolved, and a documented default-policy risk**
-- the third branch of the rule, not the second. The first dataset's separation
was produced under a floor measured on a quieter machine, which is a known bias
toward finding an effect; the replication removed that bias and the signal
shrank. But the replication cannot itself establish absence.

No third run is proposed. The rule anticipated this outcome and named the
disposition rather than prompting further benchmarking.

## 3. `startup: nst`

Null in both datasets: +1.77% then -1.12%, direction 7/5 then an exact 6/6.
Nothing to resolve.

## Status

```
Hot mutable instance dispatch   NO REGRESSION DETECTED         C/A -1.41%
work: gen_kernel                NO DETECTABLE COST             -1.20% at a 2.76% floor
work: dart2wasm                 NO DETECTABLE COST             +0.56%
startup: nst                    NO REGRESSION DETECTED         -1.12%, 6/6
startup: gen_kernel             UNRESOLVED -- documented risk   did not replicate
startup: smith                  VALID / UNRESOLVED (dataset 1 only)
```

Raw log: `evidence/RUNTIME-REPLICATION-RAW.log`.
