# STAGE37 — the size driver is data, not code

Fork `2569595b493` (clean), stamped.
Call indirection OFF and retention roots OFF in **every** arm, so reachability
stays at baseline and size is not confounded by the 22k->2k collapse.

## 1. Matrix

| arm | selection | P1 | inlining restriction | total MB | .text MB | .rodata MB | selected | retained |
|---|---|---|---|---|---|---|---|---|
| A | OFF | normal | normal | 13.42 | 5.79 | 3.81 | 0 | 22,970 |
| B | ON | **OFF** | **OFF** | 22.53 | 5.79 | **12.91** | 1,598 | 22,970 |
| C | ON | ON | OFF | 22.54 | 5.79 | 12.91 | 1,598 | 22,971 |
| D | ON | ON | ON | 22.33 | 5.78 | 12.72 | 1,853 | 23,144 |

```
A -> B   total +9.11 MB    .text +0.00 MB    .rodata +9.10 MB  (+238.8%)
B -> C   total +0.01 MB    P1 enabled
C -> D   total -0.21 MB    inlining restriction enabled
```

## 2. What this rules out

**P1 constant suppression is not the size driver.** Enabling it costs
0.01 MB — 0.1% of the regression. The ruling flagged it as plausible because
its effect can propagate well beyond the selected set; it does not.

**Inlining restriction is not the driver either.** Enabling it makes the
snapshot *smaller* by 0.21 MB.

**Lost optimisation is not the driver.** `.text` is 5.79 MB in A, B and C and
5.78 MB in D — unchanged to the resolution measured. If restrictions were
costing us optimised code, the code section would grow. It does not move.

**Retention is not the driver**, confirming STAGE36: A and B retain the
identical 22,970 functions.

## 3. What it is

The whole regression is **`.rodata`**: 3.81 MB -> 12.91 MB, a **3.4x** increase
in the data section, introduced by selection metadata alone with every other
MAOT semantic disabled.

Per selected declaration that is `9.10 MB / 1,598 ≈ 5,700 bytes` of data.

That figure is large enough to be interesting on its own: a declaration id
string, a dispatch cell and a descriptor entry should not cost kilobytes. Note
also that D selects **more** declarations (1,853) and is **smaller** (22.33 MB)
than B (1,598 / 22.53 MB), so the cost is **not linear in the selected count**.

**The specific structure responsible is not identified.** Section attribution
is as far as this matrix goes; naming the objects inside `.rodata` needs
object-level attribution, not another policy guess.

## 4. Why this is favourable

The cost is data the registry materialises, not code the optimiser lost.
Data structures are far more tractable than reinstating optimisations: they can
be interned, shared, made compact, or moved out of the snapshot entirely.
Nothing here suggests the mutable dispatch architecture is inherently
expensive — `.text` is unchanged and trampolines remain ~1%.

## 5. Status

```
Size regression                     CONFIRMED +9.11 MB / +67.9%
Located to                          .rodata (data), .text unchanged
P1 as driver                        REFUTED (0.1%)
Inlining restriction as driver      REFUTED (negative)
Lost optimisation as driver         REFUTED (.text flat)
Retention as driver                 REFUTED (identical sets)
Responsible structure               NOT YET IDENTIFIED
Cost per selected declaration       ~5,700 bytes, non-linear in count
```
