<!-- cspell:words dartaotruntime dill semantic localsend wonderous -->
# SM1-G0 — frozen inputs, corpus and reference implementations

**Gate:** [#49](https://github.com/mml555/shorebird/issues/49) · **Tracker:** [#48](https://github.com/mml555/shorebird/issues/48)
**Run:** 2026-09-06 · **Verdict: FROZEN. One finding recorded before it could mislead a later gate.**

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

## The freeze is falsifiable

    baseline                          G0 FREEZE VERIFIED
    one comment appended to base      FAILED  adversarial corpus digest unchanged…
                                              expected 4a85fcc2…, got 89a6d016…
    restored                          G0 FREEZE VERIFIED

The freeze is a function of the bytes, not of a recorded label. `freeze.sh` also
carries its own adversarial arm: it mutates a scratch copy of the corpus every
run and requires the digest to move, so a freeze that had become decorative would
report it.

## A vacuous check caught during authoring

The first corpus validation ran `dart analyze --no-fatal-warnings
--no-fatal-infos`, reported **0 errors for all 13 programs**, and was wrong: this
Dart rejects those flags and printed usage instead of analyzing. The positive
control — a deliberately broken copy — was **not caught**, which is what exposed
it. With the correct invocation the base program turned out to have a real error
(`const` constructor with a non-final field); base and all mutants were
regenerated and are now clean under a check proven able to fail.

## Acceptance

- [x] Every input recorded with a digest or immutable revision
- [x] Reference implementations frozen, unmodified, and identified by digest
- [x] Mutated input changes the freeze record — demonstrated in both directions
- [x] Producer-demand baselines recorded as historical, with their scope
- [x] No supported artifact, selector or cell modified

## What G1 inherits

- Build from effective tree `7b04b01b`, not from `9e8c898a`.
- Pin `ANALYZER=` to `67741a08…`; the build-tree default is a different file.
- The twelve mutants and their declared expectations are the substrate; `reorder`
  is the one that fails an order-derived identity, and G1 owes a deliberately
  index-derived control to prove its harness can detect that failure.
