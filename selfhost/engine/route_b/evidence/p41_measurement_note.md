# P4.1 measurement pass — specimen set established; evidence channel NOT yet chosen

2026-08-25. Deliberately stopped before specifying `route_b_release_probe`, per
the stop condition: pick the identity route only when one method distinguishes
all three states, with no source-content heuristic and no manually supplied
address. That has not happened yet.

## What IS established: the specimen set, and it is reproducible

`probes/p41_specimen_ground_truth.sh`, GREEN 3/3. Three states in ONE release
artifact, so the only variable is the target:

| specimen | patch outcome | runtime truth |
|---|---|---|
| `foldOpaque` | `NEW-OPQ/CST` | surviving call site, executes |
| `foldConst` | `OPQ/CST` **unchanged** | folded — every call site substituted the constant. The G15 shape |
| `deadBranch` | `OPQ/CST` **unchanged** | call site survives; the branch is never taken |

**`APPLY ok: 1 target(s)` for all three.** The runtime report distinguishes none
of them, and the two failures are indistinguishable from their outcome while
having different causes. That is the whole reason P4.1 needs a static instrument,
and the reason its vocabulary must keep `NO_SURVIVING_CALLSITE` separate from
"survives but is not reached".

### The fixture shape is not arbitrary, and the first attempt was wrong

The first attempt used INSTANCE methods carrying `@pragma('vm:never-inline')`.
**It did not fold at all** — patching the "folded" specimen changed the value, so
the middle row did not exist and any probe measured against it would have been
calibrated on two states, not three. `evidence/g15/foldability_verdict.txt` had
already isolated the shape that folds: top-level, identically signed, called from
one caller on adjacent lines, and **no pragma**. The pragma and the receiver were
both confounds. The probe now encodes that, and scores itself INVALID if
`foldConst` ever renders `NEW-CST`.

## What is NOT established: which static channel recovers the distinction

Two first readings, both recorded as provisional:

* **Binary-only, names.** `foldOpaque`, `foldConst` and `deadBranch` all appear as
  strings in `app.aot`, so identity by name is available *in this unobfuscated
  build*. Occurrence counts differ (3 for `foldConst` against 4 for the others),
  which is a difference in the right direction and **explicitly not usable**: a
  name-occurrence count is a heuristic, not target identity plus surviving-site
  evidence. It is also exactly what obfuscation would remove.
* **v8 snapshot profile** (`--write-v8-snapshot-profile-to`, kept beside the
  artifact). It records 24,833 nodes / 86,106 edges / 9,481 strings for this
  fixture, and all three specimen names are present — so it is a build-produced
  channel, bound to the exact compilation, that plausibly carries "which Code
  objects reference this Function". **My first decode of it was WRONG** — the
  profile's node/edge `type` and `name` fields index `meta.node_types`, not the
  string table, and I read both from `strings`. The referrer counts that produced
  (7 / 4 / 7) must not be used; they are an artifact of my decoder, not a
  measurement. Re-decoding correctly is the next step.

## Why the note stops here rather than proposing a vocabulary

Because the three-way distinction has not been demonstrated by any channel yet,
and the vocabulary is supposed to be frozen *around what the instrument showed*.
Naming `SURVIVING_CALLSITE` / `NO_SURVIVING_CALLSITE` / `UNKNOWN` now would be
committing to a shape before the evidence exists — the same order-of-operations
error the corpus model made twice.

The ownership decision is unaffected and stands: **the cell owns observations
about compiled bytes; the producer owns policy.** Nothing measured here argues
against a build-produced sidecar bound by artifact digest, and one reading leans
toward it — names survive today only because this build is unobfuscated.

## Next, in order

1. Re-decode the snapshot profile correctly (`meta.node_types` / `meta.edge_types`)
   and ask whether Function-referrer structure separates the three specimens.
2. If it does: check it still separates them under obfuscation, since that is
   where binary-only name identity dies.
3. If it does not: price the build-sidecar option — what `gen_snapshot` would have
   to emit while it still knows target identity, and how it binds by digest.
4. Only then specify `route_b_release_probe`, with the `deadBranch` specimen kept
   permanently as the control that forbids wording the result as `reachable`.
