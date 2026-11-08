<!-- cspell:words dartaotruntime dill semantic linker dynmod -->
# SL1-G3 — patch classes in Dart's type system and its collected heap

**Gate:** [#40](https://github.com/mml555/shorebird/issues/40) · **Tracker:** [#36](https://github.com/mml555/shorebird/issues/36)
**Run:** 2026-09-06 · **Verdict: PASS. No fatal substrate defect. 10/10 on the subject arm, 10/10 control.**

Transcripts: [`evidence/g3_g3_on.txt`](evidence/g3_g3_on.txt),
[`evidence/g3_g3_off.txt`](evidence/g3_g3_off.txt).
GC instrument: [`banked_experiment/`](banked_experiment).

## The GC trigger is falsified before it is used as evidence

Run first, and — deliberately — **above the oracle gate**, because it measures
ordinary AOT objects and the collector, neither of which depends on dynamic
modules. So it runs on **both** arms, and behaving identically with the flag off
is itself evidence the instrument is not entangled with the substrate:

    weakly reachable ordinary AOT object -> collectAllGarbageForTesting() -> CLEARED
    strongly rooted ordinary AOT object  -> collectAllGarbageForTesting() -> SURVIVED
                                         -> and is still the object the holder names
    identical result on the OFF arm

Without the second line a no-op trigger would have made every survival test
below pass while collecting nothing.

The instrument is a **wrapper, not a collector**: `collectAllGarbageForTesting()`
calls the existing `VMInternalsForTesting.collectAllGarbage`, which is
`heap()->CollectAllGarbage(GCReason::kDebugging, compact: true)` — the same path
ordinary objects already take. Dynamic-module objects get no special handling.
The banked patch adds 12 lines and touches only the two SDK files; it was
verified to forward-apply to the pre-G3 tree and reverse off the live one, and
to contain no part of G2's instrument.

## GC across the mixed graph

    1. AOT ROOT -> PATCH OBJECT
       rooted by:        aotHolder.ref, an AOT object's field, and nothing else
       survived full GC: yes
       same identity:    yes (weak observation identical to the field)
       method dispatch:  yes, 'PATCH-IFACE'
       still bytecode:   PatchIface.tag -> INTERPRETED after the collection
       state readable:   yes
       => the collector discovered the patch object through an AOT field

    2. PATCH ROOT -> AOT OBJECT
       rooted by:        a patch object's field, and nothing else
       host reference:   taken inside a never-inline helper whose frame is gone
                         before collect() runs, so no live slot of ours roots it
       survived full GC: yes
       checked FROM bytecode: the module's installed closure returns the SAME
                         AOT object after the collection
       state preserved:  42
       AOT call usable:  yes
       => patch-object scanning traces references back into the normal AOT heap

    3. UNROOTED MIXED CYCLE
       shape:            AOT Holder <-> patch CycleNode -> AOT Tracked
       built in:         a never-inline module function, rooted nowhere
       observed by:      AOT-created WeakReference on BOTH the patch node and
                         the AOT node
       after full GC:    both weak targets CLEARED
       => collected, on the collector's own signal

No RSS, allocation counts, finalizer inference, or "the app can't find it" was
used anywhere.

## Type-system participation

    PATCH CLASS IMPLEMENTS AOT INTERFACE
      construct:          PatchIface
      is Interface:       true
      AOT cast:           ok (castToBase / dispatchIface)
      virtual dispatch:   'PATCH-IFACE', PatchIface.tag -> INTERPRETED

    PATCH CLASS EXTENDS AOT BASE
      construct:          PatchChild
      is Base:            true
      AOT cast:           ok
      inherited method:   'INHERITED' (AOT Base.inherited)
      inherited field:    b.n written and read back as 5
      override:           ran
      super -> AOT:       'PATCH:AOT-BASE'
                          PatchChild.execute -> INTERPRETED
                          Base.execute       -> AOT
                          the mode transition is the proof; the string is
                          corroboration

    RETURN PATCH OBJECT TO AOT
      runtimeType:        PatchChild
      identity:           stable across calls
      repeated calls:     agree

    AOT COLLECTIONS
      List<Base> add:     ok        retrieve: identical      dispatch: PATCH:AOT-BASE
      Map<String,Base>:   ok        retrieve: identical      dispatch: PATCH:AOT-BASE
      element type:       still PatchChild after round-tripping through both

    BOUNDED GENERIC  T echo<T extends Base>(T value)
      from AOT, T=Base:       returned identical, runtimeType PatchChild,
                              treated as Base, dispatch enters bytecode
      from BYTECODE, T=PatchChild:
                              the module instantiates the AOT generic at its OWN
                              type -- one that did not exist when the host was
                              compiled. Returned value identical, runtimeType
                              PatchChild, `back is PatchChild` true *inside*
                              bytecode, AOT treats it as Base, dispatch still
                              INTERPRETED.

    FATAL SUBSTRATE DEFECT:   NO

The second generic case was added after the first passed: `echo<Base>(p)` from
the host only shows the **value** survives. The ruling asked for the type
**argument** to cross, so the module instantiates the generic at `PatchChild`
and the reified type argument makes the round trip. It does.

## Instrumentation non-causality

    G1 probe on the G3 build:  reproduced line-for-line, pool counters included
                               (attach true, IsInterpreted 0->1, C++ invoke NEW,
                                load NEW, pool len=1685 / Code slots=117)
    G2 suite on the G3 build:  6/6 PASS
    G1 artifacts re-hashed:    all match g1_manifest.json
    G2 artifacts:              unchanged (G3 built into new out dirs)

## Two harness defects, neither a result

1. **A `final` local could not be nulled** before the collection — and fixing
   the compile error alone would have left a worse question open: whether a live
   slot still rooted the AOT object. Replaced with a never-inline helper
   returning a record, so the frame is structurally gone before `collect()`.
2. **The OFF arm scored `gc_control` as a failure.** It is arm-independent and
   must *pass* on both; the runner now says so explicitly instead of expecting
   `UNSUPPORTED` from every test.

## Boundaries

- Ordinary, valid type dispatch only. No monomorphic call sites, devirtualization
  traps, helper-chain inlining, or TFA adversarial shapes — those are #41, and
  nothing here was restructured to dodge an optimizer.
- Host macOS/arm64. No iOS, no device, no real application.
- Retention across collection is now proven; **binder/replacement semantics for
  an existing call site remain out of scope** and unchanged since G2.

## Routing

Recommend `PROCEED` to [#41](https://github.com/mml555/shorebird/issues/41).
Nothing in the fatal list occurred: no missed cross-boundary reference, no live
object collected from either side, no heap corruption, and patch objects
participate fully in the AOT object graph.
