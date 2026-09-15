# MAOT-5 (#69) — stage 1: the descriptor-backed cell

Dart fork `358a0ee8275f69d7f0f778d55c9869ebb7a59e86`, parent
`b92efd823d83`. No trampoline yet, and no behaviour change: the #67 call
site still loads `cell[kCellImplFunction]` and branches through that
Function's entry point exactly as before.

## What changed

The dispatch cell is now the descriptor the ruling specified:

```text
DeclarationId
  -> declaration Function
  -> mutable cell { implementation Function, executable Code }
```

Release state is unchanged in meaning — `cell.impl_function` is the
declaration Function and `cell.impl_code` is its release-body `Code`. Both
halves are written together at registration and at installation, and nowhere
else.

This is #66's own distinction rather than a new one. #66 already proved a
`Function` is not an executable implementation and pins `Code` separately;
#69 moves that second half into the **cell**, where dispatch can reach it.

## One defect avoided by prior art

The cell's `Code` half is captured at registration, so it is pre-dedup for
exactly the same reason `kCurrentCode` and `kReleaseCode` are, and fails the
same way — two `Code` objects with identical `Instructions` reachable, which
the serializer refuses outright (`RELEASE_ASSERT(!FLAG_precompiled_mode)`).

#67 reintroduced that defect through `kReleaseCode` after #66 had fixed it
for `kCurrentCode`. `RepinCurrentCode` now covers the cell too, so a third
pinned `Code` did not become a third instance of one mistake.

Introspection reports `dispatch_cell_length`, `dispatch_cell_has_code` and
`dispatch_cell_halves_agree`, so a divergence between the halves is readable
rather than deduced.

## Regressions

All three accepted lanes re-run against `358a0ee8`, and the scale record
regenerated at that commit:

| lane | arms | conditions | verdict |
|---|---|---|---|
| m2 (#66) | 23, 0 failed | 24, 0 failed | `runtime_implementation_registry = ESTABLISHED` |
| m3 (#67) | 15, 0 failed | 18, 0 failed | `issue_67_closure = READY` |
| m4 (#68) | 18, 0 failed | 23, 0 failed | `arm64_aot_optimizer_invariants = ESTABLISHED`, `issue_68_closure = READY` |

Obligation 6 holds for stage 1.

The provenance guard built for #68 did its job during this stage: it refused
to write a build digest while the worktree differed from HEAD, which forced
the change to be committed before it could be measured.

## Stage 2 is designed but blocked on an ordering conflict

Every mechanism is identified — `compiler::Assembler` against the
precompiler's global pool, `Code::FinalizeCode`, `set_owner(declaration
Function)` for obligation 5, and `MonomorphicCheckedEntryAOT()` for
obligation 1, which is what makes `entry_point_ != monomorphic_entry_point_`
and so satisfies `DoUnlinkedCallAOT`'s assert.

The trampoline body, branching through the **Code** half so there is no
self-cycle:

```cpp
__ MonomorphicCheckedEntryAOT();              // cid check; falls through
__ LoadUniqueObject(IP0, cell);               // the Array(2)
__ LoadCompressed(CODE_REG,
      FieldAddress(IP0, Array::element_offset(kCellImplCode)));
__ ldr(IP0, FieldAddress(CODE_REG, Code::entry_point_offset()));
__ br(IP0);
```

`CODE_REG` is set to the implementation `Code` before the branch, which is
the obligation-2 question and is not yet measured.

### Obligation 4 names an empty window

The ruling requires trampoline installation "after #66's post-dedup repin but
before dispatch consumers freeze targets". In the actual pipeline those are
the wrong way round:

```text
751  MaterializeMutableAotRegistry()
753  FinalizeDispatchTable()            <-- dispatch table freezes CurrentCode
812  ProgramVisitor::Dedup(T)
828  RepinMutableAotImplementations()   <-- the post-dedup repin
```

`FinalizeDispatchTable` calls `dispatch_table_generator_->BuildCodeArray()`
at line 753, **75 lines and one whole phase before** the repin at 828. So:

* install before 753 and the table captures the trampoline, but the
  trampoline's `Code` is then pre-dedup — and unlike the cell, a dispatch
  table entry is already baked into an `Array` by the time the repin runs;
* install after 828 and the table has already frozen the **release body**,
  so virtual dispatch bypasses the cell entirely and the mechanism does
  nothing.

There is no point satisfying both halves as written.

**Proposed resolution, not adopted without a ruling:** install before
`FinalizeDispatchTable`, and prove the trampoline is *dedup-stable* rather
than assume it. Each trampoline references its own cell through a distinct
global-pool index, so no two trampolines share instruction bytes and
`ProgramVisitor::Dedup` has nothing to merge them with — but that is an
argument, and obligation 6 requires it be measured. The check would be:
after dedup, every mutable declaration's `CurrentCode` is still the
trampoline, and the dispatch table entry for it still points there.

Nothing in stage 2 is built. Stage 1 stands on its own and is green.
