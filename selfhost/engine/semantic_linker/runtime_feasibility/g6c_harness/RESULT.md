<!-- cspell:words dartaotruntime dill semantic linker falsifiability KBC -->
# SL1-G6C — one-command clean reproduction

**Gate:** [#45](https://github.com/mml555/shorebird/issues/45) · **Run:** 2026-09-06

    REPRODUCTION:             PASS
    FEASIBILITY_EVIDENCE:     REPRODUCED
    KNOWN_FAIL_OPEN_FINDINGS: REPRODUCED
    PRODUCTION_PREREQUISITES: UNRESOLVED

Deliberately **not** "all tests pass" — that would contradict G6A. Reproduction
passes while the evidence it faithfully reproduces includes unsafe behaviour.

Structured record: [`evidence/reproduction.json`](evidence/reproduction.json).
Full log: [`evidence/reproduce.txt`](evidence/reproduce.txt).
Reproduce: `reproduce.sh --mode full` (≈1 h). Falsify: `falsify.sh`.

## Machine-readable state

    RUNTIME_SUBSTRATE:   PASS
    MIXED_EXECUTION:     PASS
    TYPE_AND_GC:         PASS
    OPTIMIZER_CONTRACT:  PASS_IF_CAN_BE_OVERRIDDEN
    NEGATIVE_CONTROLS:   FINDINGS_PRESENT
    PERFORMANCE:         MEASURED
    REPRODUCIBILITY:     PASS

    UNRESOLVED_PREREQUISITES:
      MODULE_SIDE_DYNAMIC_INTERFACE_VALIDATION

## What the run actually did

    fresh clone of producer source   (rm -rf, then APFS clonefile)
      -> verify frozen effective Dart tree 7b04b01b
      -> prove no inherited out/
      -> build pristine Dynamic Modules OFF and ON
      -> compare against G1's accepted manifest
      -> APPLY the banked experiment patches
      -> build the instrumented pair
      -> rerun every gate, the negatives, and the cost families

It tests reconstruction, not inherited state: the working lane tree carries the
G2 and G3 instruments, so building the G1 pair on top of it would have built
something else and called it G1. Full mode re-clones first, and applying the
banked patches is itself the test that they still apply.

## Reproducibility, split — two different claims

    LANE_BUILD_REPRODUCIBILITY
      dm_off:  5/5 byte-identical
      dm_on:   5/5 byte-identical
      verdict: REPRODUCIBLE
      claim:   the G1 host toolchain builds are byte-reproducible from the
               G0-banked frozen source lineage

    SUPPORTED_CELL_REPRODUCIBILITY
      verdict: NOT_ESTABLISHED_BY_THIS_GATE
      prior:   vm_platform.dill reproduced; full cell not reproduced

**10/10 byte-identical**, including `dartaotruntime`, `gen_snapshot` and `dart`
on both arms — from a full re-clone and rebuild, not an incremental one. I had
predicted linked executables would not be bit-reproducible; that prediction was
wrong for this toolchain, and the measurement is what stands. The instrumented
pair reproduced too (`g3_off e656386f…`, `g3_on 29bebdf7…`).

This narrows [`NEXT_LANES.md`](../../../NEXT_LANES.md)'s "nothing reproduces the
cell" with new evidence; it does **not** retract it. What is shown is that this
toolchain builds deterministically from source — the precondition for cell
reproducibility, not the thing itself.

## Gates, reproduced from the clean rebuild

| gate | result |
|---|---|
| G1 substrate | PASS — OFF refuses both ways, ON attaches and loads |
| G2 mixed execution | PASS — 6/6 |
| G3 type/generic/GC | PASS — 10/10 |
| G4 optimizer | PASS — fenced sound, **and the unfenced bypass reproduced** |

`G4_optimizer.bypass_reproduced: true` is required, not incidental. If the
devirtualization bypass ever stopped happening, that would be a change in the
world and must not read as a pass.

## Negative findings reproduced as findings

    total 12   closed_expected 5   closed_other_category 1   fail_open 5

    fail_open: wrong_platform_dill, wrong_runtime_build,
               no_extendable, no_type, member_not_overridable

The verdict is computed, and there is no branch that yields a clean PASS while
`fail_open_findings` is non-empty. G6A's phase is recorded as `FINDING`, never
as a successful negative.

## Costs reproduced within measurement semantics

    aot_to_aot_direct     2.27 ns      alloc_aot_aot_type          5.69 ns
    aot_to_aot_virtual    2.52 ns      alloc_bytecode_aot_type    77.15 ns
    aot_to_bytecode      20.78 ns      alloc_bytecode_patch_type  95.52 ns
    bytecode_to_aot      27.94 ns
    bytecode_to_bytecode 28.39 ns

Timings are not required to match byte-identically. What must reproduce is that
the measurement ran, that raw samples and methodology are retained, and that the
qualitative distinctions hold — interpreted execution ~9-12x a direct AOT call,
the interpreted modes close to each other, and flat GC cost across modes. They
do. No numeric tolerance was imposed after the fact.

## Falsifiability — derived from one inventory, never maintained

`reproduce.sh` and `falsify.sh` both read
[`mandatory_evidence.json`](mandatory_evidence.json). Neither keeps a list and
neither keeps a count, and the equality is asserted at run time:

    inventory_count = 12   falsified_count = 12   caught_count = 12
    supplementary   = 12   supplementary_caught = 12
    all 12 originals restored byte-for-byte
    post-restore report-only: REPRODUCTION=PASS

Every item is mutated the required way and then a second, complementary way; a
supplementary miss fails the run too. Structured output:
[`evidence/falsification.json`](evidence/falsification.json).

**This replaces a defective first version, and the defect is the point.** That
version kept its own eight cases against the twelve `reproduce.sh` enforced, and
still printed *"every mandatory-evidence mutation is refused"* — a claim broader
than what it had tested. Omitted then: the G4 unfenced transcript, both cost
transcripts, and the G2 and G3 experiment patches. A hand-maintained count is
precisely how a harness comes to overstate itself, so there is no longer one.

The whole mechanism exists because G6C found a harness that printed
`structured: negatives.json` for a file it had never written — the defect that
would have made every other check worthless.

## Four harness defects found by building this gate

Each is a G6C finding, not a footnote:

1. **Structured output announced but never written.** G6A pasted JSON rows into
   a Python literal and died on `null`; the script reported success regardless.
   Rows now parse as JSON and the write is verified or the script exits nonzero.
2. **Stage logic could not tell a first run from a rerun** — it asserted `out/`
   must not exist, which is right for a fresh clone and wrong on re-verify.
3. **"Full reproduction" could consume already-instrumented source.** Fixed by
   re-cloning and applying the banked patches.
4. **`re.M` missing in the cost extraction**, so every row silently failed to
   match while `PERFORMANCE` read `NOT_MEASURED` — a green-looking field derived
   from nothing.
5. **The falsification matrix was narrower than the evidence it claimed to
   cover** — 8 hand-listed cases against 12 enforced items. Both scripts now
   derive from one inventory and assert the equality rather than asserting the
   conclusion.

## Provenance of this record

The authoritative run was `--mode full`. The structured record was regenerated
with `--mode report-only` after the schema was extended; it carries
`source_run_mode: full`, `source_run_started`, and `regenerated_from_evidence:
true`. No gate was re-run to produce it, and report-only cannot manufacture one.

## Repository checks

    shell_syntax       every lane script parses
    json_valid         every emitted record parses
    yaml_valid         every dynamic interface parses
    product_untouched  packages/, bin/, route_b/ and compatibility.yaml unmodified

The last is the one that matters: if the product had moved, the whole
feasibility argument would be contaminated.
