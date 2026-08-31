# Part 2B — the shipping path works; one mutation is blocked by an earlier gate.

Host only. `RouteBCoverageAnalyzer` + `RouteBProducer` — the code
`shorebird patch` runs — against a throwaway cell carrying analyzer v11 and
0017. The replacement source is written by the PRODUCER, not by the harness.

**How the invocation is observed.** The producer runs the compiler internally, so
rather than scraping a log this relies on a behavioural fact: 0017 refuses
outright without `--patched-verification-dill`. A successful super compile
through the real producer therefore proves both kernels reached the command
line.

## Positive arm — PASS

    PREFLIGHT  changed [Leaf.target]   added []   removed []
    analysis   v11, site offset 1005, target [672, close, Method]
               release evidence [[672, close, Method]]
    producer   ACCEPTED, emitted the pragma intrinsic, no `super.` survives
    execute    unpatched TICKER:APP-STATE
               virtual   LEAF:APP-STATE
               patched   WRAP:TICKER:APP-STATE

The moved-site property is exercised throughout: the release's site is at 988,
the patch's at 1005, and the target provenance is identical.

Incidentally established: `attachBytecodeToFunction` accepts a dotted
`Leaf.target` selector, so the host harness can attach to an instance method.

## Mutation A — PASS. The independence claim is restored.

Producer's source-argument gate broken, on a specimen whose release already
super-called the same target with arguments:

    producer   admits (incorrectly)
    compiler   REFUSED — "super.tag takes arguments (2 positional, 0 named,
               0 type)"

Read from the PATCHED no-AOT body. This is the result 2B.1c-SITE invalidated and
it now holds: the two gates read the same body, and the second one catches what
the first missed.

**The first version of this mutation did not reach the compiler.** Forcing only
`routeBSuperCallArgs` left `routeBSuperCallSpan` reading correctly, so the span
came back null and the producer refused with *"not inside the declaration being
replaced"* — a different gate, a different reason. Mutating the shared reader so
the producer both admits AND hands over a valid span is what a real bug would do.

## Mutation B — NOT DEMONSTRABLE through the product path

Bypassing only `releaseSuperTargets` membership on the introduced-mixin case does
**not** reach the release abort, because the patch never gets that far:

    changed  [Leaf.target, _Leaf&Base&Ticker.close]
    verdict  reject
    reason   _Leaf&Base&Ticker.close — unreachable, "abstract; call sites
             dispatch to implementations"

**Introducing a super call onto a clone the release never reached also CHANGES
that clone**, and the coverage verdict rejects the whole patch on it before the
producer's evidence gate is consulted.

So for this shape the release-evidence gate is **defence in depth, not the first
barrier**. That is worth knowing precisely, and it is not the same as the gate
being unnecessary:

* the abort it prevents is real and was measured at harness level in
  `s2b1f/` (membership bypassed → `compiler.cc:1152`);
* it still fires first for any shape where coverage accepts but the release
  method direct-called nothing — which the producer unit tests cover;
* the arm-D shape (ordinary superclass, introduced site) is admitted by coverage
  and would EXECUTE correctly, so it exercises the deliberate false negative
  rather than an abort.

I did not contrive a specimen to force the abort through the product path. The
honest statement is that the shape which aborts is caught earlier, and which gate
fires is now recorded rather than assumed.

## Not done — the real `shorebird patch ios` controls

Controls A/B/C through an actual patch command still require the release rig
(a real release on the control plane, an iOS build, the device path). Everything
above is the producer/compiler path exercised directly. That gap is unchanged
from what Part 2A recorded.

## Fixture repair, and two harness faults it caught

The TFA-symmetric fixture is the c1 shape — release `target() => super.close();`,
patch wrapping the same call — split into a patchable library and a harness
library. Both faults were caught by the preflight or by a gate, not by
inspection:

* **retention asymmetry.** Building the base with `--dynamic-interface` and the
  patched kernel without it reported `Base.close`, `Ticker.close` and the mixin
  clone as REMOVED. Both kernels now carry the same retention.
* **the wrong source on disk.** The harness restored the RELEASE text after
  building the patched kernels, so the producer's source gate read offset 1005 of
  the wrong file and refused as *"could not be verified"* — the gate behaving
  correctly on a harness mistake. At patch time the tree holds the patched source.
* and one specimen fault: the original fixture imported `dart:_internal` for the
  attach harness, which the replacement inherited — *"Can't access platform
  private library"*. A real app would not import it either.

## Reproduce

    CELL_ZIP=<v11+0017 cell> WORK=/tmp/p bash super0/s2b2/run_2b2.sh
    MUTATE=source_gate REL=…/argtarget_release.dart PAT=…/argtarget_patch.dart …
