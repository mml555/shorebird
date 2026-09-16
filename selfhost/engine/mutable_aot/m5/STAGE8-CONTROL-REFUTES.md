# MAOT-5 (#69) — the paired control refutes the super framing

## Correction

I previously reported that `super.v()` does not observe a cell change, and
framed that as a property of the **super call form**. That framing was not
established: the run had no paired control.

With the control in the same program, both fail identically:

```text
CONTROL  top-level static      control.0 = OLD-CONTROL  swap=0  control.1 = OLD-CONTROL
SUPER    instance via super    super.0   = OLD-BASE     swap=0  super.1   = OLD-BASE
```

The control is a **top-level `maot:mutable` function called statically** —
exactly the subject #67's accepted evidence covers. It does not observe the
diagnostic swap either. **Super is not implicated.**

This is why the ruling made the paired control load-bearing, and it was
right to: without it I had attributed a general failure to one call form.

## Gate B: the compiler-rewrite hypothesis is refuted

Both callers are byte-identical at all three stages — before
`ReplaceFunctionStaticCallEntries`, after it, and after `Dedup` (which is
where `BindStaticCalls` actually runs, `program_visitor.cc:1446`).

Both retain the cell load and the indirect call:

| caller | pool load | call |
|---|---|---|
| CONTROL | `ldr x0,[x27,#152]` | `blr x30` |
| SUPER | `ldr x0,[x27,#104]` | `blr x30` |

And both load the **correct** cell. The seeded indices match the emitted
offsets exactly:

| declaration | seeded index | PP offset | emitted |
|---|---|---|---|
| `Base.v` | 11 | 104 | `ldr x0,[x27,#104]` |
| `control` | 17 | 152 | `ldr x0,[x27,#152]` |

No pass rewrote either site. The defect is **below the static-binding
passes**, and it is not super-specific.

## What this leaves

The failing thing is common to both: a **#67-style static call site**, in a
build with `--maot_install_trampolines`, does not observe a diagnostic cell
swap — even though the site provably loads the right cell.

Note what is different from the paths that DO work. The working evidence —
m3/#67, and the m5 dynamic/interface results — either ran **without**
trampolines, or reached the body through the trampoline (`cell[implCode]`).
This path reads `cell[implFunction]` and calls that Function's entry point.
With trampolines installed, that entry point is the *replacement's own
trampoline*, which then indirects through the *replacement's own* cell.

That two-hop chain is the obvious suspect and is **untested**. I am not
asserting it.

## Not claimed

* No conclusion about super as a call form. It may still be fine.
* No claim that #67's accepted result is affected: m3 is green, and it runs
  without trampolines.
* `super/unproven` stays `UNMODELED_BLOCKING`, unchanged.
* No disposition touched, no fix attempted, no #64 cell moved.
