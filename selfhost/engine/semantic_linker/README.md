<!-- cspell:words semantic linker dartaotruntime aot -->
# SEMANTIC-LINKER-1 — runtime feasibility

Tracker: [#36](https://github.com/mml555/shorebird/issues/36).

**Feasibility only.** Nothing here changes the supported cell, the production
CLI, the patch format, the signing model, the control plane, or the physical
qualification state. Every artifact in this directory is experiment-only.

## The question

Can a patch-defined Dart object or function execute as bytecode, call retained
AOT code, be called from AOT, share a heap with AOT objects, preserve identity
and GC safety, cross typed AOT boundaries, and survive real AOT optimizer
assumptions?

It is the next question after the two the fork has already answered on host
macOS/arm64:

- [`../killgate/`](../killgate) — an AOT function's body **can** be repointed at
  interpreted bytecode and execute (2026-08-04), and patch bytecode **does**
  bind into the base program when retention is declared (Spike B, 2026-08-05).
- [`../dynmod/`](../dynmod) — dynamic modules are **additive**, not a
  replacement mechanism. That is prior evidence this lane depends on and must
  not contradict.

## Gates

| | gate | state |
|---|---|---|
| [#37](https://github.com/mml555/shorebird/issues/37) | G0 freeze the baseline and source provenance | **ACCEPTED / CLOSED** — [`g0_freeze/`](runtime_feasibility/g0_freeze) |
| [#38](https://github.com/mml555/shorebird/issues/38) | G1 matched Dynamic Modules OFF/ON substrate | **ACCEPTED / CLOSED** — [`g1_substrate/`](runtime_feasibility/g1_substrate) |
| [#39](https://github.com/mml555/shorebird/issues/39) | G2 AOT ↔ bytecode execution, shared heap identity | **PASS, awaiting PM decision** — [`g2_execution/`](runtime_feasibility/g2_execution) |
| [#40](https://github.com/mml555/shorebird/issues/40) | G3 class, type, generic, GC interoperability | **PASS, awaiting PM decision** — [`g3_types_gc/`](runtime_feasibility/g3_types_gc) |
| [#41](https://github.com/mml555/shorebird/issues/41) | G4 optimizer adversity, required compiler fences | **COMPLETE, awaiting PM decision** — [`g4_optimizer/`](runtime_feasibility/g4_optimizer) |
| [#42](https://github.com/mml555/shorebird/issues/42) | G5 replay on pinned current Dart | NOT TRIGGERED — G4 found a fenceable policy, not a lineage limitation |
| [#43](https://github.com/mml555/shorebird/issues/43) | G6A categorized negative controls | |
| [#44](https://github.com/mml555/shorebird/issues/44) | G6B substrate/interface/module/execution cost | |
| [#45](https://github.com/mml555/shorebird/issues/45) | G6C one-command reproduction harness | |
| [#46](https://github.com/mml555/shorebird/issues/46) | FINAL classified verdict and lane routing | |

## Standing rule for this lane

G4–G6 are expensive **because** they assume what the earlier gates establish. Do
not start them, and do not fill in #43's scaffolding, ahead of an explicit
decision on the gate before them. The Dart durability repair is
[#47](https://github.com/mml555/shorebird/issues/47) and is deliberately NOT
part of this lane: nothing qualified is rebuilt for it.

## The contract obligation G4 produced

Release tooling must emit `can-be-overridden` for **every patchable member**.
`extendable` on the class and `callable` on the member are *not* sufficient: the
bypassed arms carried both and the precompiler still devirtualized, and at a
field receiver with inlining permitted it inlined the body outright. See
[`g4_optimizer/RESULT.md`](runtime_feasibility/g4_optimizer/RESULT.md).

## The one thing to carry forward from G0

The Dart source that produced the supported cell is **`7b04b01b`** — a tree
object, not a commit. `dart_revision: 9e8c898a` names a commit that is missing
15 lines which are demonstrably compiled into the shipped `dart2bytecode.aot`,
and that commit is on no remote anywhere. Build from the bank in
[`runtime_feasibility/g0_freeze/banked_source/`](runtime_feasibility/g0_freeze/banked_source),
and see [`FREEZE.md`](runtime_feasibility/g0_freeze/FREEZE.md).
