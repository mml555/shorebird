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
