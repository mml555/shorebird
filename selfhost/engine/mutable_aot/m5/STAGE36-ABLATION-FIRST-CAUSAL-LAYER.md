# STAGE36 — the first causal layer: #67 call indirection severs reachability

Fork `2569595b493` (clean), stamped.
Same `gen_kernel` subject, one selected kernel, retention roots OFF in every
experimental arm so the only variable is which MAOT effect is suppressed.

## 1. Ablation

| arm | snap MB | selected | retained | workload | lost vs baseline |
|---|---|---|---|---|---|
| baseline (plain kernel) | 13.42 | 0 | 22,799 | ok | — |
| selected, roots ON (control) | 22.16 | 1858 | 22,975 | ok | 8 |
| selected, roots OFF | 7.83 | 0 | 2,202 | **FAIL** | **20,597** |
| **+ call-indirection OFF** | **22.33** | **1853** | **22,973** | **ok** | **2** |
| + allow inlining mutable | 7.81 | 0 | 2,202 | FAIL | 20,597 |
| + escape detection OFF | 7.83 | 0 | 2,202 | FAIL | 20,597 |
| + constant backstop OFF | 7.83 | 0 | 2,202 | FAIL | 20,597 |

**Exactly one switch restores reachability.** Disabling #67's call indirection
takes retention from 2,202 back to 22,973 and the artifact runs again — with
retention roots still OFF and 1,853 declarations still selected. Inlining
policy, escape detection and the constant backstop make no difference at all.

## 2. The mechanism, from the lowering's own contract

`flow_graph_compiler_arm64.cc` states it directly for the cell-indirect path:

> *"nothing records a static-call target, because there is no fixed target to
> record -- the callee is resolved on every call."*

That is the reachability edge the precompiler walks to discover callees.
Applied to 1,853 selected declarations it severs the graph at the root
package.

## 3. What is lost, classified

```
LOST = 20,597
  package:vm                1,951  of 1,951  (100%)  <- the SELECTED root package
  package:front_end         7,990  of 7,990  (100%)
  package:kernel            4,152  of 4,161  (99.8%)
  package:_fe_analyzer_shared 2,394 of 2,394 (100%)
  dart: (SDK)               3,116  of 5,262  (59%)

SURVIVORS = 2,202
  dart: 2,146 | package:args 40 | package:kernel 9 | entry library 7
```

This is not 20,000 independent retention faults. The entry library survives,
its own package is erased, and every package reachable only *through* it goes
with it. One analysis decision cuts one layer and the subtree below vanishes —
the shape the ruling predicted.

This is the ruling's **branch B**: preserving mutable dispatch prevents the
analysis from discovering concrete callees that ordinary AOT relies on for
reachability.

## 4. A correction to STAGE34's attribution

STAGE34 concluded the +66.8% size cost belongs to *"selection/retention"*.
**That attribution was wrong**, and this ablation shows why.

With call-indirection OFF and roots OFF, retention is essentially neutral —
22,973 against a 22,799 baseline, **+174 functions** — while the snapshot is
still **22.33 MB against 13.42 MB, +66%**.

The same holds for the roots-ON control: +176 retained functions, +65% size.

So the cost is **not** the retention of extra code. A few hundred extra
functions cannot account for 8.9 MB. Something else in the selected
configuration inflates the image by two thirds, and the candidates — P1
constant suppression, inlining refusal, the cell pool entries, the
call-indirect code shape — have **not** been separated. P1 in particular is a
front-end switch and was not in this matrix.

The earlier "the cost is selection, not trampolines" half stands: trampolines
are ~1%. The "it is retention" half does not.

## 5. Status

```
First causal layer for reachability collapse   ESTABLISHED (#67 call indirection)
Lost-set structure                             ESTABLISHED (root package severed)
Architectural branch                           B (dispatch preservation vs analysis)
Size driver                                    UNKNOWN -- NOT retention
STAGE34 size attribution                       CORRECTED
Policy v2                                      still blocked
```

Not attempted: any fix. The ruling authorizes diagnosis only, and a fix here
would mean changing how mutable call sites record reachability — architecture,
not a knob.
