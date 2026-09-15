# MAOT-5 (#69) — first virtual routing gate: PASS

A **genuinely virtual** AOT instance call routes through the declaration's
trampoline to its mutable cell, and observes `OLD → NEW → NEW2` with no
dispatch or cache mutation.

## The design change

Pool membership is now a property of **being selected**, not a side effect of
#67's static-call lowering:

```text
selected declaration -> cell -> ONE canonical global-pool entry -> trampoline
```

`SeedMutableAotRoots` adds each cell once, with `kPatchable`, while the global
builder is live and before `Iterate()` compiles anything.

`kPatchable` rather than `FindObject`: a non-patchable entry deduplicates
through `ObjIndexPair::Hash → Instance::CanonicalizeHash`, which faults on an
`Array` holding a VM `Function`. #67 found that once; this does not
rediscover it.

**One mechanism, not two.** #67's call-site lowering now reads the same seeded
index rather than calling `LoadUniqueObject`, which called
`AddObject(kPatchable)` and appended a **new** entry on every call — a
declaration with three call sites had three pool entries for one cell, and
the trampoline had no single entry to name. If the index is missing the
lowering records an escape and fails closed rather than registering a second
copy.

The index is carried through `MaterializeMutableAotRegistry`, which rebuilds
the table after seeding.

## Preconditions — measured, not assumed

`cls:Alpha::method:v`, two implementors and an environment-chosen receiver so
neither CHA nor TFA can pin the type:

| field | value |
|---|---|
| `selected` | `true` |
| **`indirect_call_sites_emitted`** | **`0`** — no static or devirtualized site |
| `dispatch_cell_length` / `has_code` | `2` / `true` |
| seeded pool entry | yes (14 cells seeded) |
| trampoline | installed, `tramp.identity = 1` (it *is* the Function's current code) |

## Identity: the dispatch table holds the trampoline

```text
dispatch-table slots holding the trampoline for …cls:Alpha::method:v:  1  (table len 5845)
dispatch-table slots holding the trampoline for …cls:AlphaNew::method:v:  0
dispatch-table slots holding the trampoline for …cls:AlphaNew2::method:v: 0
```

Exactly one slot, in the structure a real virtual call indexes. The two
replacement declarations hold zero, correctly — they are called directly, not
virtually.

## Behaviour: OLD → NEW → NEW2 on the warmed virtual route

```text
virt.0        = OLD-ALPHA
virt.warm     = OLD-ALPHA      200,000 iterations, linked dispatch state
swap.1 = 0
virt.1        = NEW-ALPHA
virt.warm.1   = NEW-ALPHA      the SAME warmed site
swap.2 = 0
virt.2        = NEW2-ALPHA
virt.warm.2   = NEW2-ALPHA
beta.v        = BETA           untouched throughout
```

`Beta` shares the selector and is a different declaration; it never moves, so
this is not a shared-cell artefact.

Only `cell.implFunction` / `cell.implCode` changed. The swap writes nothing
else — no dispatch-table slot, no cache, no trampoline, no `Function`
entry point.

## This is routing evidence, not acceptance evidence

`Dart_MaotDiagnosticCellSwap` bypasses `StageReplacement` and every escape
check, deliberately. It does not advance a version, record an implementation
id, or check ABI. Nothing here has been installed through the production
path.

## The #68 escape, unchanged

```json
{
  "optimization_class": "instance-dispatch",
  "disposition": "UNMODELED_BLOCKING",
  "decision": "a selected instance member is reachable through dispatch forms
               #68 does not model; #69 owns virtual, interface, super and
               dynamic dispatch",
  "consumed_by": "MaotRegistry::StageReplacement refuses installation while
                  this disposition stands"
}
```

`Alpha.v` remains `installable: false`, `optimizer_escapes: 1`. No
disposition was changed. This record is submitted for the reclassification
decision, not reclassified.

What has changed is that the reason it cites — *dispatch forms #68 does not
model* — now has one form that **is** modelled: the AOT dispatch table, whose
slot demonstrably holds the trampoline that resolves the cell.

Six forms remain unproven: `UnlinkedCall`, monomorphic,
`MonomorphicSmiableCall`, `SingleTargetCache`, `ICData`, `MegamorphicCache` —
and `dynamic` and `interface` require separate evidence from each other.

## Not claimed

* No #64 cell moves.
* Only the dispatch-table path is shown. Which state this warmed site
  actually reached was not captured directly; the table holding the
  trampoline plus the observed swap is the evidence, and the remaining states
  are still owed one at a time.
* The serializer population threshold remains parked. Seeding changes pool
  size and may move it again; that is not progress on that defect either way.
