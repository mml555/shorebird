# STAGE32 — diagnostics hygiene, body partition, and both scale gates

Fork `2822c0c3cb5` (clean), stamped.

```
REALAPP_MAOT_SELECTION_PRECOMPILER = WITHDRAWN
reason: observed failure was caused by unconditional diagnostic work
        introduced during STAGE20, not by Mutable-AOT selection or
        serialization semantics
```

STAGE28-30 are retained as diagnostic history with their crash conclusions
marked contaminated. UBSan was dropped: no defect hypothesis remained for it.

## 1. MAOT_DIAGNOSTICS_DISABLED_NO_WORK

The classification path now counts its own entries, reported once per
relocation pass, so "it did not run" is a number rather than an absence of
output.

```
trace OFF  rc=0   classifications=[0, 0]      -> PASS
trace ON   rc=-6  classifications=[0, 59670]  -> PASS (path runs)
```

**A limitation recorded rather than hidden:** with tracing ON the run still
crashes at this population. The provenance diagnostic is not scale-safe — it
is an O(registry) walk per call target. It is usable on m5-sized fixtures and
must not be enabled against a real application.

## 2. The 625 gap: partitioned, no remainder

```
BODY_PARTITION entries=5098 unique_body=4473 shared_body=625
               no_body=0 body_is_trampoline=0 sum=5098 remainder=0
```

`4473 + 625 = 5098`. The 625 are declarations **sharing a body Code** with
another declaration; the traversal list dedups by Code pointer, so they
collapse into a single pin. Not a defect, and now accounted for mechanically
rather than assumed benign.

## 3. Gate A — clean baselines (3 reps, median [range])

All pre-fix timings are retired as contaminated.

| arm | kernel s | snap s | kern MB | snap MB | selected | eligible | refused | installed | bodies |
|---|---|---|---|---|---|---|---|---|---|
| A normal / install OFF | 17.5 [17.4-23.0] | 25.3 [24.3-28.6] | 17.0 | **7.6** | 0 | 0 | 0 | — | — |
| B select-all / install OFF | 23.3 [20.0-52.9] | 37.7 [35.1-39.1] | 16.9 | **31.7** | 5098 | 4771 | 327 | — | — |
| C select-all / install ON | 18.5 [18.0-21.3] | 35.5 [34.8-35.6] | 16.9 | **32.3** | 5098 | 4771 | 327 | 5098 | 4473 |

`eligible + refused == selected` PASS in B and C. `installed == distinct` PASS.

**The material finding is size, and it belongs to selection, not to
trampolines:** 7.6 MB -> 31.7 MB comes from select-all with installation OFF;
turning installation ON adds 0.6 MB. Snapshot time moves 25.3s -> ~36s on the
same split. Growth is large but not nonlinear, and no identity collapse
appears.

B's kernel-time range (20.0-52.9s) contains one outlier. Not interpreted —
three repetitions is enough to avoid presenting a single noisy number, not
enough to characterise a tail.

## 4. Gate B — runnable real application

`shorebird_cli` cannot satisfy the runtime gate here: it resolves an install
tree it does not find, independent of MAOT. Substituted
`pkg/vm/bin/gen_kernel.dart` — the Dart front-end driver, a larger real
application that runs standalone and does verifiable work. The substitution is
an app-configuration constraint, not a MAOT result.

```
MAOT_SELECT_ALL_NON_SDK=1, installation ON

kernel            23s   35.3 MB
snapshot  rc=0   394s  112.9 MB
selected=18462  eligible=17706  refused=756
installed=18462  distinct=18462
BODY_PARTITION   unique=14838 shared=3624 sum=18462 remainder=0
PINNED_TRAVERSAL bodies=14838 visited_once=14838 never_visited=0
                 multiply_visited=0 unbound_entries=0
                 non_leaf_bodies=13846  verdict=PASS

runtime   rc=0   compiled hello.dart -> hello.dill (4,388,040 bytes)
```

**18,462 mutable declarations, all installed, all distinct** — and the artifact
launches and performs its real workload correctly.

Minimum runtime proof satisfied: snapshot succeeds, artifact launches, reaches
normal startup, no relocation failure, no traversal failure, no routing/cell
failure.

**Not included:** the in-process `OLD -> V2 -> NEW -> V3 -> NEW2` probe.
`gen_kernel` carries no FFI harness for `Dart_MaotInstallForTesting`, and the
ruling treats that probe as preferable rather than required. So this gate
proves mass selection serializes and runs; it does **not** re-prove replacement
semantics at scale.

## 5. State

```
Synthetic population 512        ESTABLISHED
Real-app snapshot population    ESTABLISHED (5098, and 18462 on gen_kernel)
Real-app runtime gate           ESTABLISHED (launch + real work)
Clean performance baselines     ESTABLISHED
Installed/pinned partition      ESTABLISHED (remainder 0)
Replacement-at-scale probe      NOT ESTABLISHED
Default-on readiness            NOT ESTABLISHED
```
