# MAOT-5 (#69) — super: the #67-coverage hypothesis is REFUTED

## Result

`super.v()` does **not** observe a cell change. The standing hypothesis —
that it lowers through the static mechanism #67 already established, and so
needs no #69 work — is **not confirmed by measurement**. It is contradicted.

```text
Base.v static_call_sites = 1        <- #67 lowering DID emit a cell indirection
tramp.identity = 1

super.0        = OLD-BASE
virtual.onSub  = SUB-OVERRIDE       <- super correctly selects Base.v, not the override
super.warm     = OLD-BASE           (50,000 iterations)

swap.1 = 0  ->  super.1 = OLD-BASE
swap.2 = 0  ->  super.2 = OLD-BASE
swap.3 = 0  ->  super.3 = OLD-BASE

super.noSwitchableTransition = true
```

Every swap reported success (`0`). The call keeps executing the release body.

## The trampoline is not implicated

| configuration | trampoline | super.0 → super.1 → super.2 |
|---|---|---|
| `--maot_install_trampolines` | 1 | `OLD-BASE` → `OLD-BASE` → `OLD-BASE` |
| without | 0 | `OLD-BASE` → `OLD-BASE` → `OLD-BASE` |

Identical. This is not a #69 trampoline defect; the super call site does not
reach the cell in either configuration.

## What is and is not established

**Established.** Super resolves the correct declaration: `super.v()` returns
`OLD-BASE` while a virtual call on the same receiver returns `SUB-OVERRIDE`.
Semantics are right. It also enters no switchable-call state, consistent with
being a static form.

**Refuted.** That being a static form is sufficient for #67's mutable-cell
path to carry it. `Base.v` is reached *only* through `super.v()` in this
fixture, so the one recorded static call site can only be the super call —
and yet the swap is invisible to it.

**Unexplained.** Why a call site counted as cell-lowered at emission does not
load the cell at run time. Candidates, none tested:

* a later pass rewrites the static call to a PC-relative direct branch
  (`BindStaticCalls` / `ReplaceFunctionStaticCallEntries` both rewrite static
  call targets after emission);
* `super` reaches code generation through an emission path other than
  `GenerateStaticDartCall`, and the recorded count came from somewhere else;
* the callee body was reached by a route that never consults the cell.

Distinguishing these is the next step, and it is a measurement, not a design
change.

## Consequence

```text
super/unproven   stays UNMODELED_BLOCKING
```

No `super/static-cell` record is proposed, and **no #69-specific super
mechanism was built** — the ruling's instruction to measure rather than
extend is what produced this result. `Alpha.v` and `Base.v` both remain
`installable: false`.

The difference between this and #67's accepted evidence matters: #67 proved
replacement through static calls to **top-level and static** declarations.
This is an **instance** declaration reached by `super`, and that case does not
inherit the result.
