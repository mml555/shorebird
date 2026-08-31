# D-SUPER-2B.1g (part 1) — analyzer v11 + the narrow-v1 gate, in the product.

Host only. **The wiring is NOT finished** — see the end. What is done is the
evidence contract and the admission gate, with regressions.

## analysisVersion 11

Two additions, both justified by measurement rather than convenience:

    superInvocations[].target    the resolved super target, PROVENANCE ONLY
    releaseSuperTargets          the same tuple for every super target the
                                 RELEASE version of THIS SAME method already
                                 direct-called

`origin` already existed at v10. Same-method evidence is computed from the base
component with the base component's own `ClassHierarchy` — resolved in the kernel
that was actually compiled, not in the patch's.

**The exact-key assertion was updated deliberately, not weakened.** v10 asserted
a super entry's keys were exactly `{offset, member, kind}` precisely so a
resolved target could not be added silently. v11 asserts
`{offset, member, kind, target}` and additionally asserts the target's own keys
are exactly `{fileUri, fileOffset, name, kind}`. Still never carried: the
canonical owner, the synthetic mixin-application name, any argument count.

Observed on the 2B.1f control 1 pair:

    site offset 1005          (the release's was 988 — the patch wraps the call)
    target      [672, close, Method]
    release     [672, close, Method]      -> ADMIT

The site moved; the target did not. That is the whole reason the comparison is on
the target.

## The producer gate

Refuses, before any bytecode is produced:

* a super site whose target did not resolve — *"no resolved target, so there is
  no evidence the release compiled one"*;
* a target not in `releaseSuperTargets` for the same method — *"resolves to a
  target this release never direct-called from `<method>`"*.

An ordinary superclass target the release never super-called **would** in fact
work (2B.1d arm D). It is refused anyway: the gate carries evidence, not
inferences from class shape.

## Tests and regression

    route_b_producer_test.dart            87 passed
      + refuses a target the release never direct-called
      + refuses when the release direct-called nothing at all
      + refuses a site whose target did not resolve
      + admits when only the SITE moved and the target did not
    route_b_* CLI suites                  144 passed, 1 skipped
    v11 contract controls                 32 clauses, all six shapes
    coverage/parity.sh                    8 passed
    analysis vs the v9 baseline           8/8 semantically identical, once the
                                          version and the v10/v11 additions are
                                          normalised
    census construct tables               byte-identical to the banked D0.4

One correction on the way: the v11 controls first "passed" against a **stale**
`analysis.json` from the v10 run, which meant the updated key assertion was never
exercised. Regenerated before being believed — a control read from a cached
artifact is not a control.

## Not done, and the lane is not closed

1. **The compiler still reads the RELEASE import kernel.** `0015` remains
   UNSOUND AS DESIGNED. Switching it to the patched no-AOT kernel is mandatory
   before the positive E2E, and it is a change to what the CALLER supplies
   (`ios_patcher`, `cli_produce.dart`), not only to the producer.
2. No cell/build assertion yet that a supported cell cannot carry the old
   release-import behaviour.
3. The compiler does not yet require its locally-resolved target fingerprint to
   equal the one carried for the admitted dependency.
4. The TFA-symmetric E2E fixture is unrepaired, so the positive shipping-producer
   arm has not run.
5. Both mutations remain unrun through the product path — the source-argument one
   is still invalid until (1) lands, and the compiled-target one has only been
   run in the 2B.1f harness.

So the host claim is **not** yet available. What can be said today is narrower:
the analyzer publishes the evidence, and the producer refuses everything the
narrow-v1 rule refuses.


---

# Part 2A — 0016 target agreement, and a design tension in the import kernel

## 0016 supersedes 0015; 0015 is not rehabilitated

`0015` keeps its record and its **UNSOUND AS DESIGNED / DO NOT PROMOTE** banner.
`0016` is a distinct revision: everything 0015 does, plus the check it never had.

The intrinsic now carries the analyzer's **expected target provenance**
alongside the site identity — 11 arguments, still no canonical owner and still
no arity — and the compiler refuses unless the target it resolved *locally*
equals it:

    expected  = analyzer, from the PATCHED AOT kernel
    observed  = dart2bytecode, resolving in the kernel it compiles against
    mismatch  = refusal, no fallback

The two sides are independent, and 2A.2 measured that this provenance survives
the AOT/no-AOT boundary. Without it a compiler could read the right body and
still resolve a different semantic target than the producer's release-evidence
gate admitted.

## The permanent wrong-import control

`run_import_control.sh`, on the moved-site specimen — release site 988, patch
site 1005, identical target:

    release site offset 988 / patch site offset 1005
    PASS  the site MOVED between versions        yes

    release_import   REFUSED   "no super invocation at offset 1005 in Leaf.target"
    patched_import   ACCEPTED  rediscovered site=1005, selected …|672|close|Method
                     execution WRAP:TICKER:APP-STATE

A compiler that regressed to reading the release body cannot pass this: it finds
nothing at 1005. This is the durable caller-level assertion the ruling asked for.

## The tension: `--import-dill` is a RELEASE ARTIFACT

Switching the compiler's import kernel is **larger than a caller rename**, and
the ruling's sequencing assumed otherwise. The evidence:

    ios_releaser.dart:688     the release BUILDS the no-AOT import kernel
    ios_patcher.dart:283,566  the patch DOWNLOADS it as a release artifact
                              (`releaseArtifacts[routeBReleaseImportKernelFileName]`)
    ios_patcher.dart:~560     `_verifyReleaseKernelsAgree` refuses a release whose
                              two kernels describe different programs

So today the import kernel is not merely "a kernel to look things up in" — it is
**what the entire replacement binds against**, chosen deliberately so the
bytecode is bound to the program that actually shipped. The producer says so at
its `--import-dill` argument: *"the RELEASE's import kernel … so the bytecode is
bound against the program that actually shipped."*

Compiling the whole replacement against the PATCHED kernel would change what
**every** reference in it binds to, not only the super site. 2B.1d proved a
super `DirectCall` derived that way binds — in toys where the two versions differ
in one body. It did not establish that the rest of a real replacement should be
bound to patched rather than shipped reality.

**An alternative that preserves the existing binding architecture**, and which
this lane has not evaluated: give the compiler the patched no-AOT kernel as a
SECOND, verification-only input — site rediscovery and shape checking read the
PATCHED body, while target resolution and every other reference stay bound to the
RELEASE import kernel. Narrow-v1 already guarantees the target exists and is
compiled there, and the fingerprint agreement above ties the two together.

I have not chosen between these. The wrong-import control passes under either,
because it asserts the shape check reads the patched body — which both designs
require.

## Status of part 2A

    intrinsic carries expected target provenance      DONE
    compiler enforces fingerprint agreement (0016)    DONE
    producer emits it                                 DONE  (74 producer tests)
    permanent wrong-import negative control           DONE
    patched no-AOT generation + caller wiring         NOT DONE — needs the
                                                      design decision above
    cell feature marker for the corrected compiler    NOT DONE

Part 2B (TFA-symmetric fixture, positive shipping arm, both mutations) stays
blocked on the wiring, as before.


---

# Part 2A continuation — 0017, the DUAL-KERNEL compiler

The ruling's decision, implemented: `--import-dill` stays the shipped program
the whole replacement binds against, and the patched kernel enters as an
**isolated verifier**.

    --import-dill <release-import.dill>          BINDING
    --patched-verification-dill <patched.dill>   VERIFICATION ONLY

The verification component is loaded separately and is **never merged into
`allLibraries`**; nothing in it can be named by emitted bytecode.

## Three fingerprints must agree

    analyzer expected   from the PATCHED AOT kernel
    patched verifier    resolved in the patched no-AOT hierarchy
    release binder      resolved structurally in the release hierarchy

and the `DirectCall` names the **release** Procedure. Any disagreement refuses;
there is no fallback anywhere.

**Site identity never crosses into the release lookup.** The offset is used only
against the patched kernel. The release side is found by origin class + super
member through the release hierarchy — requiring a release super call at the
patched offset would reintroduce exactly the cross-version dependency
2B.1c-SITE exists to kill.

## Controls

    release site 988 / patch site 1005 / identical target

    wrong_verifier_release   REFUSED   "no super invocation at offset 1005 …
                                        (patched kernel)"
    dual_kernel              ACCEPTED  patched verifier agrees, release binder
                                       agrees, binds to the RELEASE procedure
                                       (owner _Leaf&Base&Ticker)
                             execution WRAP:TICKER:APP-STATE
    corrupted expected       REFUSED   caught by the PATCHED verifier
    release binder isolated  REFUSED   "the RELEASE kernel resolves a different
                                        super target than the analysis
                                        authorized"

**On what the disagreement arm isolates.** Both comparisons test the same
expected tuple and the patched verifier runs first, so corrupting the tuple is
caught there — that arm proves a disagreement refuses, not that the release-side
check works. The release-side equality is reached by a second arm that disables
the patched comparison, because building a specimen where the two hierarchies
genuinely resolve DIFFERENT targets is prevented by Route B's own
signature/hierarchy guards. Recorded rather than glossed.

## A harness fault, fixed

The first dual-kernel run left the engine tree dirty: the harness captured its
restore baseline from an **already-patched** generator, so "restored" restored
the patch. `run_import_control.sh` now refuses to start against a patched tree,
and both the generator and the driver are restored and checksummed.

## Status

    dual-kernel 0017 (verification isolated from binding)      DONE
    three-way fingerprint agreement                            DONE
    DirectCall binds the RELEASE procedure                      DONE
    wrong-verifier control                                      DONE
    release-binder disagreement control                         DONE
    patched no-AOT generation + producer/caller threading        NOT DONE
    compiler-cell feature marker (routeBDirectSuperDualKernelV1) NOT DONE

Part 2B stays blocked on the two remaining items: the product does not yet
BUILD a patched no-AOT kernel at patch time, nor pass one.
