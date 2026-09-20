# STAGE42 — the last C-vs-B difference is a compile-order artifact, not a lost edge

Fork `a774b308e6a` (clean, stamped). Retention roots **OFF** in every arm.
Diagnosis only: no recording point changed, no policy changed, no inlining
policy changed.

## 0. Revised Gate A, as measured

```
C retained            = 22972
B retained            = 22971
LOST_ROUTING  (C - B) = 1     dart:core::_StringBase.get:isNotEmpty
EXTRA_ROUTING (B - C) = 0
EXTRA_ROUTING application declarations = 0
```

## 1. The result

`_StringBase.get:isNotEmpty` is **inlined into `_Uri.resolveUri` in both arms**.
The cell-indirect lowering never sees a call to it. There is no missing
reachability edge and nothing for the release edge to reconstruct.

What differs is one level deeper, and it is a decision stock AOT makes
differently depending on **when** a function is compiled.

## 2. The trace the gate asked for

| | arm C (control) | arm B (production) |
|---|---|---|
| compile ordinal of `_Uri.resolveUri` | **8** of 21,748 | **534** of 21,747 |
| inliner decision, `isNotEmpty` into `resolveUri` | inlined, 3 sites | inlined, 3 sites |
| inliner decision, `isEmpty` into that inlined body | **`NO — intrinsic`** | **inlined** |
| `resolveUri` inlining growth | 0.450980 (102 → 46) | 0.568627 (102 → 58) |
| call representation before lowering | `StaticCall` to `isEmpty` survives inside the inlined `isNotEmpty` body | no call — `isEmpty` is folded in |
| call representation after lowering | ordinary static call (`isEmpty` is not a mutable declaration, so no dispatch cell) | no call site exists |
| inline-tree membership of `isNotEmpty` | present in `Code::inlined_id_to_function()` | absent |
| retention reason for `isNotEmpty` | `AddTypesOf` from the inline-tree walk in `AddCalleesOf(_Uri.resolveUri)` | none |
| stage C gains it | `AddCalleesOf`, inlined-functions walk, symbolic stack traces | — |
| stage B ceases to have it | never acquires it | — |

### First phase where C and B differ

Not a phase. **The precompiler's worklist order**, which diverges at
ordinal **2** of ~21,748:

```
#1  C: dart:_http::_get__httpConnectionHook     B: same
#2  C: dart:_http::_init__httpConnectionHook    B: StructOrUnionNativeTypeCfe.
...
#8  C: dart:core::_Uri.resolveUri               B: (compiled at #534)
```

A cell-indirect call records no static-call target, so its callee is queued by
the release edge drained at the top of the next `AddCalleesOf` rather than by
the static-call-table walk of the current one. The queue is LIFO, so this
reorders everything downstream.

## 3. Why the order decides it

`inliner.cc` refuses to inline intrinsics in AOT **unless** `AlwaysInline`
says otherwise:

```cpp
if (CompilerState::Current().is_aot() && function.is_intrinsic() &&
    !inliner_->AlwaysInline(function)) {          // -> "intrinsic" bailout
```

and for a getter `AlwaysInline` is

```cpp
const intptr_t count = function.optimized_instruction_count();
if ((count != 0) && (count < FLAG_inline_getters_setters_smaller_than)) return true;
```

`optimized_instruction_count` is a **cache written by `CollectGraphInfo`** the
first time any compilation builds that callee's graph. Before that it is 0, so
`AlwaysInline` is false and the intrinsic bailout fires. Afterwards it is small
and the bailout is skipped. The predicate is therefore a function of time, not
of the callee.

### It is not stable within a single build

From one invocation each, over the same 404 call sites to
`_StringBase.get:isEmpty`:

```
arm  decisions  refused "intrinsic"  inlined   refused at ordinals   first inline
C    404        14                   390       <= 38                 60
B    404         4                   400       <= 41                 96
```

A clean time split in both arms. `_Uri.resolveUri` sits at #8 in C — inside the
refusal window — and at #534 in B, far outside it. The other refusals in C land
in `_normalizeRelativePath` #9, `_GrowableList.join` #11, `_joinWithSeparator`
#15, `StringBuffer.write` #25, `_substringMatches` #37, `_Uri.get:hasScheme`
#38 — and those same functions are exactly where arm C's edge log shows the
extra static-call edges into `isEmpty` that arm B does not have.

## 4. Intervention: the chain confirmed by manipulation, not only observation

`--inline_getters_setters_smaller_than=0` makes `AlwaysInline` unconditionally
false for getters, so the intrinsic bailout always fires and the order
sensitivity is removed. Nothing else changes.

```
arm                                         retained   isNotEmpty
B  + --inline_getters_setters_smaller_than=0   23362      retained
C  + --inline_getters_setters_smaller_than=0   23362      retained

LOST_ROUTING  (C - B) = 0
EXTRA_ROUTING (B - C) = 0
retained multisets identical = True   (23,362 entries, 0 differences)
```

**With the one order-sensitive predicate neutralised, the production routing
arm and the semantic control produce the identical retained set — exactly, as
a multiset, not merely in count.**

Either half of this could have refuted the chain: the flag could have failed to
restore the retention in B, or it could have changed C. Neither happened.

`--inline_getters_setters_smaller_than=0` is an **instrument, not a proposal**.
It retains 23,191 distinct declarations against 22,971/22,972, so it is a
program-wide inlining change and is not offered as a production setting.

## 5. What this means for the gate

`LOST_ROUTING = 1` is not a reachability dependency the release edge failed to
reproduce. In the production arm nothing calls `_StringBase.get:isNotEmpty` and
nothing inlines it into surviving code; it is absent from the program. The
control retains it only as a symbolic-stack-trace artifact of an inlining
decision that stock AOT itself makes both ways inside a single build depending
on compilation order.

A requirement to preserve inline-tree-derived retention would therefore require
reproducing an artifact that stock AOT does not produce stably.

**Proposal, for disposition — not applied:** routing neutrality should be
compared over declarations that have at least one call or structural edge of
their own, excluding retention that exists *only* as an inline-tree entry of
another function. Under the present measurement that set difference is already
`0 / 0` in both directions.

The alternative — implementing a generic "preserve inline-tree reachability"
mechanism — would have to reproduce a decision whose outcome depends on
worklist position, and the evidence above says that outcome is not stable
enough to be a contract.

## Reproduce

```
scratchpad/orderinline.sh   # one invocation per arm: --trace_precompiler
                            # and --print_inlining_tree together
scratchpad/interv.sh        # the --inline_getters_setters_smaller_than=0 arms
selfhost/engine/mutable_aot/m5/lib/edgediff_m5.py    # the edge graphs
```
