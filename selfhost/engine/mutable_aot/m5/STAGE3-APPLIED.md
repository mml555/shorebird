# MAOT-5 (#69) — granular dispositions applied; ICData proven

## Wording, kept honest

The measured sequence is **not** a release baseline. It is:

```text
NEW-ALPHA -> NEW2-ALPHA -> NEW-ALPHA
```

Three successive implementation changes through one already-warmed cache
state, with no cache mutation. That is the property under test; it is not
rewritten as `OLD → NEW → NEW2`.

## Dispositions applied — only the proven combinations

The axis is **(call form × switchable state)**, not state alone.

| record | disposition |
|---|---|
| `instance-dispatch/dispatch-table` | **SLOT_PRESERVING** |
| `dynamic/UnlinkedCall-linked` | **SLOT_PRESERVING** |
| `dynamic/monomorphic` | **SLOT_PRESERVING** |
| `dynamic/MonomorphicSmiableCall` | UNMODELED_BLOCKING |
| `dynamic/SingleTargetCache` | UNMODELED_BLOCKING |
| `dynamic/ICData` | UNMODELED_BLOCKING |
| `dynamic/MegamorphicCache` | UNMODELED_BLOCKING |
| `interface/unproven` | UNMODELED_BLOCKING |
| `super/unproven` | UNMODELED_BLOCKING |

`interface` and `super` are explicit records rather than an absence, so
nothing can inherit the dynamic results by omission. The interface form
**cannot** inherit them in any case: it compiles to `DispatchTableCallInstr`,
a direct indexed branch with no miss handler, and never enters this
machinery.

## The production decision consumes them

```text
Alpha.v  installable = False   escapes = 6
blocking_records: dynamic/MonomorphicSmiableCall, dynamic/SingleTargetCache,
                  dynamic/ICData, dynamic/MegamorphicCache,
                  interface/unproven, super/unproven
```

Three `SLOT_PRESERVING` records stopped contributing escapes; six still do.
The refusal is attributable to **named** remaining blockers, not to an
aggregate flag — introspection reports `blocking_records` beside
`installable` precisely because an escape count cannot say which form is
unproven, nor whether a proven form is still being counted by mistake.

Positive evidence was consumed without weakening fail-closed behaviour
anywhere else.

## ICData reached naturally and tested the same way

Driving **one** site polymorphically (alternating receiver classes) pushes it
past monomorphic into ICData; the reads afterwards use Alpha only, through
that same site.

| state | sequence | counts | no cache mutation |
|---|---|---|---|
| `dynamic/UnlinkedCall-linked` | NEW-ALPHA → NEW2-ALPHA → NEW-ALPHA | 9/9/9/9 | **true** |
| `dynamic/monomorphic` | NEW-ALPHA → NEW2-ALPHA → NEW-ALPHA | 1/1/1/1 | **true** |
| **`dynamic/ICData`** | NEW-ALPHA → NEW2-ALPHA → NEW-ALPHA | **1/1/1/1** | **true** |

`st.ic.beta = BETA`: the other cid entry in the same inline cache is
untouched, so the IC is serving two declarations independently.

**ICData is proven but NOT reclassified.** It was not in the authorized set,
and the pattern is prove → propose → authorize. The evidence is here; the
disposition change is not applied.

## Self-cycle invariant now mechanical

`cell.implCode` may never be the declaration's own trampoline, or the
trampoline branches to itself and the process spins with no diagnostic.
`CellCodeWouldSelfCycle` is checked at **both** cell writers:

* the production commit path refuses the install;
* the diagnostic swap returns `-5`.

Verified: `selfcycle.refused = -5` rather than a hang. No redundant mechanism
was added — this is a check at the single point both writers already pass
through.

## An accepted-work regression, found and fixed

Splitting `instance-dispatch` broke #68's devirtualization join, which
matched that exact class name and then counted zero. The condition still has
to mean *instance dispatch is blocked*, so it now counts every **still-
blocking dispatch-form record** rather than one fixed name. m4 is green
again: 18 arms, 23 conditions, 0 failed.

| lane | result |
|---|---|
| m2 (#66) | `runtime_implementation_registry = ESTABLISHED` |
| m3 (#67) | exit 0 |
| m4 (#68) | 18 arms / 23 conditions, 0 failed, `ESTABLISHED` / `READY` |

## Not claimed

* `MonomorphicSmiableCall`, `SingleTargetCache` and `MegamorphicCache` remain
  unreached. Unreached is unproven, not safe.
* `interface` and `super` have no evidence at all yet.
* No #64 cell moves. Nothing installs through `StageReplacement`.
