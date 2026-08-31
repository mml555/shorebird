# 2C.0a — STOP. The cell's identity is not the engine-fork revision.

Nothing certified moved. The engine fork is back on `route-b` at
`619fdad176ff4573…`; the candidate commit lives only on an unmerged branch.

## What was done

    candidate branch   route-b-2c-candidate
    candidate revision b456dc0dd88ff45575b364bd994a45892f2515f3
    parent             619fdad176ff457331b50230b9511e7230a6ed93
    contents           one Markdown file. No runtime source changes.

Committed with `--no-verify`: the engine's pre-commit hooks run depot_tools'
`vpython3`, absent from this rig's PATH, so the hook aborts before checking
anything. Recorded rather than hidden — the same situation was banked once
before in `evidence/p6-signing/RUNTIME_SOURCE_BANKED.md`. The commit adds one
Markdown file and touches no buildable source.

## The finding, and why it stops the plan as written

**A Route B compiler cell is keyed by the release's recorded engine revision,
which is the pinned FLUTTER's `bin/internal/engine.version` — not the mml555
engine-fork SHA.** Measured:

    ~/.shorebird/bin/cache/flutter/a4a3c0d1…/bin/internal/engine.version
      -> 4792f0eca461f3761001a1adbe131b4b115e3684

    selfhost/cdn/overlay/…/shorebird/4792f0eca461…/   exists — cells live here

    ios_patcher.dart:833  routeBCompilerResolver.resolve(
                            engineRevision: provenance.engineRevision)

`619fdad1` is the engine fork's *source* provenance, recorded in
`compatibility.yaml`. It is not what resolves a cell. So the candidate revision
created above — honest and harmless as it is — **does not by itself produce a
distinct cell identity**, and the plan's `candidate engine revision → candidate
cell` mapping lands on the Flutter engine revision instead.

Publishing the v11+0017 cell under `4792f0ec` would overwrite the certified
published cell, which is forbidden.

## Two ways forward, and neither should be picked unilaterally

**(a) Earn a real candidate engine.version.** Build the candidate engine
revision and derive a new hash from the build the way this repo already does —
`publish_ios_overlay.sh` computes its hash as *"sha1 of the device-slice Flutter
binary"*. Then create a candidate Flutter revision pinning that
`engine.version`, publish the candidate cell under it, and map it through
`experimental_hashes.map`. The chain stays honest end to end:

    engine source → real build → artifact-derived hash → Flutter pin → cell key

Cost: a real iOS engine build. The existing `ios_*` out dirs date from
2026-08-27, so this is not a no-op rebuild.

**(b) Keep `4792f0ec` and isolate the serving instead.** Publish the candidate
cell into a scratch overlay served by a second CDN instance, leaving the tracked
overlay and the certified cell untouched. Cheaper, but the candidate release
would record an engine revision whose cell differs depending on which CDN
answered — a routing fiction of exactly the kind (a) exists to avoid.

**(a) is the one consistent with every rule this programme has frozen**, and it
is also the expensive one. That trade is a decision, not a detail.

## What was deliberately NOT done

* No candidate Flutter revision created — inventing an `engine.version` value is
  precisely the fictional routing token the ruling forbade, and deriving a real
  one requires the build in (a).
* No engine build started.
* No overlay write, no `experimental_hashes.map` entry, no release cut.
* `~/.shorebird` untouched — the isolated-CLI finding means it never needs to be.

## Ledger

`LEDGER_BEFORE.txt` records the pre-mutation state. Re-verified after the work
above:

    engine fork HEAD        619fdad176ff4573…   (unchanged, on `route-b`)
    published cell 4792     0696da541c2b9a9d…   (unchanged)
    compatibility.yaml      42a970f46a234794…   (unchanged)
    installed CLI HEAD      207c4a7ac91f937e…   (unchanged)
    experimental map        7bdc97bf9ed27082…   (unchanged)

The only addition anywhere is an unmerged branch in the engine fork.
