# MAOT-5 (#69) — locating the super divergence: instrumentation blocked

## Metric reframed, as directed

`indirect_call_sites_emitted` is no longer read as proof that a call site is
cell-routed. It counts **lowering attempted**, not the final executable
route — the super result is exactly a case where the two differ:

```text
Base.v  static_cell_lowering_attempted = 1
        runtime behaviour              = cell change NOT observed
```

This does not reopen #67. That result covers **top-level and static**
declarations; `Base.v` is an instance member reached by `super`, outside the
proven subject set. What the super case shows is that *sharing a lowering
path is not enough to inherit the proof*.

## Paired control built

`fixture_m5_super.dart` now contains both subjects in one program:

| | subject | call form |
|---|---|---|
| control | `control()` — top-level, `maot:mutable` | `callControl()`, static call |
| test | `Base.v` — instance, `maot:mutable` | `sub.viaSuper()`, super call |

Both are swapped at the same point in the same run, so any difference is
attributable to the call form rather than to timing or fixture shape.

## The divergence is NOT yet located — instrumentation blocked

A dump of each caller's **final** instruction words, placed after every
static-call rewrite, crashed `gen_snapshot` twice:

1. iterating `functions_to_retain_` directly — SEGV;
2. `ProgramVisitor::WalkProgram` at the end of `DoCompileAll` — SEGV at the
   same address, 0 callers dumped.

Both are placement faults in my diagnostic, not results. The end of
`DoCompileAll` is after `DropFunctions` and `PruneDictionaries`, so the
program is no longer walkable the way the dump assumed. The correct window is
**after `ReplaceFunctionStaticCallEntries` and before the drop phase**, and
the dump has not been moved there yet.

The flag defaults to off, so nothing else is affected.

## What is established, and what is not

**Established.**

* super resolves the correct declaration — `super.v()` gives `OLD-BASE`
  while a virtual call on the same receiver gives `SUB-OVERRIDE`;
* super enters no switchable-call state;
* the trampoline is not implicated: identical `OLD-BASE` throughout with
  trampolines on (`tramp=1`) and off (`tramp=0`);
* a cell indirection was *attempted* for the super site.

**Not established.**

* which pass, if any, rewrites the super call site away from the cell;
* whether the control's call site keeps the cell route through the same
  passes — the paired comparison has not produced data yet;
* therefore whether `BindStaticCalls` / `ReplaceFunctionStaticCallEntries`
  are responsible at all. That hypothesis remains **untested**, not
  supported.

## Unchanged

```text
super/unproven  =  UNMODELED_BLOCKING
```

No fix attempted, no special-casing of super, no second trampoline path, no
#68 disposition altered, no #64 cell moved. `MonomorphicSmiableCall` remains
pending rather than abandoned.
