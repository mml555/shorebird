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

---

# ARM 2 — the profile channel PASSES, unobfuscated and obfuscated

2026-08-25, same three-specimen release (`app.aot` `b8e72036…`, profile beside
it). Decoder corrected: node/edge `type` indexes `meta.node_types[0]` and
`meta.edge_types[0]`; `to_node` is a byte offset into `nodes`; edges are laid out
per node in node order (asserted — the walk consumes the array exactly).

## The three-way measurement

Each specimen resolves to **exactly one `Function` node** — no ambiguity — and the
discriminating structure is which `ObjectPool`s reference it, traced to the `Code`
that owns the pool:

| target | Function nodes | pools referencing it | pool owner (`Code`) | runtime truth |
|---|---|---|---|---|
| `foldOpaque` | 1 | **3** | `[Optimized] _specimenLine`, `[tear-off] foldOpaque`, one unowned | surviving, executes |
| `foldConst` | 1 | **0** | — | folded |
| `deadBranch` | 1 | **3** | `[Optimized] _specimenLine`, `[tear-off] deadBranch`, one unowned | survives, never taken |

**`foldConst != deadBranch`: 0 pools against a pool owned by the actual caller.**
That is the comparison the arm existed to make, and it passes.

Why this is invocation evidence rather than a generic reference: a patchable
static call loads `entry_point_` from the callee's `Function`, held in the
CALLER's object pool — which is exactly the `ldur lr,[r0,#7]; blr lr` form the
release-level detector counts. So a pool owned by `_specimenLine` holding the
target's `Function` IS a surviving call site in `_specimenLine`.

## Obfuscation: the channel survives, and for a reason worth knowing

Rebuilt the same `release.dill` with `--obfuscate --save-obfuscation-map`.
Obfuscation genuinely ran — **3,371 of 5,095 names renamed** (`exponent -> UL`,
`implementation -> TH`) — and the three-way partition is unchanged: 3 pools / 0
pools / 3 pools, with the same caller attribution.

The specimens' names were **not** renamed, and the mechanism is not luck:

| name | named in the dynamic interface? | after obfuscation |
|---|---|---|
| `print`, `now`, `millisecondsSinceEpoch` | yes (`--sdk-members`) | preserved |
| `exponent`, `implementation`, `xIndex` | no | `UL`, `TH`, `mp` |

**A name the dynamic interface retains must stay bindable by name, because that
is how a dynamic module resolves it at run time — so the obfuscator preserves
it.** Every Route B target is named in the interface by construction, since that
is what retention means. So identity-by-name holds for exactly the set of members
Route B can target, and dies only for members it could never patch anyway.

That is a dependency, not a free lunch, and it belongs in the eventual probe's
design: **the fundamental identity stays (library, owning class, member/signature)
and the string is the lookup mechanism, valid because the interface preserves it.**
If that retention/obfuscation interaction ever changes, the lookup breaks and the
instrument must fail closed rather than silently miss.

## Stop condition: MET

One static method distinguishes all three states, by exact Function identity, with
caller attribution, and still does so under obfuscation. The instrument can now be
specified.

## What the specification will have to settle, from what this arm exposed

1. **Classification rule for "surviving invocation site".** Not every pool
   reference is one: the target's own `[tear-off]` Code has a pool referencing it,
   and one pool had **no `Code` owner at all**. The rule needs to name which
   referrers count and which do not, and the unowned pool needs a category rather
   than a shrug.
2. **The profile is not emitted by the release pipeline today.** Turning
   `--write-v8-snapshot-profile-to` on is a build change, and this toy's profile is
   1.6 MB for 24,833 nodes — the size and cost on a real app are unmeasured.
3. **Binding.** The profile is build-produced and must be bound to the exact
   artifact by digest (P4.4), or it is evidence about some other compilation.
4. **`UNKNOWN` must stay distinct** from zero-sites: "no Function node found" and
   "Function found, zero qualifying referrers" are different facts, and only the
   second is `NO_SURVIVING_CALLSITE`.
