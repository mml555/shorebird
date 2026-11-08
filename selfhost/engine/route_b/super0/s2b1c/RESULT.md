# D-SUPER-2B.1c — PARTIAL. Producer emits; end-to-end harness not yet green.

Host only. Throwaway compiler artifacts, restored or discarded; no cell
published, no pin moved, no device.

## Done, with evidence

### 1. `memberKind` is now load-bearing in the compiler

The mandatory fix before wiring. `0015` takes **seven** arguments and resolves the
origin member on **name AND kind**, with no first-member-with-that-name fallback:

    for (final p in cls.procedures) {
      if (p.name.text == originMemberName && p.kind.name == originMemberKind) {

Identity arm added to `s2b1/run_2b1.sh` (`KIND=Getter`):

    WRONG memberKind -> REFUSED
      "no Getter named original in LifeState in the import kernel"

So the field v10 carries is consumed by the safety-critical consumer rather than
ignored. The wire value is Kernel's `ProcedureKind.name` and therefore
capitalised — `Method`, `Getter` — consumed exactly as spelled, and the doc
comment in `route_b_coverage.dart` corrected to say so.

`s2b1/run_2b1.sh` still passes all four arms: mixin lifecycle → `TICKER`, deep
hierarchy → `DEEP-BASE`, super-with-arguments → REFUSED, wrong kind → REFUSED.

### 2. The producer emits the intrinsic

`_lower` now admits super sites from the SOURCE and rewrites each call:

    super.close()
      -> $routeBSuper(self, 'package:…/target.dart', 'LifeState', 'target',
                      'Method', 1886, 'close') as dynamic

with the intrinsic's declaration emitted **before** the entry-point pragma, since
only one declaration may carry that pragma. Six unit tests
(`route_b_producer_test.dart`, 70 passing overall) assert:

* a zero-argument call is rewritten, `super.` does not survive, and the emitted
  source carries the pragma and the full site identity **including `Method`** —
  the observable is the emitted source, not the producer reporting success;
* no intrinsic declaration is emitted when no super site is reported;
* arguments → refuse; unverifiable source → refuse, with its own message;
* a `getter`/`setter` site kind → refuse;
* a missing `origin` → refuse.

All-or-nothing per target: a method with two super calls where one is
unsupportable refuses entirely.

### 3. A throwaway cell, and why one is needed

`resolveRouteBCompiler` verifies every artifact's SHA-256 against
`PROVENANCE.txt`, so the shipping producer cannot be driven on the host with a
file swapped in. `mint_throwaway_cell.sh` rebuilds the bundle with updated
hashes and a THROWAWAY banner, leaving the `engine revision` line untouched.

**A cell is a coherent set, not a bag of files.** The first attempt replaced only
`dart2bytecode.aot` and the producer died on *"the coverage analyzer speaks
version 9, and this build understands 10"* — the bundle still carried the v9
analyzer. Both artifacts this lane changed now travel together, and the cell is
verified to work end-to-end on an unrelated specimen (the D-HYGIENE `K` case
produced a container and executed correctly through it).

## NOT done — the end-to-end harness does not pass

`s2b1c/run_2b1c.sh` is in-tree and marked WIP. Its plumbing is right; its
specimen is not.

The base and patched kernels differ in **four** members rather than one:

    LifeBase._quiet   LifeState.close   LifeState.target   main

Only `target`'s source changed. The other three drift because TFA specialises
the super targets differently on the two sides, and the producer then fails
compiling one of them — `LifeBase._quiet: the bytecode compiler refused its
replacement body (exit 254)`.

Two specimen fixes already went in and were not enough:

* holding the super targets alive from a separate `keepAlive` made TFA treat them
  as reachable-only-from-a-dead-branch on one side and called-from-`target` on
  the other → three changed members;
* reaching them from `target`'s own dead branch on both sides → still four.

Building a specimen where only the target's body differs under `--aot --tfa` is
the remaining work. This is the same family of problem that has now bitten five
times in this programme, and it is worth naming as a standing rule:

> **A two-kernel specimen must make the two kernels differ in exactly the way
> the test claims.** TFA decides what to specialise from whole-program
> reachability, so any asymmetry in how a member is reached — not just in its
> source — shows up as a changed member.

Also not done, and therefore **the closure gate is NOT met**:

* the cross-gate mutation (`MUTATE_SOURCE_GATE=1`) is implemented in the harness
  but unrun, because it needs the positive arm to work first;
* stateful positive execution through the shipping producer;
* the required matrix rows (plain parent, deep hierarchy, mixin lifecycle,
  private super, multiple sites in one method) are only covered by the
  harness-authored arms in `s2b1/`, not by the producer path.

## Regression

    route_b_producer_test.dart     70 passed (6 new super cases)
    route_b_super_source_test.dart  6 passed
    s2b1/run_2b1.sh                4/4 arms
