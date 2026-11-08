# STAGE34 — production selection policy v1, A/B/C

Fork `ee9676f6736` (clean), stamped —
`maot_selection.dart` is now **in** the provenance stamp, which it was not
before: it defines selection, so editing it changed the measured population
without changing a byte of the binary.

Subject: `pkg/vm/bin/gen_kernel.dart`. Root application package = `vm`;
`front_end`, `kernel` and the rest are dependencies and are **not** selected
under v1.

Policy expressed as package ownership: `MAOT_SELECT_URI_PREFIX` now takes a
comma-separated list, so root-package-only is the default and a named
dependency can be opted in without widening to everything.

## 1. Arms

| arm | kernel s med[rng] | snap s med[rng] | snap MB | selected | eligible | refused | installed | runtime s med[rng] |
|---|---|---|---|---|---|---|---|---|
| A normal / OFF | 19.9 [19.3-22.0] | 149.1 [148.8-149.7] | **13.42** | 0 | 0 | 0 | — | 0.32 [0.31-0.39] |
| B policy / OFF | 19.6 [19.0-20.7] | 180.9 [167.1-219.7] | **22.16** | 1858 | 1780 | 78 | — | 0.43 [0.42-0.44] |
| C policy / ON | 34.3 [29.8-37.2] | 183.6 [155.4-216.7] | **22.38** | 1858 | 1780 | 78 | 1858 | 0.33 [0.33-0.40] |

`eligible + refused == selected` (1780 + 78 = 1858). All 78 refusals are
"the dispatch cell has no seeded global-pool entry".

```
BODY_PARTITION   entries=1858 unique_body=1690 shared_body=168
                 no_body=0 body_is_trampoline=0 sum=1858 remainder=0
PINNED_TRAVERSAL bodies=1690 visited_once=1690 never_visited=0
                 multiply_visited=0 unbound_entries=0
                 non_leaf_bodies=1550  verdict=PASS
```

Runtime workload (gen_kernel compiling a file) succeeded in all arms, 5 reps.

## 2. Size — the reliable result

| delta | value |
|---|---|
| selection only (B−A) | **+8.75 MB, +65.2%** |
| trampolines (C−B) | **+0.22 MB, +1.0%** |
| total policy (C−A) | **+8.96 MB, +66.8%** |
| bytes per installed declaration | ~4,823 |

Against the stated band, **C vs A at +66.8% is >25%: NOT default-ready.**

The attribution is the same as the select-all stress result, now on the
intended production policy: **the cost is selection, not trampoline
installation** — 65.2% from selection with installation off, 1.0% from the
trampolines themselves.

## 3. Timing — NOT reportable on this rig

**The time figures must not be judged against the bands, and the reason is
internal to the data.**

Arms B and C use *identical* selection and therefore run the *identical*
`gen_kernel` invocation. Their kernel times should match. They do not:

```
B kernel 19.6s [19.0-20.7]
C kernel 34.3s [29.8-37.2]     same work, +75%
```

A 75% spread on an operation that is byte-for-byte the same bounds this rig's
timing noise far above the ±25% build-time and ±5% runtime bands I was asked
to judge against. So the derived "snapshot time +23.1%", "kernel time +72.5%"
and "runtime +4.8%" numbers are **not** evidence of anything.

The runtime column shows the same problem from another angle: B (0.43) is
*slower* than C (0.33) despite C doing strictly more work, with barely
overlapping ranges.

Size is deterministic and unaffected by this; it is reported above with
confidence. Timing needs a quiet machine and more repetitions before any
band judgement is defensible.

## 4. Where this leaves default-on

```
Production selection policy v1     IMPLEMENTED and MEASURED
Snapshot size under policy v1      +66.8%  -> NOT default-ready
Cost attribution                   selection, not trampolines
Build/runtime timing               NOT MEASURABLE on this rig
Default-on readiness               NOT ESTABLISHED
```

The decision this points at is not an optimisation task on trampolines — they
cost 1%. It is about what selection retains: keeping 1,858 declarations
replaceable prevents the tree-shaking that produced the 13.42 MB baseline.
