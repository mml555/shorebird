# D-SUPER-2B.1g — CLOSED. Host certification for zero-argument `super.method()`.

## The claim

> **HOST CERTIFIED:** Route B supports zero-source-argument `super.method()` when
> the release version of the same method already exact-called the same semantic
> target. The patched call is independently verified against an unspecialized
> kernel of the patched source, while emitted replacement bytecode remains bound
> to the shipped release kernel. Target provenance must agree across analyzer,
> patched verifier, and release binder. New exact-super dependencies refuse
> fail-closed under the narrow-v1 evidence policy.

> **This is compiler/producer host certification only.** It does not certify
> `shorebird patch ios`, control-plane release resolution, installation, device
> activation, or a publishable compiler cell.

**No shipped release can use it.** The producer requires a cell implementing
`routeBDirectSuperDualKernelV1`, and none is published.

## What the lane established

    TFA-isolated changed member                    PASS   s2b2
    moved site, identical target provenance        PASS   s2b1f, s2b2
    stateful exact-super execution                 PASS   s2b2
    patched-body independent backstop              PASS   s2b2 mutation A
    unsafe introduced-mixin case refused earlier   PASS   s2b2
    narrow-v1 release evidence rule                PASS   s2b1f
    dual-kernel compiler (0017)                    PASS   s2b1g
    cell capability, earned                        PASS   qualify_dual_kernel_cell.sh
    A / B / C against real cells                   PASS   s2b2

## The STOPs that shaped it, in order

Each was a measured refutation of a design that looked correct:

    2B.1c-SITE   a patched source offset is not an identity in the release body.
                 A byte-aligned specimen made the compiler accept a patch whose
                 argument list it never saw: BASE:NONE:APP where the author
                 wrote BASE:x:APP. Silent, no diagnostic.
    2A           a target's canonical owner is renamed by AOT mixin
                 deduplication; 8 of 44 Wonderous super sites disagree.
    2B.0         TFA erases a super call's arguments from the AOT kernel, so an
                 admission gate reading it would accept super.tag('a', 7).
    2B.1e        retention is not compilation. A retained mixin clone with no
                 AOT code aborts the app at compiler.cc:1152.

None of these were visible in the shape the lane started with; each came from
building the control that could fail.

## What the design deliberately gives up

* An ordinary superclass target the release never super-called **would** work
  (`s2b1d` arm D) and is refused anyway. The gate carries evidence, not
  inferences from class shape.
* Whether a patch may introduce arbitrary new exact-super dependencies is
  `D-SUPER-BROAD-0`, parked, with E2 NOT ESTABLISHED rather than negative.

## Handover to D-SUPER-2C

The real `shorebird patch ios` A/B/C controls move to 2C, where their
prerequisites — a resolvable candidate cell and a candidate CLI — are the task
rather than an obstacle. Requiring a release-resolvable 0017 cell to close the
lane that decides whether 0017 deserves one was circular.

`0015` and `0016` remain UNSOUND / superseded and not promotable. The certified
runtime `619fdad176ff4573…` and the published cell
`4792f0eca461f3761001a1adbe131b4b115e3684` are untouched throughout.
