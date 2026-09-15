# MAOT-5 (#69) — dispatch structure inventory and mechanism selection

Checkpoint 2. Read-only inventory of the fork at `b92efd823d83`. No compiler
or runtime change; no R3 borrow.

## The four remaining structures

All five AOT switchable-call states, corrected from checkpoint 1.

**Correction.** Checkpoint 1 said `ICData` was absent from the AOT state
machine. It is not: `HandleMissAOT` dispatches `kICDataCid` to
`DoICDataMissAOT`, and ICData is the polymorphic state of AOT switchable
calls. The earlier reading sampled a different switch in the same file.

| structure | holds | how the arm64 stub branches |
|---|---|---|
| `UnlinkedCall` | a **name** (`target_name`) + args descriptor; no target | resolves fresh through the miss handler |
| monomorphic (`Smi` cid + `Code`) | the target **`Code`** | `ldr R1, [CODE_REG + Code::entry_point_offset]` |
| `MonomorphicSmiableCall` | `expected_cid_` + **raw `entrypoint_`** | cid check, then `Code::entry_point_offset` |
| `SingleTargetCache` | target **`Code`** *and* a **raw copy of `entry_point_`** + cid range | `ldr R1, [R5 + SingleTargetCache::entry_point_offset]` |
| `ICData` (AOT polymorphic) | per-cid target, read as **`Code`** | `LoadCompressed(CODE_REG, …); ldr R1, [CODE_REG + Code::entry_point_offset]` |
| `MegamorphicCache` | the target **`Function`** | `ldr R1, [FUNCTION_REG + Function::entry_point_offset]` |

### They share exactly one chokepoint

Every AOT transition resolves the target through **`Function::CurrentCode()`**
— `DoUnlinkedCallAOT` explicitly (`target_function.CurrentCode()`),
`DoMegamorphicMiss` by storing the `Function` whose cached `entry_point_`
`SetCode` keeps in sync with it, and the rest by deriving `Code` or a raw
entry from the same place.

The AOT dispatch table uses that same accessor at
`dispatch_table_generator.cc:258`. So *one* accessor feeds the dispatch table
and all five switchable-call states.

That is what made "make `CurrentCode()` the trampoline" attractive: the
caches would not need invalidating at all, because a cached `Code` or raw
entry point *is* the indirection and keeps dispatching through the cell. It
would be the issue's "leave the cache valid because it resolves through a
mutable slot" branch, uniformly, for every structure at once.

## The hazard that decides the design

#66's cell is `Array(1)` holding a **`Function`**, and at registration
`kCurrentImpl` is the declaration's own `Function`. The #67 call site does
`LoadUniqueObject(cell)` → `LoadCompressed(element 0)` → `blr [fn +
entry_point_]`.

So the naive form of the trampoline is a cycle:

```
trampoline → load cell[0] = mutableFn → blr [mutableFn + entry_point_]
           → trampoline → …
```

Making `CurrentCode()` a trampoline on the same `Function` the cell points at
makes every mutable call infinitely recurse. This is not a tuning problem; it
is the design being self-referential, and it is why the mechanism could not
be selected from checkpoint 1's partial inventory.

### Three further constraints the inventory pins down

1. **`Code::owner()` must stay the declaration's `Function`.**
   `DoSingleTargetMissAOT` recovers the old target with
   `Function::RawCast(old_target_code.owner())`. A trampoline whose owner is
   anything else silently breaks single-target range extension.
2. **The trampoline needs a monomorphic entry.** `DoUnlinkedCallAOT` asserts
   `code.HasMonomorphicEntry()` before patching to the monomorphic state.
3. **`PrologueNeedsArgumentsDescriptor()` must not change.** It decides
   whether a call site may transition to monomorphic at all, so the
   trampoline must answer as the real body does.

Plus #66's standing constraint: two `Code` objects with identical
`Instructions` must not both be reachable after `ProgramVisitor::Dedup`. Each
trampoline embeds its own cell, so instructions differ per declaration — but
that must be verified, not assumed.

## Selection

**Recommended: the trampoline, in the split-identity form only.**

The cycle is resolved by separating the two roles #62 already distinguishes:

* the **declaration** `Function` keeps the trampoline as its `CurrentCode()`,
  so every structure that resolves through that accessor — dispatch table and
  all five switchable states — picks up the indirection with no invalidation;
* the **implementation** is a distinct `Function`, and the cell points at
  *that*, so the trampoline's load never returns to itself.

#66 already has the slots for this: `kCurrentImpl`, `kReleaseImpl`,
`kCurrentCode`, `kReleaseCode` and the impl-id fields are separate from the
declaration id. Today `kReleaseImpl` *is* the declaration `Function`; this
design makes them genuinely distinct, which is the real cost and the real
change.

**Rejected: rewriting dispatch-table entries on install.** The table is a
heap `uword[]` and is writable, but it needs a serialized reverse index from
declaration to every `(selector, cid)` slot, one inherited `Code` appears at
many cids, and it fixes only the table — the five switchable-call states
would each still need their own invalidation, each with a runtime decision
that consumes it. That is five more mechanisms where the trampoline needs
none.

**Not proposed: any JIT mechanism.** `jit` stays #64's control axis.

### What is not yet established

* That a trampoline can satisfy constraints 1–3 simultaneously. Each is read
  from the code, none is measured.
* That splitting declaration from implementation `Function` does not disturb
  #66's selected-set-exact or #68's escape accounting. Both have regressions
  that must stay green.
* Whether `super`, already lowered to a static call, needs anything at all —
  read from the lowering, not measured.

This is a recommendation, not an implementation. Nothing is built until the
split-identity design is approved.
