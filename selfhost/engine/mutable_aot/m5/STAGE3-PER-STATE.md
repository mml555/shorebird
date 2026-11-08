# MAOT-5 (#69) — per-state OLD → NEW → NEW2 with no cache mutation

## The instrument

A cached dispatch target that a replacement invalidated would **miss again**,
and a miss records another observation. So a cell swap that changes what the
call returns **without** increasing that state's observation count proves the
cached target was never touched and the state resolved through the cell.

Counters are O(1) and unconditional; decision *records* are capped at 8 per
state. The first version appended a record at every miss, and a warm loop
alternating receiver classes misses on most iterations — the decisions array
grew without bound and the run had to be killed at 900 s. The instrument was
destroying what it measured.

## Result — one warmed call site per state

| state | OLD | NEW | NEW2 | counts | no cache mutation |
|---|---|---|---|---|---|
| UnlinkedCall → linked | `NEW-ALPHA` | `NEW2-ALPHA` | `NEW-ALPHA` | **9/9/9/9** | **true** |
| monomorphic | `NEW-ALPHA` | `NEW2-ALPHA` | `NEW-ALPHA` | **1/1/1/1** | **true** |

Three successive swaps, each observed through the **same** warmed site, with
the state's observation count unchanged across all three. `beta.v = BETA`
throughout.

Convergence was separately established: every `-observed` record for these
states is `SLOT_PRESERVING`, which is emitted only when the state's stored
executable target equals the registry trampoline.

## Two instrument defects found and corrected

**Reading through fresh call sites.** The first version called `site.v()`
three times inside a helper — three *distinct* call sites, each starting
Unlinked and missing once. The count rose `8/9/10/11` and
`noCacheMutation` reported **false** for a reason that had nothing to do with
cache mutation. Corrected to a single `_oneSite()` helper, warmed before the
first swap, so all three reads traverse one site.

**Swapping a cell to a trampolined declaration.** The helper began with an
identity swap `Alpha → Alpha` to establish a baseline. `Alpha`'s
`CurrentCode` *is* its trampoline, so this set `cell.implCode = trampoline`
and the trampoline branched to itself — the process hung. That is the exact
self-cycle the two-half cell was designed to avoid, and the ruling had
already warned against using a replacement's trampoline as the target.

It is also incidental confirmation that `trampoline → cell → implCode` is the
live path: pointing the cell at the trampoline is what hangs it.

## Not proven

* `MonomorphicSmiableCall`, `SingleTargetCache`, `MegamorphicCache` were
  never reached. Not observed is not disproven.
* These states were exercised through the **dynamic** call form. The
  interface form never enters this machinery at all — it compiles to
  `DispatchTableCallInstr`, a direct indexed branch with no miss handler.
  `interface`, `super` and `dynamic` remain separate axes.
* No #64 cell moves. Nothing installs through `StageReplacement`;
  `Alpha.v` remains `installable: false` with six blocking escapes.
