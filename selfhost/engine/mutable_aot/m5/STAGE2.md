# MAOT-5 (#69) — stage 2: trampoline prototype, INCOMPLETE

**Status: the prototype does not work yet.** `gen_snapshot` reaches
serialization and segfaults. Nothing here is a working mechanism and no
#69 cell moves.

Dart fork `df7d2f0693e`, seven commits on `b92efd823d83`. Stage 1
(`358a0ee8275`) is accepted and unaffected — everything below is on top of it.

## What works

```text
[maot] materialized 13 of 13 selected (0 dropped)
[maot] installed 13 dispatch trampolines (0 skipped)
[maot] re-pinned 0 of 13 descriptors after dedup
```

* trampolines are generated and installed for every selected declaration;
* the approved ordering holds — install between
  `MaterializeMutableAotRegistry` and `FinalizeDispatchTable`;
* the repin fix the ruling required is in and demonstrably active: **0 of 13**
  re-pinned, because `RepinCurrentCode` now returns early for any entry
  carrying a trampoline rather than rederiving a body pin from
  `implFunction.CurrentCode()` — which would have returned the trampoline and
  pointed the cell's Code half at itself;
* registry pins are canonicalized inside `ProgramVisitor::Dedup`, by lookup;
* compilation, dedup and the static-call fixer all complete.

## Four defects found and fixed, each real

1. **Compiler headers in a runtime translation unit.** `maot_registry.cc` is
   compiled into the AOT *runtime* as well as the precompiler, and the
   runtime may not include compiler sources. The generator moved to
   `precompiler.cc`, which is precompiler-only by construction.
2. **`constant_pool_allowed()` is false on a fresh `Assembler`**, so
   `LoadUniqueObject` failed `CanLoadFromObjectPool` and gen_snapshot aborted
   at `assembler_arm64.cc:667`.
3. **`TMP` is the macro-assembler's own scratch.** Parking the cell pointer
   there across `LoadUniqueObject`/`LoadCompressed` clobbered it, and the
   trampoline branched to a tagged pointer — a bus error at an odd address,
   nowhere near the emission. `CODE_REG` is now both scratch and destination.
4. **A `Function` owner puts the Code on the function-code paths.**
   Obligation 5 requires `Code::owner()` be the declaration Function, because
   `DoSingleTargetMissAOT` recovers the target through it. That same choice
   makes `IsFunctionCode()` true, so `ReplaceFunctionStaticCallEntries` walks
   `static_calls_target_table()` — which stubs never need, because their owner
   is a Class. It now carries an empty table.

Also: `Canonicalize()` falls through to `Dedup()`, which **inserts**. A
mutable declaration's body Code is reachable only from the registry once the
Function carries the trampoline, so it is never in the walk; inserting grew
`canonical_objects_` and tripped
`RELEASE_ASSERT(canonical_count == canonical_objects_.Length())`. The hook is
lookup-only now — a pin absent from the map was never merged, so it is
already canonical.

## Where it fails

```text
si_signo=Segmentation fault: 11(11), si_code=SEGV_ACCERR(2),
si_addr=0x4d50003f1b9
frame #0: dart::Serializer::Serialize(dart::SerializationRoots*) + 11028
```

Reproducible, same address every run. The odd address means a tagged pointer
is being dereferenced as untagged.

Adding `pc_descriptors` and `compressed_stackmaps` did **not** change it, so
the hypothesis that function-code serialization wanted those is wrong and is
recorded as such.

### Next hypotheses, untested

* `Code::FinalizeCode(..., kNotAttachPool, ...)` leaves `object_pool()` null.
  Stubs tolerate that because they serialize in a different cluster; a
  Function-owned Code may not.
* The trampoline is reachable from `Function::CurrentCode()` **and** from a
  dispatch-table entry **and** from `kTrampolineCode`. One of those paths may
  reach it before its cluster is assigned.
* A one-build discriminator: give the trampoline a **Class** owner
  temporarily. If serialization then succeeds, the failure is specific to the
  function-code path and obligation 5 conflicts with serialization — which
  would be a finding about the design, not a bug to patch.

That discriminator is the cheapest next step and is what I would run first.

## Not claimed

* No dispatch form is proven. No #64 cell moves.
* The trampoline has never executed. Obligations 1, 2, 3 and 6 are untested;
  only 4 (ordering) and 5 (owner) are implemented, and 5 is implicated in the
  current failure.
* #66/#67/#68 regressions have not been re-run against stage 2 — there is no
  snapshot to run them against.
