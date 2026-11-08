# MAOT-5 (#69) — interface applied; MonomorphicSmiableCall NOT proven

## interface/dispatch-table applied

```text
Alpha.v  installable = False   escapes = 4
blocking_records: dynamic/MonomorphicSmiableCall, dynamic/SingleTargetCache,
                  dynamic/MegamorphicCache, super/unproven
```

`interface/unproven` is gone, replaced by the concrete mechanism
`interface/dispatch-table`. Named-blocker attribution intact; four remain,
exactly as predicted.

## MonomorphicSmiableCall — NOT proven. The pass would have been vacuous.

```text
st.ms.old  = NEW-ALPHA
st.ms.new  = NEW2-ALPHA
st.ms.new2 = NEW-ALPHA
st.ms.counts = 0/0/0/0
st.ms.noCacheMutation = true      <-- VACUOUS
st.ms.beta = BETA
```

The values changed, so that site does route through the cell. But the
observation count is **0/0/0/0**: the site was never in
`MonomorphicSmiableCall` at all. "Count unchanged" means the state was never
entered, not that its cache survived.

The standard requires the state to be **positively identified** at the warmed
site. It was not. **No reclassification is proposed.**

This is exactly the failure mode the count instrument is supposed to expose
and, applied carelessly, would have produced a green result from an absent
state.

## The can_patch_to_monomorphic contradiction — resolved, and my earlier claim was wrong

Recording the branch *actually taken* inside `DoUnlinkedCallAOT`, rather than
labelling by the flag at the dispatch site:

```text
UnlinkedCall transition: can_patch_to_monomorphic=1,
                         installed state object = 229
```

`229` is a **Smi** — the receiver's class id — so this transition installed
the **plain monomorphic** form, which is why `kSmiCid` and
`monomorphic-observed` were seen. That half is fully explained.

An earlier run of the same probe recorded `flag=0, cid=33`. So **both flag
values occur in one program**, and `UnlinkedCall::New`'s
`!FLAG_precompiled_mode` default is not the whole story — different
`UnlinkedCall` objects reach the runtime with different values.

What I previously wrote — that the flag "reads as always false in AOT, yet
both branches occur" — was half right and stated too confidently. The flag is
**not** uniformly false at runtime; it is observed as both 0 and 1. The
remaining open question is narrow: which creation path yields `flag=1`, and
what cid 33 is. The `flag=0` branch's object was not named because the
shared record cap was consumed by the `flag=1` case.

That is an honest partial result, not a resolved one.

## Not claimed

* `dynamic/MonomorphicSmiableCall` stays **UNMODELED_BLOCKING**.
* `SingleTargetCache` and `MegamorphicCache` stay blocking. No exclusion
  logic was built, and their preconditions remain reachable in principle.
* `super` not yet measured.
* No #64 cell moves.
