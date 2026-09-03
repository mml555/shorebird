<!-- cspell:words localsend wonderous tearoff prober cand -->

# D-DEMAND-3 — current-stack refusal attribution

2026-09-03. Host only. **No capability was implemented, no cell minted, no
release cut, no device run.** The corpus was not re-selected: same windows,
same pairs, same frozen dills, same generated-code exclusion, same weighting as
D-DEMAND-1 / D-PRODUCER-DEMAND-2.

## Control 1 — the headline reproduces on a FRESH replay

Required before any blocker count may be interpreted. Not taken from the D2
cache: `demand3_replay.sh` re-ran every pair through today's committed
producer, and `verify_supported_state.sh` first confirmed that repo HEAD's
`packages/shorebird_cli` tree equals the qualified revision's (24 checks, all
ok). Repo at `ef8f1dc0`, clean — no bootstrap-stamp trap.

| corpus | observations | producer accepts | compatibility | recorded in `SUPPORTED_STATE.yaml` |
|---|--:|--:|--:|--:|
| Wonderous | 20 | 10 | **50.00%** | 50.00% |
| LocalSend | 232 | 215 | **92.67%** | 92.67% |

Refusal sets are **byte-identical** to D2's, pair by pair. Generated-code
filtering intact: 21 LocalSend observations excluded (slang `.g.dart` plus 7
flutter_rust_bridge), 0 Wonderous — so the denominators are the frozen 20 / 232.

## Instrument

`selfhost/engine/route_b/coverage/demand3_blocker_chain.dart` — new; the frozen
`demand_replay_refusal.dart` was not touched, so the control above is a
like-for-like reproduction.

It deliberately does NOT live under `packages/shorebird_cli/tool/`, where it was
first written. `SUPPORTED_STATE.yaml` freezes that package's git **tree**
object, and `verify_supported_state.sh` failed with a product-tree drift whose
whole content was this one harness file. Restamping a qualification record to
accommodate a measurement tool would blunt the one check that catches real
product drift, so the tool moved instead, restoring the qualified tree
`e3ebed51cabcc05423b85b4ea4b146fc734a5413` exactly. Run it from the repo root
with `dart --packages=.dart_tool/package_config.json run …`.

It asks the shipping producer about **one target at a time**, records the
refusal, applies the one *relaxation* that models that refusal, and asks again
— until the target is admitted or the refusal is one no relaxation models.

A relaxation edits the INPUT DOCUMENTS this harness feeds the producer. None
edits the product and none disables a gate: after `constructs` is relaxed, the
capability, reachability, signature and super gates all still run and still
refuse. Two exist:

* `constructs` — empty that target's `lowering.unsupported`. Models the lowering
  learning every shape the analyzer flagged.
* `capability` — union the release manifest with the private keys the body
  names. Models a **retention-policy** change, not a patch-time grant.

**Why every count here is an upper bound.** No compiler cell is supplied
(deliberately: D2 recorded that compiling against a mismatched platform dill
produces mass `exit 254` that measures the mismatch), and release
binding/signature evidence and the survival oracle do not exist for a
historical commit. Admission is what is measured, not compilation.

## The answer: solve exactly one blocker

Observations that become producible, **per corpus, never pooled**:

| Candidate | Wonderous | LocalSend | Replicated? | Class | New safety surface |
|---|--:|--:|:--:|:--:|---|
| private method/top-level/type reference | **1** | **1** | **yes** | **A** (see below) | moderate — the fix ADDS structured evidence rather than weakening the gate |
| retention / release evidence | **1** | **1** | **yes** | B | low — cost is retention breadth, no new lowering |
| compound read+write at one offset | 0 | 2 | no | A | moderate — one edit must become two |
| named parameters | 0 | 1 | no | A | high — calling convention; a mismatch binds and misbehaves |
| optional positionals | 0 | 1 | no | A | high — same ABI surface |
| method tear-off / this-escape | **0** | 1 | no | A | high — same rewrite class that shipped the 2026-08-25 `'$_count'` render bug |
| receiver rewrite | 0 | 1 | no | A | highest — the gate exists because a wrong rewrite compiles and misbehaves |
| candidate-introduced private construction | (1) | 0 | no | **C** | **not a candidate** — refused by design (D2); solving it means loosening a fail-closed rule |
| reachability | 0 | (2) | no | **C** | not a candidate — the release cannot reach the member |

