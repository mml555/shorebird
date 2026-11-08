<!-- cspell:words MAOT precompiler dartaotruntime devirtualization tearoff -->

# MAOT-4 (#68) — what this issue may claim against #64

Written before any optimizer change, per the #68 authorization: *map the
intended proof to the exact #64 rows/cells, and do not promote a whole row
unless every mode it requires is proven.*

## The vocabulary, as #64 actually defines it

`t0/lib/schema.py`:

| axis | values |
|---|---|
| `DISPATCH_MODES` | `direct`, `virtual`, `interface`, `super`, `dynamic`, `tearoff_pre`, `tearoff_post` |
| `OPTIMIZER_MODES` | `jit` — *"unoptimized/interpreted-ish; the control"* · `aot` — *"AOT snapshot: inlining, TFA, devirtualization all on"* |
| `HEAT_MODES` | `cold` (1 invocation) · `hot` (20,000 invocations) |

## Finding 1 — there is no "#64 optimization-stress row"

#68's last acceptance item reads:

> #64 optimization-stress rows for direct/static body replacement are `PROVEN`.

No such row exists. Searching all 104 corpus rows for optimization vocabulary
returns exactly two, and neither is what the item describes:

| row | title | declared modes |
|---|---|---|
| `EB-25` | tear-off obtained before installation | none — scaffolded |
| `RS-09` | inline caches and dispatch specialization state | none — scaffolded |

The optimization stress #68 is about is not a row. It is the **`aot` cell of
the `optimizer` axis** on the ordinary body-replacement rows — `aot` is
defined as *"inlining, TFA, devirtualization all on"* — taken together with
`heat=hot`, which runs 20,000 invocations and is where specialization
actually happens.

So the item maps to **cells of EB-01 and EB-02**, not to rows of their own.
This is the same shape of mis-specification that #67's acceptance item had,
and it is surfaced for the same reason.

## Finding 2 — the `jit` cell is a compiler gap, not a test to run

#68's required test 10 is:

> optimized and non-optimized builds produce identical mutation semantics

That maps exactly onto #64's `optimizer: jit | aot` axis, so #64 already
models it. But it cannot be satisfied by running the existing fixture a
second way.

The #67 mechanism emits the dispatch-cell indirection in
`FlowGraphCompiler::GenerateStaticDartCall`, guarded by
`FLAG_precompiled_mode`. Kernel loading registers declarations in both modes
(`kernel_loader.cc` is not AOT-only), so in JIT the **descriptors would
exist and be installable while no call site traverses the cell** — the exact
false-safe shape #67's `G01`/`G11` arms exist to catch, except structural.

Proving the `jit` cell therefore requires a JIT lowering. That is a scope
decision, not an implementation detail, and it is stated here rather than
taken.

## What #68 can claim without either question resolved

| row | cell | before #68 | after #68 |
|---|---|---|---|
| EB-01 | `direct` × `aot` × `cold`+`hot` | linked by #67 | linked, **hardened** |
| EB-02 | `direct` × `aot` × `cold`+`hot` | linked by #67 | linked, **hardened** |

"Hardened" is the honest word. #67 showed the conservative posture *happens
to hold* for its fixture. #68 makes it an enforced, per-pass rule with a
falsification for each optimization class, and adds the adversarial variants
#68 names — always-inline candidate, constant-return callee, callee
unreachable at release, several mutable callees in one caller, nested
A → B → C chains, two successive replacements.

**#68 adds no new #64 cell.** It raises the confidence of a cell #67 already
linked. Whole-row `PROVEN` for EB-01/EB-02 remains impossible here: they also
require `tearoff_pre`, `tearoff_post` and `dynamic`, which #69 and #70 own.

`RS-09` stays `UNMODELED`. Giving it modes is a #64 corpus change, and #64 is
closed.

## The governing rule this lane enforces

> A mutable declaration may be optimized only if every resulting executable
> path still selects the current #66 implementation, or the optimization
> carries machine-consumed invalidation/dependency state that makes that
> guarantee true.

With the corollary that decides what counts as evidence:

> No `NOT_INLINED` log, optimizer annotation, dependency record or compiler
> statistic counts unless a real correctness or install decision consumes it.

## Open questions, stated rather than assumed

1. **Is `jit` in scope for this program at all?** Flutter release builds are
   AOT; #64 calls `jit` "the control". If it is out of scope, EB-01/EB-02 can
   never reach whole-row `PROVEN` and #64's rows are over-specified for a
   Mutable-**AOT** program. If it is in scope, #68 needs a JIT lowering and
   is a materially larger issue.
2. **Should `RS-09` be given modes and brought into #68?** It is the row that
   names inline caches and dispatch specialization, and #68 is the issue that
   constrains them — but it is scaffolded, and #64 is closed.

Phase A proceeds on the `aot` cell, which neither question affects.
