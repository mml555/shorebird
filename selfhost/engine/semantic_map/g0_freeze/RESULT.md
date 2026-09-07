<!-- cspell:words dartaotruntime dill semantic localsend wonderous -->
# SM1-G0 — frozen inputs, corpus and reference implementations

**Gate:** [#49](https://github.com/mml555/shorebird/issues/49) · **Tracker:** [#48](https://github.com/mml555/shorebird/issues/48)
**Run:** 2026-09-06, hardened 2026-09-07 · **Verdict: FROZEN and fail-closed.**
Two PM review passes closed four acceptance gaps; one finding is recorded before
it could mislead a later gate.

Machine-readable: [`freeze_manifest.json`](freeze_manifest.json).
Re-check with `freeze.sh` (default `--verify`); rewrite only with `--emit`.

## Finding — `parity.sh` defaults to an analyzer the cell does not ship

    build tree    18862acd…   2,035,128 bytes
    shipped cell  67741a08…   2,053,976 bytes   ← SUPPORTED_STATE.yaml

`coverage/parity.sh` defaults `ANALYZER` to
`$OUT/zip_archives/route_b_analyze.aot`, which is a **build-tree** artifact. The
analyzer the compiler cell actually ships is a different file. Freezing "the
analyzer" by pointing at the build tree would have frozen the wrong artifact, and
every later gate would have been measuring something the product does not use.

The freeze takes the analyzer **from the cell archive** and verifies it against
`SUPPORTED_STATE.yaml`. The build-tree copy is recorded as a known divergence
rather than silently used. **Any parity run in this lane must pin `ANALYZER=` to
the shipped digest.**

## What is frozen

| input | how |
|---|---|
| release lineage | inherited from SEMANTIC-LINKER-1's freeze; producing Dart effective tree `7b04b01b` re-verified |
| analyzer | shipped digest `67741a08…`, taken from cell `f85251f3` |
| reference implementations | `gen_target_manifest.dart`, `build_patch.dart`, `analyze_coverage.dart`, `parity.sh` — by digest, unmodified |
| real-world corpus | `wonderous.window.txt` (40 revisions), `localsend.window.txt` (80 revisions) |
| adversarial corpus | 12 mutants, digest `4a85fcc2…`, expectations declared in `corpus/EXPECTATIONS.json` |

## The adversarial semantic corpus

One base program plus **twelve mutants, one dimension each**, so a later
disagreement is attributable to that dimension and nothing else. Expectations are
**declared here and frozen**, so G1 and G2 check the map against a stated
intention rather than against whatever the map happens to say.

| mutant | subject | id stable | ABI = | body = | expected |
|---|---|---|---|---|---|
| `body_only` | `topLevel` | ✔ | ✔ | ✘ | changed existing declaration |
| `abi_added_positional` | `Shape.area` | ✔ | ✘ | ✘ | not reusable |
| `abi_nullability` | `topLevel` | ✔ | ✘ | ✔ | not reusable |
| `abi_positional_to_named` | `Shape.area` | ✔ | ✘ | ✔ | not reusable |
| `abi_generic_bound` | `Box` | ✔ | ✘ | ✔ | not reusable |
| `abi_return_type` | `Shape.perimeter` | ✔ | ✘ | ✔ | not reusable |
| `reorder` | `topLevel` | ✔ | ✔ | ✔ | unchanged |
| `unrelated_added` | `topLevel` | ✔ | ✔ | ✔ | unchanged |
| `unrelated_removed` | `topLevel` | ✔ | ✔ | ✔ | unchanged |
| `unrelated_renamed` | `topLevel` | ✔ | ✔ | ✔ | unchanged |
| `field_added` | `Shape.area` | ✔ | ✔ | ✔ | unchanged |
| `private_other_domain` | `usesPrivate` | ✔ | ✔ | ✔ | unchanged |

Four cases are load-bearing and worth naming:

- **`body_only`** — a body change must not move `DECLARATION_ID`, or the map
  cannot express *"same declaration, new implementation"*.
- **`abi_nullability`**, **`abi_positional_to_named`**, **`abi_generic_bound`**,
  **`abi_return_type`** — body text is *identical* and only the signature moved.
  A map reporting `abi_equal` here is deriving ABI from the body.
- **`reorder`** — an index- or offset-derived identity fails this one. It is the
  anti-order-dependence case.
- **`private_other_domain`** — `corpus.helper::_privateHelper` and
  `corpus.app::_privateHelper` share a simple name across privacy domains. A map
  that confuses them reports app's caller as changed.

`field_added` carries a deliberate boundary: the *method* is unchanged, so the
fingerprints must say unchanged. Whether the owning class's layout change makes
the method unsafe to reuse is a **separate question owned by SM1-G5**, and must
not be smuggled into the fingerprints.

Four dimensions from the tracker are **contract-level, not source mutations**, and
are recorded as owned elsewhere: retention withheld (G4), capability withheld and
`can-be-overridden` withheld (G5), map/release identity mismatch (G6).

## Recorded as historical, not reinterpreted

Wonderous **50.00%** and LocalSend **92.67%** are **Route B producer-demand
baselines**, measured for a different question. The freeze records their scope
explicitly so no later gate reads them as semantic-map quality scores.

## Confounds recorded now, for the gates that will hit them

1. **`PLATFORM_LIBRARY_GUARD_IS_UNCOMMITTED`** (G3) — the guard refusing
   `--resolve-private-names-in-library` on a platform library is
   uncommitted-but-shipped source, present in `7b04b01b` and absent from a clean
   checkout of `9e8c898a`. A gate built from the wrong tree makes that arm pass
   vacuously.
2. **`ANALYZER_BUILD_TREE_DIVERGENCE`** (recorded here) — above.
3. **`VM_ENTRY_POINT_RETAINS_INDEPENDENTLY`** (G4) — `@pragma('vm:entry-point')`
   retains regardless of the contract; SEMANTIC-LINKER-1's
   `missing_retained_import` control passed while measuring the pragma.

## Verification re-hashes every frozen input

`frozen_inputs` in the manifest is **the** inventory — 34 entries: 4 reference
implementations, 2 real-world corpus pins, the supported record, and 27
adversarial-corpus files. `--verify` iterates that list and re-hashes each one;
it keeps no separate inventory to drift from it.

**This closes a real gap.** The first version recorded digests for the reference
tools and corpus pins and then checked only their **existence**, so a one-byte
edit to `gen_target_manifest.dart` still printed `G0 FREEZE VERIFIED`. A freeze
that records a digest it never compares is decorative.

Falsified per input class, each caught:

    gen_target_manifest.dart   caught      wonderous.window.txt   caught
    SUPPORTED_STATE.yaml       caught      corpus/base/helper.dart caught

## Parity runs clean, against the analyzer the cell ships

    coverage parity: 8 passed, 0 failed        EXIT=0

    ANALYZER pinned to 67741a08…  (the shipped cell artifact)
    parity.sh's build-tree default 18862acd…  was NOT used

Transcript: [`evidence/parity_shipped_analyzer.txt`](evidence/parity_shipped_analyzer.txt).
Eight cases — `added_member`, `dispatch_table`, `instance_method`,
`mixed_rejection`, `private_accessor`, `static_function`, `tearoff_closure`,
`unreachable_target` — comparing the shipped analyzer against both untouched
reference implementations on changed-target set, target identity, representable,
conditional and rejected sets, **the exact rejection reason for each**, and the
whole-patch verdict.

Given the analyzer divergence above, running this against the default would have
proved agreement for an artifact the product does not use.

## The release-dill mutation arm

The arm #49 actually specifies:

    frozen source + frozen toolchain
      -> build base release dill      fe114c0f64be…
      -> mutate ONE declaration       (body_only: return x + 1 -> x + 2)
      -> rebuild                      f0944ebc7760…
      -> digest MUST differ           ✔
      -> frozen verification refuses  ✔

### The refusal is exercised, not asserted

Banked in [`evidence/fail_closed_proofs.txt`](evidence/fail_closed_proofs.txt) —
run through the same verifier, with exit codes:

    1. baseline                                  G0 FREEZE VERIFIED   exit=0
    2. SKIP_DILL=1 --verify                      FAILED: 2 check(s)   exit=1
    3. DILL_SOURCE=mutants/body_only --verify    FAILED: 1 check      exit=1
         release dill does not match the frozen identity:
         fe114c0f64be != f0944ebc7760
    4. restored                                  G0 FREEZE VERIFIED   exit=0

**Case 2 closes a fail-open.** `SKIP_DILL=1 freeze.sh --verify` used to print
`G0 FREEZE VERIFIED` while skipping the one proof #49 specifies: the verifier
reported the dill as unverified without incrementing failures. A fail-closed
freeze does not offer an opt-out of its own mandatory check, so both a *skipped*
proof and a manifest carrying *no* release identity are now failures.

**Case 3 is isolated on purpose.** `DILL_SOURCE` points the rebuild at a mutant
while leaving every frozen corpus file untouched, so all 34 input hashes still
pass and the **only** failing check is the release identity. Mutating the corpus
on disk would have failed the input hashes too, and the transcript would not show
which refusal fired.

**Its confound is controlled first, every run:** "the digest differs" proves
nothing unless a rebuild of the *same* source is deterministic. Two builds of the
base produce an identical digest, and that control runs on every invocation
rather than being asserted once.

That control immediately earned its place. The first builder used a fresh
`mktemp` directory per call, and the package `rootUri` is a `file://` URI baked
into the dill — so every build was unique and the control failed for a reason
with nothing to do with the compiler. The builder now uses a stable path.

Worth carrying to G1: the `reorder` mutant **also** moves the dill digest,
because a dill preserves declaration order. That is precisely why
`DECLARATION_ID` must not be derived from dill ordering.

The source-corpus mutation is kept as a **supplementary** control — cheap, and
independent of the toolchain.

## The freeze is falsifiable

The freeze is a function of the bytes, not of a recorded label, and every input
class was mutated in turn and caught (above). `freeze.sh` also carries its own
arms — the release-dill rebuild and the scratch-copy corpus mutation — so a
freeze that had become decorative would report it rather than pass.

## A vacuous check caught during authoring

The first corpus validation ran `dart analyze --no-fatal-warnings
--no-fatal-infos`, reported **0 errors for all 13 programs**, and was wrong: this
Dart rejects those flags and printed usage instead of analyzing. The positive
control — a deliberately broken copy — was **not caught**, which is what exposed
it. With the correct invocation the base program turned out to have a real error
(`const` constructor with a non-final field); base and all mutants were
regenerated and are now clean under a check proven able to fail.

## Acceptance

- [x] Every input recorded with a digest **and re-hashed on verify** — 34 inputs
- [x] Reference implementations frozen, unmodified, identified by digest, and their **parity harness runs clean (8/8) against the shipped analyzer**
- [x] A mutated **release dill** changes the frozen release identity, with determinism controlled first
- [x] The verifier **refuses** a mutated dill, exercised end-to-end and banked with its nonzero exit
- [x] The mandatory dill proof **cannot be skipped** on `--verify`; a skipped proof and an incomplete freeze are both failures
- [x] Producer-demand baselines recorded as historical, with their scope
- [x] No supported artifact, selector or cell modified

## What G1 inherits

- Build from effective tree `7b04b01b`, not from `9e8c898a`.
- Pin `ANALYZER=` to `67741a08…`; the build-tree default is a different file.
- The twelve mutants and their declared expectations are the substrate; `reorder`
  is the one that fails an order-derived identity, and G1 owes a deliberately
  index-derived control to prove its harness can detect that failure.
- `reorder` moves the release-dill digest too, so dill order is not a safe basis
  for `DECLARATION_ID`.
- Build corpus dills with `lib/build_corpus_dill.sh`; a fresh temp path per build
  makes them non-reproducible.
