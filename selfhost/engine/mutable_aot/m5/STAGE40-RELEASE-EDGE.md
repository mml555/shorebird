# STAGE40 — release-only reachability edge: mechanism works, Gate A fails by 3

Fork `0e47504314a` (clean), stamped.
Retention roots **OFF** throughout. Call indirection **ON** (production shape).

**Stopping at the Gate A stop condition: three baseline-retained declarations
are lost.**

## 1. The mechanism

The #67 lowering records no static call target, which is the edge ordinary AOT
reachability walks. The backend now records the release target as a
reachability-only edge at the moment it emits a cell-indirect call;
`AddCalleesOf` drains those edges for the caller that recorded them.

That ordering is what makes it an **edge and not a root**: an unreachable
caller is never compiled, so its edges are never recorded and its callees are
never added. The list is held by the `Precompiler`, not the `ObjectStore`, so
it is a GC root during precompilation and unreachable from any snapshot root.

## 2. It fixes the collapse

| | retained | snapshot | selected | eligible | workload |
|---|---|---|---|---|---|
| baseline A | 22,799 | 13.42 MB | 0 | 0 | ok |
| policy B, roots OFF | **22,971** | 14.01 MB | 1,853 | 1,775 | **ok** |

Before the edge, this exact configuration retained **2,202** and segfaulted.
Eligibility is also healthy again at 1,775/1,853 (96%) — the earlier 723 was
the falsification flag, as reported.

## 3. Gate B — edge accounting: PASS

```
A: RELEASE_EDGES recorded=0     consumed=0     missing=0  pending_at_end=0
B: RELEASE_EDGES recorded=3207  consumed=3207  missing=0  pending_at_end=0
```

`missing_release_edge_for_required_mutable_call = 0`, every recorded edge is
consumed, nothing is left pending, and the baseline arm records none at all —
so the mechanism is inert when there is nothing mutable.

## 4. Gate A — baseline preservation: **FAIL**

```
LOST  = BASELINE_RETAINED - MAOT_RETAINED = 3     required 0
EXTRA = MAOT_RETAINED - BASELINE_RETAINED = 175
```

The three lost:

```
dart:_compact_hash__CompactLinkedIdentityHashSet&_HashFieldBase&SetMixin@...
dart:mixin_deduplication__MixinApplication21&Object&TreeVisitor1DefaultMixin&...
dart:core__StringBase@0150898_get_isNotEmpty
```

**A naming artifact was the obvious explanation and it is refuted.** Two of the
three are synthesized mixin applications whose names carry hash suffixes, so
the set difference could have been a renaming. Comparing with `@<digits>`
stripped, none of the three appears in B. B also retains 49 other
`StringBase` members, so the class did not vanish — that specific getter did.

**P1 is not the explanation either.** Arm B's kernel is the one built with
`MAOT_P1_CLEAR_MUTABLE_CONSTANTS=0`, so constant suppression was already off
for this measurement.

Cause not established. Three functions out of 22,799 is 0.013%, but the gate
is set-based for good reason and I am not going to argue it down to a
percentage.

### EXTRA, classified

```
package:vm       169    <- application declarations
package:kernel     3
package:front_end  2
dart: (SDK)        1
```

169 application declarations retained beyond baseline, against a target of 0.
Also unexplained.

## 5. Not run

Gates C and D, and the compact replacement regression. The ruling stops at a
lost baseline declaration, and routing/rebinding evidence gathered on a build
that is not retention-neutral would have to be re-gathered anyway.

## 6. Status

```
Release-only reachability edge   IMPLEMENTED
Reachability collapse            FIXED (2,202 -> 22,971, workload ok)
Gate B edge accounting           PASS (3207/3207/0)
Gate A baseline preservation     FAIL -- LOST = 3
Gate A extras                    175, of which 169 application declarations
Gates C, D, replacement regression  NOT RUN
```
