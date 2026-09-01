# 2C.0a.3–.4 — candidate built, acceptance gate PASS.

Nothing published, nothing pinned, no map entry, no release cut.

## Environment repair, scoped as authorized

    before   ninja not installed; /opt/homebrew/opt/ninja DANGLING; none on PATH
    plan     `brew install --dry-run ninja` -> "Would install 1 formula: ninja"
    after    ninja 1.13.2 at /opt/homebrew/bin/ninja; /opt/homebrew/opt resolves

No `brew update`, no upgrades, no Python or depot_tools repair. The dry run was
checked first and showed no unrelated dependency changes.

A second, non-mutating fix was also needed: the build's generated-header actions
call `vpython3`, which exists in the tree at
`flutter/third_party/depot_tools/vpython3` and merely was not on PATH. Supplied
per-command (`PATH="$DT:$PATH" ninja …`) rather than installed anywhere.

## The build

Built commit `dfa2b24ac38477f3705ff0357530f33fe09474b8` — the **marker** commit,
not the docs-only `b456dc0d`. 8050 targets, ~28 minutes. It was not the small
incremental rebuild expected: the generated SPIR-V/Dart headers were stale, so
most of the graph re-ran.

## Acceptance gate — PASS

    candidate sha1    a5a8be5854c529268378ce16762a16d6e31763e9
    candidate sha256  2fa8b808e863552f1ebf9ffaa8b460c299b16241d68cfb19689798534e555f58
    candidate size    19,104,576
    certified sha1    cc150ab64dbeef57be41fd7b1bd12bda5cb7e717
    certified size    19,104,440

    PASS  candidate sha1 differs from certified      differs
    PASS  marker present in candidate                1
    PASS  marker ABSENT from certified               0
    PASS  updater revision in candidate              1
    PASS  updater revision in certified              1

+136 bytes, one occurrence of the marker, and `af6e842ccf87` unmoved on both
sides. The updater provenance did not participate in earning this identity.

## The claim, stated as it should be

> Runtime semantics are intended unchanged; artifact identity is deliberately
> distinct through a single retained, non-executable Shorebird provenance atom.

Not "byte-identical" — it deliberately is not. Not "a different runtime" — no
behaviour changed. The difference has exactly one source and it is in the diff.

## SHARED STATE CHANGED — read this before using the rig

`engine/src/out/ios_release` **now holds the CANDIDATE build**, and the engine
fork is left on `route-b-2c-candidate` so source and artifacts agree. Leaving the
fork on `route-b` while the out dir held candidate bytes would be the more
dangerous state.

    certified device slice   preserved at
                             scratchpad/certified_preserved/Flutter.certified
                             sha1 cc150ab6…, sha256 62bd2395…, 19,104,440 bytes

To restore the certified build: check out `route-b` and rebuild `out/ios_release`.

## Held, awaiting the next ruling

    candidate Flutter pin        WAIT
    cell publication             WAIT
    experimental_hashes.map      WAIT
    release cut                  WAIT

The measured value the chain would use is
`a5a8be5854c529268378ce16762a16d6e31763e9`, and nothing has consumed it yet.

## Ledger, re-verified

    published cell      0696da541c2b9a9d…  unchanged
    compatibility.yaml  42a970f46a234794…  unchanged
    installed CLI       207c4a7ac91f937e…  unchanged
    experimental map    7bdc97bf9ed27082…  unchanged
    engine fork         route-b-2c-candidate @ dfa2b24a (619fdad1 intact)
