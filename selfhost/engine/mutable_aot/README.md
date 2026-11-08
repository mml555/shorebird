<!-- cspell:words patchability unmodeled UNMODELED MAOT -->

# Mutable-AOT — 100% Dart patchability on a maintained Dart/Flutter fork

Program epic: **#62**. Implementation backlog: **#63 – #77**.

## What this program is, in one paragraph

Patchability becomes a **compiler- and runtime-owned contract** instead of a
property inferred from finished AOT machine code. The CFE assigns stable
declaration and type identity; the AOT compiler knows which declarations are
mutable *before* optimization; every supported call form reaches a
runtime-owned implementation mechanism or carries a dependency that patch
installation can mechanically invalidate; and the runtime switches an existing
declaration to a replacement atomically.

The architecture it replaces is the one that reads:

    compile arbitrary AOT -> inspect machine code afterward -> guess what can be replaced

## Why it exists

The semantic-map work and **#61** established, mechanically, that post-AOT
inference cannot prove universal patchability. #61 closed at
`VALIDATION_INPUT_UNDERIVED`: the validator works given a complete
specification, and no complete specification is derivable from any source in
the fork. Route B remains useful as evidence and possibly as an execution
backend for replacement code. It does not define the architecture.

## Layout

| directory | issue | what it holds |
|---|---|---|
| [`maot0/`](maot0) | **#63** | the authoritative compatibility matrix, the contract, the frozen construct universes, and the gate that refuses a 100% claim |
| [`t0/`](t0) | **#64** | the fixture corpus, the run harness (optimizer/heat/dispatch modes), and the fifteen adversarial controls |
| [`m1/`](m1) | **#65** | stable declaration and type identity: the cases, detectors and arms that gate the scheme living in the Dart fork |

Later issues add their own directory and **consume `maot0/matrix.json`** rather
than maintaining a second list of what must work.

## The Dart fork

From #65 onward the compiler changes live in a durable fork, not in this repo:

    repository  mml555/dart-sdk-shorebird-lineage
    branch      maot/identity          (transport, not provenance)
    baseline    9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c

Branch names move; provenance is repository plus full commit and tree sha, and
every lane records both. A push is not durable until the branch has been
FETCHED BACK independently and its tree sha compared -- `run_m1.sh` does that
on every run rather than trusting that a push printed progress.

## The rules that apply to every issue here

* **Report per axis, not per row.** Each row has four independent columns —
  code representability, dispatch correctness, live-state compatibility,
  semantic migration. "This issue is done" is not a recordable claim.
* **`PROVEN` needs evidence.** A row may only reach `PROVEN` with an executable
  gate id and an evidence file whose digest matches. The gate checks both.
* **No percentage is a closure gate.** Coverage may be reported; the aggregate
  is a conjunction over every in-scope row and compares against no threshold.
* **Advance the lock deliberately**, in the commit that supplies the evidence.
  `matrix.lock.json` exists so a row cannot move toward supported quietly.
* **An architectural contradiction is a finding, not a failing test to force
  green.** If evidence shows an issue's assumed architecture cannot reach the
  goal, stop at the invalid assumption and report it.

## Running the MAOT-0 gate

```bash
cd selfhost/engine/mutable_aot/maot0
./run_maot0.sh                    # gate; exits non-zero on any blocking finding
./run_maot0.sh --accept-lock      # advance matrix.lock.json, then re-gate
DART_TREE=<path> ./run_maot0.sh   # also re-derive the frozen universes
```

It needs Python 3 and nothing else. The construct universes are frozen into the
repository with the Dart tree's full SHA and per-file digests, so the gate runs
without a Dart checkout and without the external build disk.