Parenthesised counts are refusals that exist but are **not** capability gaps.

### Sole-blocked vs multi-blocked

| corpus | counted refused | admits in its own pair | sole-blocked | multi-blocked |
|---|--:|--:|--:|--:|
| Wonderous | 10 | 1 | 3 | 6 |
| LocalSend | 17 | 1 | 11 | 5 |

## The load-bearing proofs

The leading refusal category in each corpus was tested by removing it and
asking what refuses next.

**Wonderous's leading category is NOT load-bearing.** `unconsumed_this`
(the census's `method_tearoff` + `this_escape`, one producer gate split by AST
parent kind) touches **7 of 10** Wonderous refusals. Relaxed, **six of them land
immediately** on the private-reference text backstop, naming the very handler
being torn off:

| method | after relaxing the construct gate |
|---|---|
| `_RangeSelectorState.build` | names `_handleMidDrag` |
| `_FullscreenVideoViewerState.initState` | names `_handleKeyDown` |
| `_ArtifactScreenState.build` | names `_handlePageChanged` |
| `_CollectionListState.build` | names `_CollectionList` |
| `_WonderEventsState._buildTwoColumn` | names `_handleScroll` |
| `_RangeSelectorState._getHandle` | names `_handleRightDrag` (and also needs named parameters) |

**Method tear-off, implemented alone, would unlock 0 of 20 Wonderous
observations.** That is the single most important number in this lane, and it is
the opposite of what the static census ranking implies.

The mechanism is not a coincidence: the tear-off **is** the private reference.
`onDrag: _handleRightDrag` lowers to `self._handleRightDrag`, so the capability
necessarily includes emitting a resolved reference to the torn-off private
member.

**LocalSend's leading category is load-bearing in 1 of 4.**
`abi.named_parameters` touches 4 refusals. `ServerService.restartServer` admits
once relaxed; all three `ServerService.startServer` observations land on
`receiver_rewrite` (`reads \`_syncServerState\` through a receiver this lowering
cannot rewrite safely`).

## The measurement that corrects the engineering class

For every private-reference backstop refusal, was the named member **already
retained** by that release's own manifest?

**8 of 11: yes.**

    _handleRightDrag  _handleMidDrag  _handleKeyDown  _handlePageChanged
    _handleArtifactTap  _handleScroll  _toggleAdvanced  _advancedProgressPanelExtraPadding
      ... all present as privateInstanceCallable / privateTopLevelCallable
    _CollectionList   present as privateClassesConstructible (`_CollectionList.new`)

So the missing piece is the **analysis resolving the reference structurally**,
not the release retaining it: `granted` in `_lower` is built only from
`lowering.accesses` entries carrying a private target, and these names never
arrive as one. **This candidate is class A, not B/A.** The release evidence is
already banked.

The two exceptions are real and are counted as needing both:
`_advancedProgressPanelExtraPadding` is retained at release `af0416be` (200
private top-levels) and **not** at `deab2010` (197) — one observation each way.

## The paired case, which is TWO blockers and reported as such

Because tear-off and private-reference resolution are not separable in
practice, the combination is the only move that changes Wonderous materially:

| corpus | observations unlocked | resulting producer compatibility |
|---|--:|--:|
| Wonderous | 6 | 10 → 16 of 20 = **80.00%** |
| LocalSend | 5 | 215 → 220 of 232 = **94.83%** |

94.83% is exactly LocalSend's analyzer upper bound, so on that corpus the pair
closes the whole producer-side gap. Every Wonderous member involved is already
retained; one LocalSend observation additionally needs a retention change.

This is **not** a one-blocker unlock and must not be read as one.

## A methodology artefact, stated because it moves a number

Two observations counted refused by the frozen accounting are **admitted by the
producer in their own pair**: Wonderous `AppBtn.build` at `56086308_002e1272`
and LocalSend `_ProgressPageState.build` at `4b5236ce_63efbe6b`. The frozen
methodology counts a target refused in ANY pair as refused in EVERY pair it
appears in — documented in D2 and applied identically in D1. Per-observation the
figures would be Wonderous 11/20 = 55.00% and LocalSend 216/232 = 93.10%.

