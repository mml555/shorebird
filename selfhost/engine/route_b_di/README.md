# ROUTE-B-DI-1 (#61) — CLOSED at `VALIDATION_INPUT_UNDERIVED`

Closed as **completed**, which means the investigation reached one of its
authorized outcomes. It does **not** mean
`MODULE_SIDE_DYNAMIC_INTERFACE_VALIDATION` is satisfied. That prerequisite
remains open and blocking for production.

Route B was never modified: 0 changed files across
`selfhost/engine/route_b`, `packages`, `bin`, `scripts`.

## What the two stages established

**Stage A — the validator works.** Given a *complete* specification,
`dart2bytecode --validate` refuses real violations:

| historical arm | outcome |
| --- | --- |
| `no_extendable` | refused at module compile |
| `no_overridable` | refused — the `FAIL_OPEN_SILENT_BYPASS` is eliminated |
| `no_type` | **vacuous arm**, not a validator gap |

`m_ok.dart` only *extends* `Base`; it never names it in a type position, so
withdrawing `can-be-used-as-type` withdrew a permission the module does not
exercise. The rule itself **is** enforced, proven with `m_type.dart` — `m_ok`
plus one type annotation, generated so the difference is provably that. The
historical arm was left unchanged rather than re-pointed at the new module.

Attribution is structural, never a message match: the classifier decides from
`validate_flag_passed`, `bytecode_produced`, `module_compile_exit` and
`load_exit`. Three preconditions gate every arm — the positive is healthy and
overrides, an irrelevant spec addition still compiles, and the same restricted
spec with the flag *dropped* still compiles.

**Stage B0 — no complete input is mechanically available in this fork.** The production path is real and was
found by deriving the consumer universe from the producer/release graph:
`ios_releaser.dart` generates `dynamic_interface.yaml` from the release's own
prepass kernel and captures it into the release supplement;
`patch_command.dart` compiles the patch against that same file. It is
release-bound and release-consumed — and supplies `callable` only, because it
is a **retention** interface. Role: `partial`.

The three permission sections say what a patch may *do to the host*, and no
release-side source in this tree supplies them:

- **the module itself** — permanently ineligible. Reading permissions off the
  patch would permit whatever it does, so validation would refuse nothing.
- **the semantic map** — admits 0 of 36; SEMANTIC-MAP-1 FINAL classified
  `MODIFY_MAP_DESIGN` precisely because it cannot name a patchable surface.
- **committed policies** — 28 found, none release-bound. Two SL1 fixtures do
  carry all four sections and are referenced by universe members; each is
  recorded and accounted for rather than ignored.

No forced conflict with retention cost: validation accepts **member-scoped**
`dart:core` entries, not only whole-library ones. Whole-library `dart:core`
retention is +310%, so a wholesale widening would be unaffordable — but that is
not the obstacle. No source in this tree supplies the sections.

## The decision that closed it

Creating a release-time patch-permission surface would be a new policy and
security contract, not a mechanical completion of #61. It was **declined**. If
it is ever pursued it belongs in a separately authorized design lane.

## Reading the evidence

    run_stage_a.sh     -> evidence/stage_a.txt, stage_a_arms.json
    run_stage_b0.sh    -> evidence/stage_b0.txt, stage_b0.json,
                          b0_universe.json, b0_policies.json, b0_sources.json

Stage A: 13 assertions, 10 falsification arms. B0: 25 assertions, 10
falsification arms in both directions — a classifier pinned to `UNDERIVED` and
one pinned to `DERIVABLE` are both controlled, because a single-direction
control cannot catch a verdict pinned the other way.

The B0 verdict is a function of **source roles**, not of any one generator's
output: `COMPLETE_SPECIFICATION_DERIVABLE` iff some source is release-bound,
release-consumed, supplies all four sections, and is demonstrated to validate
the positive module. A complete source appearing anywhere — including behind a
`publish_*` consumer no filename glob would have found — moves the verdict, and
removing it restores `UNDERIVED`. Both are arms.

## Scope of the result

B0 is a statement about the sources present in this tree at this revision,
reached over the derived consumer universe. It is **not** a statement that no
complete validation source can exist. A future derivation algorithm, or a
deliberately designed permission policy, could supply one — and the classifier
would then say so, which the falsification arms demonstrate directly: a
complete source introduced anywhere in the universe moves the verdict, and
removing it restores `UNDERIVED`. The result is contingent on the evidence, not
a claim about what is possible.

## Provenance constraint: the raw generated digest is path-dependent

`gen_dynamic_interface` emits a `# Source dill: <path>` comment, and each run
supplies a fresh temporary path, so the **raw SHA-256 of the generated
interface changes between runs of identical inputs**. Measured directly: two
runs differing only in that comment line produced different raw digests and an
identical non-comment digest (`642be1cd…`).

This does not affect the B0 result — digests are provenance, never inputs to a
role or a verdict, and there are zero complete sources either way. It does mean
a future lane **must not use the raw digest as reproducible release-identity
evidence** until the emitted bytes are path-stable, or a mechanically defined
semantic digest exists.

`spec_sha256_noncomment` is recorded alongside the raw digest as an interim.
Be precise about what it is: a byte digest over non-comment lines, which is a
*defined* canonicalisation and not a semantic one. It would still move under
entry reordering, a quoting change, or any YAML-equivalent rewrite. A real
semantic digest would parse the document and canonicalise its structure.

## Recorded limitation

Being static does not by itself make a policy non-release-bound. If a policy's
exact digest were mechanically bound into a release identity, the way G6 binds
a map to the full AOT SHA-256, it would be release-bound despite identical
bytes across releases. The rule here treats static-and-committed as not bound,
which is sound for the evidence as it stands — none of the existing complete
committed policies has such a binding, and each is recorded so the claim can be
rechecked. A future lane introducing a digest-bound static policy must refine
the rule rather than inherit it.
