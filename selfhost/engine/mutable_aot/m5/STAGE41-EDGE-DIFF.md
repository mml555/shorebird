# STAGE41 — the Gate A differences are not the release edge

Fork `a774b308e6a` (clean, stamped). Retention roots **OFF** in every arm.
Diagnosis only: no recording point changed, no policy changed.

**Result: 3/3 LOST and 175/175 EXTRA are explained, and none of them is
attributable to the Stage 40 release edge. The release edge introduces zero
declarations that a build without it does not already have.**

## 1. Why a set difference could not answer this

Stage 40 compared two sets of survivors. A set difference cannot distinguish

* the edge into this declaration disappeared,
* the declaration that used to pull it in disappeared,
* it was never pulled in by an edge at all.

`--maot_dump_reach_edges` writes one `caller \t callee \t kind` line per
discovered edge. The caller is the function being compiled and walked; edges
found outside such a walk read `<root>`, which is exactly the missing-edge /
missing-root distinction.

The edge must be logged where the retained set is actually populated. That is
`AddTypesOf`, not `AddFunction`: `AddFunction` feeds
`possibly_retained_functions_`, while `--maot_dump_retained` prints
`functions_to_retain_`, and only `AddTypesOf` inserts into it. Both are logged.

**Coverage, stated before any conclusion is drawn from the graph:**

```
A retained = 22799   with no in-edge = 0
B retained = 22971   with no in-edge = 0
```

Every retained declaration is explained by at least one edge. The graph is not
a partial view of the set it is being diffed against.

## 2. The arms

The two things Mutable-AOT does to a selected declaration are independent, so
they get a 2x2 rather than a ladder — and a control that says whether the
selection metadata does anything at all on its own.

|  | inlining allowed | inlining refused (default) |
|---|---|---|
| indirection OFF | **E** neither | **C** inlining only |
| indirection ON | **D** indirection only | **B** production, both |

`k0` = kernel with selection OFF. `k1` = same source, selection ON
(`MAOT_SELECT_ALL_NON_SDK=1`, `MAOT_SELECT_URI_PREFIX=package:vm/`).
The two kernels are the same length and differ in 2,493 bytes.

```
arm  configuration                          retained   edges
A    k0 baseline kernel, stock              22799      74949
E    k1: neither mechanism (control)        22799      74949
C    k1: inlining refusal only              22972      75633
D    k1: call indirection only              22804      74998
B    k1: both (production)                  22971      75692
```

**Arm E reproduces the baseline reachability graph exactly — all 74,949 edges,
identical sets, `A-only = 0`, `E-only = 0`.** That is three things at once: the
pipeline is deterministic, so none of the differences below are run-to-run
noise; the selection metadata is inert on its own; and the control could have
failed and did not.

## 3. Attribution

```
arm  configuration                          LOST     EXTRA
E    neither mechanism (control)            0        0
C    inlining refusal only                  2        175
D    call indirection only                  1        6
B    both (production)                      3        175
```

### LOST

| declaration | baseline predecessor | missing edge kind | dropped by |
|---|---|---|---|
| `dart:_compact_hash::_CompactLinkedIdentityHashSet&_HashFieldBase&SetMixin@3099033.` (mixin-application constructor) | `package:vm/.../dynamic_interface_annotator.dart::_annotateComponent` | static call table (`needed for symbolic stack traces`) | inlining refusal |
| `dart:mixin_deduplication::_MixinApplication21&Object&TreeVisitor1DefaultMixin&ExpressionVisitor1DefaultMixin@28353248.` (mixin-application constructor) | `package:vm/.../unreachable_code_elimination.dart::_transformComponent` | static call table | inlining refusal |
| `dart:core::_StringBase.get:isNotEmpty` | `dart:core::_Uri.resolveUri` | inline tree (`retain:AddTypesOf`, no call edge at all) | call indirection |

All three have **zero** in-edges in the production arm. In all three cases the
predecessor is still retained and still compiled; the specific edge is gone.
None of the three is called by anything in the Mutable-AOT program: each was
retained in the baseline only because it appeared in a static call table or in
another function's inline tree.

`_annotateComponent` makes the mechanism visible. It has 15 baseline
static-call-table edges; the production arm has 15 release edges covering the
same 14 `package:vm` targets, and the 15th — the `dart:` mixin-application
constructor, which is not a mutable declaration — has no call site left at all.

### EXTRA

```
present in E (neither mechanism)  = 0
present in C (inlining refusal)   = 175
present in D (call indirection)   = 6
present in B (production)         = 175
```

One rule accounts for all of them: **a declaration that may not be inlined must
exist as a real function, and the calls in its body become real calls.** All
175 are absent from the baseline graph entirely — never a callee, never a
caller — and all 175 appear in arm C, which has no call indirection and
therefore no release edge.

Of the 159 the production arm reaches through a release edge, **all 159 are
also present in arm C**, reached there by an ordinary static call table edge
(156) or by a static call table edge and a dispatch-table selector together
(3). The release edge introduces **0** declarations that the other arms lack.

## 4. What the release edge actually does

Counted as `(caller, callee)` pairs:

```
baseline static-call-table pairs                  37928
production static-call-table pairs                35766
production release-edge pairs                      2708

static pairs the baseline has and production lacks 2274
   re-supplied by the release edge                 1921
   not re-supplied                                  353
   ... callees of those that production drops         2   (the two above)

release pairs with no baseline static counterpart   787
   distinct callees                                 358
   callees the baseline retained anyway             199
   callees the baseline did not retain              159   (= the EXTRA)
```

The 353 not re-supplied are calls that no longer exist in the production build
because the caller's body changed; only two of them have no other reacher.

## 5. What this says about Gate A

Gate A as written — `LOST = 0` and `EXTRA = 0` against a stock baseline — is
measuring the cost of refusing to inline mutable declarations. That refusal is
not incidental: a declaration whose body has been inlined into its callers has
no single body to replace. **A build that satisfies Gate A exactly is a build
in which mutable declarations were inlined, which is a build in which they are
not replaceable.**

This is a proposal about the gate, not a disposition change. No recording
point was changed and no policy was changed.

## 6. Falsification arms that were run and could have failed

* **Arm E** could have shown that the selection metadata alone moves the
  retained set. It reproduced the baseline graph exactly, edge for edge.
* **Arm D** could have shown the release edge introducing declarations. It
  introduces 6 relative to the baseline, all 6 also present in arm C.
* **Coverage** could have shown retained declarations with no in-edge, which
  would have made every attribution above unsupported. It is 0 in both arms.
* The naming-artifact explanation for the two mixin applications is refuted a
  second way here: their full names end in `.`, so they are the synthesized
  **constructors**, and the predecessor edge that carried them is a static call
  table entry that is simply absent.

## Reproduce

```
selfhost/engine/mutable_aot/m5/lib/edgediff_m5.py     # arms A and B, the diff
selfhost/engine/mutable_aot/m5/lib/edgeablate_m5.py   # arms C, D, E, the 2x2
selfhost/engine/mutable_aot/m5/lib/edgeanalyze_m5.py  # edge-kind breakdowns
```

`EDGEDIFF_REUSE=1` re-analyses without re-running the snapshots.