**The headline is unchanged.** Control 1 required reproducing the frozen
50.00% / 92.67%, and it does. This is recorded so the 10 and 17 are read as what
they are.

## Category D: zero survive, and two were caught

No refusal in the final measurement is infrastructure or unavailable historical
evidence. Two were found and **eliminated as harness artefacts** rather than
reported as product limits:

1. **No patched verification kernel.** The producer refuses an admitted `super.`
   site when none is supplied. The corpus has the candidate kernel on disk
   (`dills/<cand>.dill`); supplying it removed the refusal. Left in, a real
   A-class blocker would have read as multi-blocked behind a harness gap.
2. **The harness's fake compiler advertised no super capability.**
   `_unusableCompiler` defaults `supportsDirectSuperDualKernel` to false, so
   every admitted `super.` site refused with "this release resolves a compiler
   cell that does not implement routeBDirectSuperDualKernelV1". Fixed with a
   **measured** basis, not an assumption: the frozen cell's own dart2bytecode
   `--help` advertises `--patched-verification-dill`, so the flag is passed
   explicitly via `--super-capable`.

A third D-class refusal — `WebParams.get:hashCode`, "its parameter list could
not be found" — is in flutter_rust_bridge generated code and is excluded by the
generated-code filter, confirming the filter is doing its job.

## Three harness defects this lane caught, each of which inflated the answer

1. **A resume guard treated a truncated file as done.** The first fresh replay
   was killed by a timeout mid-pair, leaving a 0-byte output; the next run
   skipped it as complete. An empty replay reports no refusals, so those
   observations would have counted as producer-accepted and LocalSend would have
   read too high. Found by diffing every refusal set against D2. The script now
   has no resume guard and asserts that every output reached its verdict line.
2. **The chain prober reported ADMITTED on an empty set.** `produce` builds its
   selector list from `representable + conditional` and never reads `changed`.
   A guard written against `changed` let four observations through that are in
   `changed` only — they are refused for **reachability** and the producer never
   gates them. Reporting those as unlocks would have inflated exactly the number
   this lane exists to produce. The guard now checks the walked sets, and such a
   target reports `not_walked`.
3. **A synthetic access produced a false unlock.** An earlier model of
   "resolution" injected a synthetic private access to clear the text backstop.
   Accesses drive text edits **by offset** (`text.replaceRange(offset -
   span.start, …)`), so the synthetic offset of 0 gave a negative index, a
   `RangeError`, and the tool's catch-all counted the crash as PAST_ADMISSION.
   Removed. The backstop needs no model: it is the **last** admission gate —
   `_lower` returns immediately after it — so a chain ending there has nothing
   further to hit, which is a fact about the code rather than a simulation.
   Every surviving ADMITTED verdict was verified to be
   `PAST_ADMISSION(ProcessException)`, i.e. reaching the absent compiler; 0 are
   anything else.

## What this lane did NOT do

No capability implemented. No fail-closed rule loosened — the
candidate-introduced private construction refusal and the reachability refusals
are reported as class C and excluded from every unlock count. No corpus
substitution, no re-selection, no re-weighting. D-TEAROFF not started.

## Reproduction

    selfhost/engine/route_b/verify_supported_state.sh          # 24 checks
    selfhost/engine/route_b/coverage/demand3_replay.sh         # fresh replay -> producer14
    selfhost/engine/route_b/coverage/demand3_shadow.sh         # shadow dirs -> d3
    python3 .../producer_report.py --corpus 'Wonderous|.../d3/wonderous' \
                                  --corpus 'LocalSend|.../d3/localsend'   # control 1
    python3 .../demand3_chains.py                              # chains.json
    python3 .../demand3_attribute.py                           # ATTRIBUTION.txt

Banked: `demand3_CONTROL.txt`, `demand3_ATTRIBUTION.txt`, `demand3_chains.json`,
`demand3_attribution.json`, and the four scripts.

| thing | value |
|---|---|
| repo revision | `ef8f1dc0` (clean) |
| cell | `cd848320d605ff8af5060cabf9a8d1b35853f752` |
| analyzer | v13, digest `67741a08…` |
| corpus | D-DEMAND-1's, unmodified; 20 Wonderous / 232 LocalSend |
