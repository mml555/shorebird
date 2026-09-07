# SM1-G5 — work in progress, NOT a gate submission

**Gate:** [#54](https://github.com/mml555/shorebird/issues/54) · started 2026-09-07

## What is built and sound

`lib/predict_patchable.dart` — the PREDICTION path. Consumes only G2/G3/G4 map
rows and emits, per declaration, `predicted_patchable` plus a refusal reason
from a fixed vocabulary. On the frozen base corpus: 23 declarations, 14
predicted patchable, 9 refused, coverage 60.9% (emitted as
`coverage_diagnostic_only`, and #54 forbids it from affecting any verdict).

Two design points worth keeping:

* **Independence is structural.** This file never reads the demonstrator and the
  demonstrator never reads it. #54's confound is that a subset check between two
  outputs of the same model compares the model with itself.
* **`PRIVATE_TYPE_REFERENCE` is a refusal reason even though #54 does not list
  it.** D-DEMAND-1 measured the shipping ANALYZER admitting changes the shipping
  PRODUCER refuses (Wonderous 70.00% analyzer vs 45.00% producer, later 50.00%),
  and D-PRODUCER-DEMAND-2 found the only blocker class replicated across both
  corpora was `private non-construction references` — a body naming a private
  TYPE. Omitting it would reproduce a known, measured over-claim.

## What is NOT yet trustworthy, and why nothing is claimed from it

`probe/demo_host.dart` calls `attachBytecodeToFunction` directly from `main` and
then re-invokes the subject. Against the frozen corpus every subject reports:

    ATTACHED true
    ATTACH: pool len=1691, rewrote 0 slot(s)
    DEMO_RESULT SILENT_NO_EFFECT

A control rules out the obvious harness explanation: adding a
`@pragma('vm:never-inline')` indirection between the observer and the subject
changed nothing, so it is not the observer's own call being inlined.

**That is still not evidence about the system.** `probes/p1_bind_private_receiver.sh`
demonstrably patches this same shape, and it does NOT use a bare attach: it packs
a patch with `packaging/pack_patch.dart` into an `.sbrb` and runs
`dartaotruntime app.aot patch.sbrb`, letting the RELEASE apply it, then reads the
program's own call. So the difference is very likely my harness, not the VM, and
`SILENT_NO_EFFECT` is recorded here as a harness state rather than a finding.

Reporting those nulls as "not demonstrated patchable" would manufacture
over-claims out of a demonstrator that does not represent the shipping path --
the exact failure #54's confound section warns about.

## Next step

Rebuild the demonstrator on the shipping apply path (`pack_patch.dart` ->
`.sbrb` -> runtime apply -> the program's own call), which is both faithful and
independent of the map. Only then can the subset check mean anything.

## Open question for the PM

Two candidate over-claims are already visible in the predictions and are
recorded as HYPOTHESES, not results, pending a faithful demonstrator:

1. `Box.unwrap` is predicted patchable while its owner `Box` carries
   `abi_shape: refused:type_parameters`. A member of a generic class may not be
   patchable even when its own signature is supported.
2. Patchability may be a property of the CALL SITE rather than of the
   declaration. If a direct-bound call site cannot be redirected, a
   per-declaration map cannot decide patchability alone, and #54's
   `REDUCE_SCOPE` stop condition would be in scope -- naming the class and
   proving the exclusion is decidable fail-closed.

Neither is established. Both need the faithful demonstrator first.
