# MAOT-5 (#69) — switchable-call state matrix: first three states converge

## Accepted work protected first

**One cell → one pool entry**, counted rather than argued, on the case that
used to duplicate:

```text
pool entries for the cell of …cls:OnlyShape::method:describe: 1  (static call sites 3)
MAX pool entries for any one cell: 1
```

Three static call sites, one pool entry. Before selection-time seeding,
`LoadUniqueObject` appended a new entry at each site.

## Granular escape records, and proof the install decision reads them

The coarse `instance-dispatch / UNMODELED_BLOCKING` record is replaced by
seven per-state records:

| record | disposition |
|---|---|
| `instance-dispatch/dispatch-table` | **SLOT_PRESERVING** |
| `instance-dispatch/UnlinkedCall` | UNMODELED_BLOCKING |
| `instance-dispatch/monomorphic` | UNMODELED_BLOCKING |
| `instance-dispatch/MonomorphicSmiableCall` | UNMODELED_BLOCKING |
| `instance-dispatch/SingleTargetCache` | UNMODELED_BLOCKING |
| `instance-dispatch/ICData` | UNMODELED_BLOCKING |
| `instance-dispatch/MegamorphicCache` | UNMODELED_BLOCKING |

`NoteDecision` projects each blocking disposition into exactly one escape,
and `StageReplacement` refuses while any escape stands. The consumption is
visible as a number: the escape count moved from **1** (coarse) to **6** (one
per unproven state), and `OnlyShape.describe` reports
`escapes=6, installable=False`. Proving a state flips its record to
`SLOT_PRESERVING`, which removes its escape; only when all are proven does a
declaration become installable.

**Nothing was made installable.** `Alpha.v` remains `installable: false`.

## A structural finding: the interface call form never uses these states

Driving the genuinely virtual fixture recorded **zero** switchable states.
That is not a gap in the instrumentation — an interface call on a statically
known interface compiles to `DispatchTableCallInstr`, a direct indexed branch
with **no miss handler**, so `HandleMissAOT` is never entered.

The six switchable states belong to the **dynamic** call form. This is
concrete support for the ruling's insistence that `virtual`, `interface` and
`dynamic` be evidenced separately: they do not merely *deserve* separate
evidence, they traverse different machinery.

## States reached and their stored targets

Driving a `dynamic` receiver, and ordering receivers so a mutable target
lands on the monomorphic-miss path:

| state | times observed | stored target converges on the trampoline |
|---|---|---|
| `UnlinkedCall` | 7 | **yes** — SLOT_PRESERVING |
| `monomorphic` | 1 | **yes** — SLOT_PRESERVING |
| `ICData` | 1 | **yes** — SLOT_PRESERVING |

`SLOT_PRESERVING` here is computed, not asserted: the record is emitted only
when the state's stored executable target equals the registry's trampoline
for that declaration.

Order mattered and is worth recording. A site that links to `Alpha` first
makes the later `Beta` call the monomorphic miss — and `Beta.v` is not
mutable, so nothing is recorded. Linking to `Beta` first and then calling
`Alpha` puts the mutable declaration on the miss path. Both calls must be the
*same* site, so the two receivers go through one helper; two separate `x.v()`
expressions are two sites, and the second would start Unlinked.

## Replacement observed through the dynamic path

```text
dyn.0        = NEW2-ALPHA      (reflects the cell after the earlier swaps)
dyn.warm     = NEW2-ALPHA      200,000 iterations
swap.3 = 0
dyn.1        = NEW-ALPHA
dyn.warm.1   = NEW-ALPHA
mono.beta    = BETA
mono.alpha   = NEW2-ALPHA      Alpha through a site previously linked to Beta
beta.v       = BETA            untouched throughout
```

## What is NOT proven

* `MonomorphicSmiableCall`, `SingleTargetCache` and `MegamorphicCache` were
  never reached. Not observed is not disproven.
* A per-state `OLD → NEW → NEW2` with swaps interleaved **inside** each state
  was done for the dispatch-table and dynamic paths, **not** separately for
  `monomorphic` and `ICData`. For those two I have convergence of the stored
  target plus a post-swap read, which is weaker than the full sequence.
* `interface`, `super` and `dynamic` remain separate axes. Only the dynamic
  form exercised these states.
* No #64 cell moves. Nothing installs through `StageReplacement`.

## Proposal, not applied

For `UnlinkedCall`, `monomorphic` and `ICData`:

* **old escape** — `instance-dispatch/<state>`, `UNMODELED_BLOCKING`, one
  escape each, consumed by `StageReplacement`.
* **why it was blocking** — the state caches an executable target at a miss,
  and nothing showed that target was the declaration's trampoline rather than
  a frozen body.
* **new mechanism** — selection-time pool seeding gives the declaration one
  canonical cell entry and a trampoline installed as its `CurrentCode`; every
  AOT transition resolves through `Function::CurrentCode()`, so the cached
  target *is* the trampoline, which loads the cell on every call.
* **production decision that observes it** — `MaotNoteSwitchableState`
  compares the stored target against the registry trampoline at each
  transition and emits `SLOT_PRESERVING` only on equality; the escape
  projection feeding `StageReplacement` is the same one.
* **new disposition** — `SLOT_PRESERVING`.

I have not applied this. Two of the three lack the full interleaved
`OLD → NEW → NEW2` inside the state, and that gap should be closed or
explicitly waived first.
