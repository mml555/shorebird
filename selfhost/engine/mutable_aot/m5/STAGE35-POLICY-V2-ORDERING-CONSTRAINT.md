# STAGE35 — policy v2 blocked by an ordering constraint

Fork `2569595b493` (clean), stamped.

**Stopping and reporting the ordering constraint, as the ruling directs,
rather than adding another retention side channel.**

## 1. What policy v2 needed, and why it looked like a no-op change

Materialization **already** consumes retention: `MaterializeMutableAotRegistry`
keeps an entry only when `functions_to_retain_.ContainsKey(fn)` and the
function has code. The only place selection *causes* retention is the seeding
loop, which runs before `Iterate()`:

```cpp
if (!FLAG_maot_disable_retention_roots) {
  AddFunction(fn, RetainReasons::kMutableAotDeclaration);
  AddTypesOf(fn);  // retains the owning class and its type graph
}
```

So policy v2 appeared to need no new selection logic at all: suppress those
two calls and selection consumes retention instead of causing it.

## 2. It does not work, and the failure is not subtle

One identical kernel, one flag:

| kernel | retention roots | snapshot | selected | retained | workload |
|---|---|---|---|---|---|
| plain (nothing selected) | ON | 13.42 MB | 0 | 22,970 | ok |
| plain (nothing selected) | OFF | 13.42 MB | 0 | 22,970 | ok |
| policy-selected | ON | 22.16 MB | 1,858 | 23,146 | ok |
| policy-selected | **OFF** | **7.83 MB** | **0** | **2,220** | **SEGV** |

The two kernels differ by **2,856 bytes** — the selection metadata alone.

The flag is a clean no-op when nothing is selected. With selection present,
removing the seeds collapses retention roughly **10x below the ordinary
baseline** (2,220 vs 22,970) and produces an artifact that crashes.

## 3. The constraint, stated as measured

With selection metadata present, the MAOT seed roots are **not additive extra
roots**. Ordinary entry-point reachability in that configuration reaches only
2,220 functions; the seeds are load-bearing for discovering the rest of the
program.

So the required invariant —

```
Mutable-AOT selection must consume normal retention.
Mutable-AOT selection must not cause normal retention.
```

— **cannot be satisfied by suppressing the seeding**, because in the presence
of selection the seeding is part of how normal retention is reached at all.

**What is NOT established:** *why* adding selection metadata changes ordinary
reachability so drastically. That is the next question and it needs
authorization; it is a front-end/TFA interaction, not a retention-policy knob.

## 4. My neutrality check passed vacuously — do not trust it

The Stage 35 gate asked for `EXTRA_RETAINED_DUE_TO_MAOT = 0`, proven by set
comparison. It reported:

```
arm B: retained_not_in_baseline = 0  PASS
arm C: retained_not_in_baseline = 0  PASS
```

**That PASS is worthless here.** B and C retained 2,220 functions, which is a
strict subset of the baseline's 22,970 — a catastrophically under-retained
build trivially adds nothing to the baseline set.

The check as written can only detect over-retention. It needs a lower bound
too: a neutral policy should retain approximately what the baseline retains,
not merely "no more than". Reported rather than quietly recorded as a pass.

The same applies to the size numbers from that run: `B−A = −41.7%` is not a
saving, it is a broken build.

## 5. Status

```
Policy v2 via retention-root suppression   NOT VIABLE (crashing artifact)
Ordering constraint                        REPORTED, root cause not established
Neutrality check                           INSUFFICIENT (upper bound only)
Policy v1                                  remains REJECTED (+66.8%)
Default-on readiness                       NOT ESTABLISHED
```

No replacement-semantics regression was run: there is no viable policy v2
build to run it against.
