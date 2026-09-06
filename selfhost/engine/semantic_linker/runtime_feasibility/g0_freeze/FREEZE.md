<!-- cspell:words dartaotruntime localsend wonderous dill semantic linker gcs -->
# SL1-G0 — the frozen baseline, and what freezing it found

**Gate:** [#37](https://github.com/mml555/shorebird/issues/37) · **Tracker:** [#36](https://github.com/mml555/shorebird/issues/36)
**Run:** 2026-09-06 · **Verdict: FROZEN, with one durability finding carried forward.**

Machine-readable form: [`freeze_manifest.json`](freeze_manifest.json).
Re-check it with `freeze.sh` (default `--verify`); rewrite it only with `--emit`.

## What the gate asked

Freeze the exact `selfhost-v1.1.1` distribution **and the actual engine/Dart
source bytes** SEMANTIC-LINKER-1 will build from. The second half is the part
that matters: G1 has to rebuild that lineage twice, Dynamic Modules off and on.
A lineage nobody can reconstruct is not a baseline, however precisely its commit
is recorded.

## The baseline matches, exactly

Every identity the tracker names was read out of the record **at the tag**, from
the committed blob rather than the working tree — the working copy has since
moved to `5cc178ef`, and surviving that drift is the point.

| | expected | found |
|---|---|---|
| tag → commit | `bdb234ab` | `bdb234ab` ✅ (annotated tag; `rev-parse selfhost-v1.1.1` returns the **tag object** `315d3643` — not a mismatch) |
| CLI | `46ee70af` | `46ee70af` ✅ |
| Flutter selector | `5b180d22` | `5b180d22` ✅ |
| cell | `f85251f3` | `f85251f3` ✅ |
| producer engine | `dfa2b24a` | `dfa2b24a` ✅ |
| Dart | `9e8c898a` | `9e8c898a` ✅ |

The stop condition — "if the tag or recorded identities do not match the expected
immutable baseline, stop and report" — is **not tripped**.

## Supported-state verification passes against the detached worktree

`verify_supported_state.sh`, unmodified, run from a detached worktree at
`bdb234ab`: **SUPPORTED STATE VERIFIED**, 0 failures.
Transcript: [`evidence/verify_supported_state.txt`](evidence/verify_supported_state.txt).

Two things had to be supplied to the worktree, and neither is part of the frozen
identity — both are untracked stores that live outside git:

- `bin/cache/{flutter,artifacts}` — symlinked read-only to the qualification
  rig's cache. The rig was not modified.
- `selfhost/cdn/overlay/*` — symlinked read-only to the main checkout's overlay
  (12 GB, `.gitignore`d, 53 cells).

The first run without them reported 4 failures, all of them "no published
compiler archive". That is the verifier behaving correctly — **missing evidence
is never a pass** — and it is worth stating that the frozen worktree alone does
not carry the artifacts it verifies.

## Finding 1 — the producing Dart tree is DIRTY, and the dirt shipped

`dart_revision: 9e8c898a…` does **not** identify the source that produced the
supported cell. The producing checkout carries one uncommitted modification:

    M pkg/front_end/lib/src/source/source_loader.dart     +15 lines, mtime 2026-08-25

It is a guard that makes the CFE refuse
`--resolve-private-names-in-library dart:core` — a platform library — throwing
rather than widening private-name resolution into the platform. Substantively it
is a *good* change; the problem is that it is nowhere in git, and it is in the
shipped bytes.

**Proven, not assumed.** The guard's own message string is present in the
published `dart2bytecode.aot`:

    ', which is a platform library. This option may only name an application
    library: it exists so generated code can act as part of the library it
    replaces a member in, not to widen resolution into the platform.'

And the probe was made falsifiable before it was believed. The first cut ran
`grep -F` straight at the binary and found **neither** the guard **nor** a
positive control (`resolvePrivateNamesInLibrary`, `SourceLoader`) — it would
have "cleared" the tree while being incapable of finding anything at all.
Extracting with `strings` first makes the control hit; only then does the
subject's presence mean something. `freeze.sh` re-runs both, and fails the whole
freeze if the control ever goes missing.

Consequence: provenance for this cell may not be claimed from the commit alone,
which is exactly what the gate said.

## Finding 2 — that Dart lineage exists on ONE DISK

`9e8c898a` is advertised on no remote. Its own checkout names
`file:///Volumes/build/ios-engine/dart-sdk` as `origin`, and **the commit is not
in that clone either** — only its two ancestors are. Nothing on
`shorebirdtech/dart-sdk` (unreachable), nothing on any `mml555` mirror.

The engine side is fine by contrast: `dfa2b24a` is on
`mml555/shorebird-flutter` at `refs/heads/route-b-2c-candidate` and the
annotated `refs/tags/acs2-macos-ios-producer`, and its tree object `26acc7f4`
fetched from that remote **equals** the local checkout's tree.

This is the same class of defect [`NEXT_LANES.md`](../../../../NEXT_LANES.md) §4
already recorded once for the updater fork. It is recorded here, not repaired
here: pushing a Dart fork is not inside this gate's stop boundary.

## What was banked, and how the bank was checked

[`banked_source/dart/`](banked_source/dart) — 2,116 insertions across 22 files,
the whole Route B Dart SDK support:

| file | content |
|---|---|
| `0001-Add-snapshot-size-accessors-for-code-push.patch` | commit `6b58bb3a` |
| `0002-Route-B-Dart-SDK-support-bytecode-producer-and-the-t.patch` | commit `9e8c898a` |
| `9999-worktree-uncommitted.patch` | the uncommitted guard |

Applied to the vanilla base the engine's own `DEPS` pins
(`dart_revision d684a576`, i.e. Dart 3.12.2):

    base tree      4e9377df
    + 0001 + 0002  aa55ff96   == the producer's committed HEAD tree      ✅
    + 9999         7b04b01b   == the producer's EFFECTIVE tree           ✅

**`7b04b01b` is the real identity of the source that built the cell.** Tree
objects, not ancestry and not commit messages ([[ancestry-is-not-identity]]).
The producer's own index was never touched — the comparison used a temporary
`GIT_INDEX_FILE`.

The replay is re-run by `freeze.sh` on every verify. Mutating a single character
of the banked delta (`platform library` → `platform librarY`) makes it fail with
`got f4c71537…`, so the check is not vacuous.

## Carried forward, unchanged

- **Qualification**, referenced not rewritten: iOS iPhone 7 / iOS 15.8.8,
  2026-09-03, release 142 / patch 106-1; Android CPH2551, 2026-09-04
  (`evidence/android-final-stack-2/RESULT.md`).
- **Producer-demand baseline**: Wonderous **50.00%**, LocalSend **92.67%**
  (`evidence/producer_demand_2.md`). Not re-measured.
- **Corpus pins**: `coverage/demand1/{wonderous,localsend}.window.txt`, digested
  in the manifest. A fresh replay is optional and must never substitute newer
  app revisions.
- **`coverage/baseline_a.json` is VOID** and is not used — minted from an engine
  tree carrying 18 uncommitted files, retracted in `COMPATIBILITY_STUDY.md`.

## Acceptance

- [x] Tag resolves to the expected commit
- [x] Supported-state verification passes against the detached tag worktree
- [x] Freeze manifest contains both commit and actual source-tree provenance
- [x] Dirty source banked and cryptographically identified — and replay-checked
- [x] Physical qualification and corpus baselines referenced without rewriting history
- [x] No supported artifact or selector changed

## What G1 inherits

1. Build from **`7b04b01b`**, not from `9e8c898a`. The bank is how you get there.
2. The engine's untracked `.gcs_entries` names a prebuilt host SDK
   (`db98bdaa…/dart-sdk-darwin-arm64.tar.gz`) that is a real build input.
3. `engine/src/out/host_release_arm64_nodm` already exists on the build box — a
   Dynamic-Modules-OFF tree from this lineage. G1 must establish whether it was
   built from this exact source before treating it as the control, not assume it
   ([[stamps-are-not-bytes]]).
