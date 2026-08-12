# Real-patch compatibility study — scope

**Status: Phase 0 complete. Phase 1 ATTEMPTED AND BLOCKED on corpus
feasibility — the method needs a decision before it can run. See the end.** Analyzer frozen at **v6**, cell
`aa9155840d6c1e71b015bbcff1e06eaea7e73e17`.

## The question

> Of realistic Flutter code changes, what fraction can Route B patch today, and
> what actually causes rejection?

Frequency, not intuition, chooses the next widening work. The point of writing
the method down before running it is that an acceptance percentage is only
meaningful if the corpus was fixed first.

## What is frozen

Nothing in `route_b_producer.dart`, `coverage/analyze_coverage.dart`, or the
cell changes while the corpus runs. The harness **asserts** the analysis it
receives reports `analysisVersion == 6` and refuses to record a row otherwise,
so a mid-study rebuild cannot silently move the thing being measured.

`R7` stays unclaimed for the duration. If someone needs it, the study stops and
restarts rather than straddling two analyzers.

## Corpus

### Selection is mechanical and pre-registered

The filter is fixed before any case runs, and the **funnel is reported** —
candidates at each stage, and how many each rule removed. A rule that removes
most of the corpus is itself a finding.

Per source, in order:

1. commits touching `**/*.dart` under the app's own source root;
2. minus merge commits;
3. minus files matching `*_test.dart`, `*.g.dart`, `*.freezed.dart`,
   `*.mocks.dart`, `generated_*`, `l10n/`;
4. minus commits that also touch `pubspec.yaml`, `pubspec.lock`, `ios/`,
   `android/`, `macos/`, `windows/`, `linux/`, or `assets/` — dependency and
   native changes are out of Route B's scope by construction, not by preference;
5. minus commits changing more than **200 added+removed Dart lines** — the
   "large refactor" cut. The threshold is arbitrary and therefore declared;
   sensitivity to it gets reported.

Then take the most recent N surviving commits. **No inspection of the diff
contents before selection.** Nobody looks at whether a change is
Route B-friendly.

### Source 1 — this fork's history

453 commits since 2025-01-01 touch non-test Dart under `packages/`. Ample.

**Caveat that must travel with every number derived from it:** `shorebird_cli`
is a command-line program, not a Flutter app. Its shape skews toward top-level
and static functions, dependency-injected singletons, and `ArgResults` plumbing;
it has no widgets, no `setState`, no build methods. It will *understate* the
instance-receiver forms and *overstate* the static ones — the opposite of the
population we care about. It is included because it is real, versioned, and
guaranteed to compile in this rig, and it is a control, not the headline.

### Source 2 — a real Flutter app

Primary evidence. Requirements: real product history, ordinary commits, no
monorepo indirection, and a Dart/Flutter constraint the rig's toolchain
satisfies.

Candidate checked: **gskinnerTeam/flutter-wonderous-app** — 774 commits,
`sdk: ^3.11.5`, `flutter: ^3.41.9` against the rig's Flutter 3.44.8. Its recent
history is exactly the target population ("Updated cueVideoByUrl catch to
dumpErrorToConsole", "Added rethrow to try/catch for GoogleMap loadLibrary") —
small logic and error-handling changes that plausibly belong in code push.

Alternatives if it does not resolve: any single-package Flutter app with >300
commits and an SDK constraint the cell satisfies. **The app is chosen before the
commits, and the commit rule is the one above.**

## Method, per case

A case is one commit, treated as one patch, because whole-patch refusal is the
product's actual semantics.

```
checkout parent        ->  prepass.dill      (--aot, no interface)
                       ->  dynamic_interface.yaml
                       ->  base.dill         (--aot, WITH that interface)
checkout commit        ->  patched.dill      (--aot, with the BASE's interface)
route_b_analyze        ->  analysis.json
```

The interface is not optional and not an optimisation. Compiling without one
changes what the kernel says — `--aot` eliminates a parameter only ever passed a
constant, and a probe that skips the interface measures a compilation no release
performs. That error already cost one wrong paragraph in this repo; the harness
reproduces the release's own order.

Work happens in a **separate `git worktree`**, per `PARITY.md` §17. The app
clone lives outside the repo.

### Recorded per case

| field | |
|---|---|
| source, commit, parent, subject | |
| files, added/removed lines | |
| verdict | `accept` / refusal |
| changed / added / removed targets | counts and identities |
| accepted, conditional, unreachable, unknown targets | |
| per-target refusal reason | verbatim from the analyzer |
| form | one of the buckets below |
| whole patch publishable | boolean |
| **blocked-by-one** | patch rejected while ≥1 target was representable |
| `analysisVersion`, cell hash | freeze evidence |

### Form buckets

`static/top-level`, `getter/read`, `receiver call`, `call with arguments`,
`setter`, `compound write`, `super`, `private app member`, `cascade`,
`signature/arity`, `added member`, `removed member`, `dispatch-table unknown`,
`other`.

`other` is reviewed by hand and its count is always printed. A classifier that
silently buckets the unclassifiable into a known bin is the failure mode here —
the mapping from the analyzer's free text to a bucket is exact-match, and
anything unmatched stays `other`.

## Policy classification — three categories, not two

Every blocker is labelled with *why* it is refused, because the three imply
completely different responses:

| label | meaning | example |
|---|---|---|
| **architectural** | Route B cannot do this at all under the current model | added/removed member; a synthetic library naming another library's private member |
| **deliberate boundary** | could be built, decided not to | compound writes, `super`, cascades — see the frozen surface in `ROUTE_B.md` |
| **not yet widened** | no decision, simply unbuilt | whatever the corpus turns up that nobody has considered |

Compound writes are **deliberate boundary** as of 2026-08-11. A high count there
is an argument to revisit a decision, not evidence of an oversight — and it is
the category most likely to be misread if the label is not carried.

## Outputs

1. patch-level acceptance %, target-level acceptance %;
2. rejections by reason, and by form;
3. **blocked-by-one** count — patches killed by a single unsupported target
   while the rest were representable. This is the number that says whether
   whole-patch refusal is itself the dominant cost;
4. the ranked blocker table:

| blocker | occurrences | patches blocked | policy |
|---|---|---|---|
| … | … | … | architectural / deliberate / not-yet |

5. the selection funnel, and the count of cases that failed to compile.

## Cost, measured not guessed

One `gen_kernel --aot` of `shorebird_cli`: **90s warm** (22s CPU, 26% CPU
utilisation — I/O-bound on the build SSD, so it parallelises nearly linearly).

Four compiles per case → ~6 min serial, ~2 min at 3-way parallelism.

| | cases | serial | 3-way |
|---|---|---|---|
| pilot | 5 + 5 | ~1 h | ~25 min |
| full | 50 + 50 | ~10 h | ~3.5 h |

Background job. `R5` (the build SSD) is shared; three concurrent *kernel*
compiles are not an engine build, but if anyone starts one the study yields.

**Phase 0 is a 5+5 pilot** — validate the pipeline, the classifier and the cost
estimate before committing to 100 cases. If the pilot shows the reason strings
do not classify cleanly, that is cheaper to learn at 10 cases than at 100.

## Threats to validity — stated in advance

- **Commit granularity is not patch granularity.** A commit may bundle a fix
  with unrelated cleanup, so patch-level acceptance understates what a developer
  shipping one deliberate fix would see. Reported alongside target-level
  acceptance, which does not have this problem, and the gap between them is
  itself informative.
- **Historical build fragility.** Older commits may not resolve. The window is
  kept recent to limit drift, and failures are reported as an exclusion count,
  never silently dropped.
- **Source 1 skew**, above.
- **One app is one codebase.** House style — one team's habits around getters,
  cascades, or `late` — will show up as if it were a property of Flutter.
  A second app is the cheap way to test that, and is out of scope until the
  first result justifies it.
- **A predicted result, recorded now so it cannot be retrofitted:** the dominant
  blockers are expected to be *structural* — added and removed members, and
  changed signatures — rather than the lexical forms the rungs have been
  widening. If that is what the data says, the honest conclusion is that further
  lexical widening has low value, and the interesting question moves to whether
  Route B can ever add a member.

## Not in scope

No analyzer or producer changes. No device work. No new rungs. No fix for
anything the study finds — the study's output is a ranked table, and what earns
a design project is decided after reading it.


---

# Phase 0 results — 10 cases, 2026-08-11

Analyzer v6, cell `aa9155840d6c1e71b015bbcff1e06eaea7e73e17`, unchanged
throughout. Rows: `compat_phase0_rows.jsonl` (each keeps the analyzer's verbatim
output). Harness: `compat_study.py`, reclassifier: `compat_reclassify.py`.

## The headline

**0 of 10 patches are publishable.** The analyzer's verdict alone would have said
5 of 10 — see "the verdict is not publishability" below.

| blocker | occurrences | patches | policy |
|---|---|---|---|
| private app member | 39 | 9 | architectural |
| signature/arity | 8 | 6 | architectural |
| added member | 5 | 4 | architectural |
| `this` escape (incl. cascade) | 3 | 3 | deliberate |
| `super` | 2 | 2 | deliberate |
| removed member | 1 | 1 | architectural |
| **compound write** | **0** | **0** | deliberate |

53 of 58 blocker occurrences are **architectural**. Five are deliberate
boundaries. **Compound writes did not occur once**, and `super` twice.

On this evidence the frozen boundary is not what is costing anything, and
neither compound writes nor `super` has earned a design project. That was the
question the study existed to answer, and ten cases answer it clearly enough
that widening further would be work chosen against the data.

## The pre-registered prediction, scored

Recorded before running: *the dominant blockers will be structural — added and
removed members, and changed signatures — rather than the lexical forms the
rungs have been widening.*

**Right in direction, wrong in detail.** Structural causes do dominate
(architectural 53/58), and signature and added-member are second and third. But
the largest single blocker was one the prediction did not name: **private app
members**, in 9 of 10 patches.

Two distinct things drive it, and they should not be conflated:

* a replacement library cannot name another library's private members at all
  (rung D) — so a body that touches any `_field` or `_method()` is out;
* **in Flutter, the State class itself is conventionally private.** Seven of the
  fourteen blocked emit-targets were methods of `_FullscreenVideoViewerState` —
  `initState`, `build`, `onKeyDownEvent`. Idiomatic `StatefulWidget` code is
  private by convention, which collides with the synthetic-library model for
  reasons that have nothing to do with syntax.

Second-largest is **signature/arity**: *"the method takes parameters; the single
allowed entry-point parameter is the receiver"*. Any instance method that takes
arguments of its own is unpatchable, because the receiver already consumes the
one positional slot the entry-point contract allows. That is an ABI limit the
fork has already moved once (0 → 0-or-1) and could move again.

## The verdict is not publishability — a product finding

The coverage verdict says `accept` for patches the producer then refuses. It is
computed from unreachable / unknown / added targets and **does not consider
whether a representable target can actually be lowered**.

Five of ten cases were `accept` with an unlowerable target in the emit set. The
product is still safe — the producer throws and the whole patch is refused — but
it refuses *later*, and the coverage refusal summary names a different reason
than the real one. Any tooling that trusts the verdict overstates acceptance,
which this study did until the pilot caught it.

Not fixed here: the analyzer is frozen, and this is a finding, not a defect to
patch mid-study.

## Phase 0 exit check — 3 of 4 clear

| condition | |
|---|---|
| analyzer v6 unchanged | **clear.** Verified byte-identical to the published cell before and after |
| classified without reading source to interpret output | **clear.** 0 unclassified of 58 blockers, exact-match against the closed set |
| no case-specific categories invented | **clear.** The taxonomy that ran is the one that was scoped |
| corpus selection unchanged after seeing results | **NOT CLEAR** |

The fourth failed, and honestly: the first fork run selected the five most recent
commits, which were **this session's own Route B commits**. `--exclude-path
route_b` was added after seeing that. The change made results worse rather than
better, so it was not curation toward friendliness — but the rule is the rule,
and a selection edited mid-run is exactly what the rule exists to prevent.

**Consequence: Phase 1 re-runs both sources from scratch under the final rule.**
No Phase 0 row is carried forward as a result.

## What the pilot found about the harness — all fixed

* **A silent `git checkout` failure is indistinguishable from a real result.**
  `flutter pub get` rewrites the tracked `pubspec.lock`, so checkout refused;
  the exit code was not checked; both compiles ran on the same tree; the dills
  were identical and the analyzer honestly reported `inert`. Four of five app
  cases looked like a finding about Flutter and were a bug here. Now: `-f`, the
  resulting HEAD is verified against the requested rev, and a
  base/patched byte-identical pair is recorded as `identical_kernels` rather
  than being allowed to masquerade as `inert`.
* **Worktrees must be leased, not assigned by index**, or two concurrent cases
  check out over each other.
* Preserving `raw` paid for itself immediately: the publishability correction
  was applied to ten existing rows by `compat_reclassify.py` in under a second,
  with no kernel recompiled.

## Answers to the five Phase 0 questions

1. **Do v6 refusal strings map cleanly?** Yes — 0 unclassified. The strings are
   a closed set generated from one file, so exact-match is sound.
   *One conflation:* cascades produce the same string as `this` being captured,
   passed or stored (`uses \`this\` other than to read a member`). They are not
   separable from the analyzer's output, and the bucket is named `this-escape`
   to say so rather than reporting a cascade count it cannot support.
2. **Are three policy classes sufficient?** Not quite. `architectural` is doing
   too much work — it covers the synthetic-library model (cannot name another
   library's privates), the **entry-point ABI** (arity), and the replacement
   model (added/removed members). The middle one is not architectural in the
   same sense: the fork has already widened it once. **Recommend splitting into
   `model` / `abi` / `replacement-shape` before Phase 1.**
3. **Does mechanical selection yield code-push-shaped changes?** For the app,
   yes — error-handling and key-event tweaks are exactly the target population.
   For the fork, no: even excluding `route_b`, recent history is almost entirely
   this project. **Phase 1 should sample uniformly at random with a fixed seed
   across full history**, not take the most recent N.
4. **Is "primary blocker" subjective?** It would be, and the design already
   refuses to guess: **8 of 10 patches have multiple independent blocking
   categories**, so `primary_blocker` is null in all 8. The ranked table must
   keep reporting occurrences *and* patches-affected; a single headline reason
   per patch would be invented, not measured.
5. **Does 3-way parallelism behave?** Yes, once leasing was fixed. No flakiness
   and no contamination. It did make the silent-failure mode easier to miss,
   which is why the `identical_kernels` guard is not optional.

## Cost, re-measured

Far cheaper than scoped, because the 90s figure was near-cold:

| | per case (3-way) | 50 cases |
|---|---|---|
| app (Flutter, 44 MB dill) | ~105 s | ~30 min |
| fork (CLI, 15 MB dill) | ~60 s | ~17 min |

Phase 1 at 50+50 is **under an hour**, not 3.5 h. The corpus can afford to be
larger than planned — which matters, because 10 cases is enough to rule
compound writes out and nowhere near enough to size the private-member problem.

## What this suggests, without deciding it

If the Phase 1 numbers hold, the interesting question stops being *which syntax
form to widen* and becomes:

* can a replacement name the target library's private members — i.e. is the
  synthetic-library model itself the limit, and can a payload be compiled *into*
  the target library's privacy scope?
* can the entry-point contract carry a receiver **and** the method's own
  parameters?
* can a patch add a member at all?

Those are three architecture questions, and the data says they matter roughly an
order of magnitude more than the lexical ladder did. **Deciding them is not part
of this study.**


---

# Phase 1 — attempted, blocked, and why

Both requested changes were made and the study was rerun from scratch:

* **taxonomy split** into `model` / `abi` / `structural` / `deliberate` /
  `not-yet`, with raw reason + category + subtype all preserved separately
  (`compat_taxonomy.py`);
* **fixed-seed sampling** — filter mechanically, shuffle with seed `20260811`,
  take the first 50; seed, eligible-set sha256, full eligible list, selection
  and funnel written to a manifest (`compat_phase1_attempt/*.manifest.json`);
* **three separate outcomes** recorded — coverage verdict, producer lowering
  verdict, whole-patch publishable — with `identical-kernels` as its own
  terminal state.

**100 of 100 cases produced no analysis.** Not a result about Route B: a result
about the method.

| | app (Wonderous) | fork |
|---|---|---|
| eligible after filtering | 109 | 1025 |
| sampled | 50 | 50 |
| sampled date range | 2024-05 → 2026-07 | 2023-05 → 2026-07 |
| dependency resolution failed | 19 | 46 |
| compile failed | 31 | 4 |
| **analysable** | **0** | **0** |

## What went wrong, precisely

Seeded sampling did exactly what it was asked to: it sampled the whole eligible
history instead of the recent tip. That exposed what taking the most-recent N
had been hiding — **historical trees do not build against a pinned toolchain.**

* The first run reached commits from **2022-09** declaring `sdk: ">=2.16.0
  <3.0.0"`. Dart 3.12.2 cannot resolve them at all. Measured: 286 of the app's
  400 most recent Dart-touching commits declare a Dart 2 constraint.
* An SDK-compatibility filter was added (mechanical, reported in the funnel:
  290 of 422 app commits dropped, 129 of 1281 fork commits). The survivors still
  fail, because a *compatible SDK constraint is not a resolvable dependency
  set*: Wonderous at `^3.3.0` pins `intl ^0.19.0` while the pinned Flutter SDK
  forces `intl 0.20.2`. Version solving fails before any compile.
* Per-case `pub get` was added so dependencies match the commit rather than
  HEAD. It cannot fix a constraint the pinned SDK contradicts.

One of the two failure modes is mine and fixable: the fork's `pub get` ran at
the worktree root, which has no `pubspec.yaml` at older commits (the workspace
layout is newer than much of the history). That accounts for the fork's 46 and
would move to `packages/shorebird_cli`. **The app's 19 + 31 are not a harness
bug** — they are genuine dependency-era incompatibility.

## The decision this needs

Replaying historical *trees* against one pinned toolchain does not work, and no
amount of filtering fixes it: the filter that would make it work is "commits
recent enough to build today", which reintroduces exactly the recency bias
seeded sampling was adopted to remove.

The alternative that keeps real diffs and drops the incompatible context:

> **base = HEAD with commit C reverted; patched = HEAD.**

The change content is real and unmodified — it is C's own before/after — but it
is rebased onto a tree that builds. Dependency resolution happens once, at HEAD,
where it is known to work. Commits whose revert does not apply cleanly are
excluded mechanically and reported in the funnel.

What it costs, stated plainly: the corpus becomes *diffs that still apply to
today's code*, which correlates with recency and with churn locality. That is a
different population from "all historical changes", and the write-up would have
to say so. It is a narrower claim, honestly labelled, rather than a broader one
that cannot be computed.

**Not adopted unilaterally.** Selection has already been amended twice under
pressure of results, and changing what the corpus *is* — from historical trees
to rebased diffs — is a bigger change than either. It is the study's meaning,
not its plumbing.

## Freeze: two leaks found, one still open

`analyze_coverage.dart` is untouched since `cb50590d` and the cell's
`route_b_analyze.aot` still hashes to `4023835b…`, so what the study *measures*
is frozen. Two things around it were not:

* **The harness ran the repo's `gen_dynamic_interface.dart`**, not the cell's
  `route_b_gen_dynamic_interface.aot`. The repo copy is live and changed under
  the study on 2026-08-11 (`a2927e41`). Using it means claiming a frozen cell
  while running an unfrozen tool inside it. Fixed: the cell's generator is now
  invoked, which is what shipping it in the cell is for.
* **The PRODUCER is not frozen and is being changed** — `a28ba1d9` makes a
  private receiver class lower to `dynamic`. The study does not run the
  producer; it derives a producer verdict from the analyzer's lowering data as
  "any unsupported lowering means refused". That model is now potentially stale
  in the accepting direction. No results are invalidated because no Phase 1 data
  exists, but **the freeze has to cover the producer as well, or the derived
  verdict has to be pinned to a producer commit.** Open.

The harness is complete and unblocked otherwise: taxonomy, seeded manifests,
three-outcome recording, `identical-kernels`, verified checkouts, worktree
leasing, and reclassification from preserved `raw` all work. Only the corpus
construction is open.


---

# Baseline for Phase 1 — and two reasons it is not pinnable yet

Decided: **historical parent/child trees stay.** Revert-onto-HEAD answers a
different question — *would this old edit be patchable against today's program?*
— and it would move the very things being measured: privacy, class shape,
signatures, reachability, member existence, call resolution. It would give real
diffs and not real patches. It stays available as a separate, later study, and
the two populations are never mixed.

A historical pair that no longer builds is therefore **recorded, not rescued**:
`toolchain-incompatible` and `dependency-resolution-failed` are terminal states
in the funnel. Transplanting such a diff onto HEAD would quietly convert a
failed historical-compatibility result into a different experiment.

## Landed now

* `producer_verdict` -> **`predicted_producer_verdict`**, and `publishable` ->
  `predicted_publishable`. The study does not run the producer; it infers from
  the analyzer's lowering output. The inference holds one way only —
  *analyzer-unsupported implies the producer refuses* — but not the converse:
  the producer also refuses for an unrecognised access kind, two edits at one
  offset, a non-empty parameter list, and `this . label` spacing, none of which
  the analyzer reports. So it is a **lower bound on refusal and an upper bound
  on publishability**, and it is now named for that instead of borrowing the
  producer's authority.
* Terminal states renamed to `toolchain-incompatible` /
  `dependency-resolution-failed`, plus `identical-kernels`.
* `--producer-commit` is required and recorded on **every row** and in the
  manifest, so a later baseline can be compared rather than confused.

## Why the baseline cannot be pinned yet

**1. The producer is settled; the CELL is not, and they disagree.**
The producer's last change is `a28ba1d9` (G3.6c, private receiver class lowers
to `dynamic`) and is clean. But `gen_dynamic_interface.dart` — a cell file —
changed *after* it, twice: `059573ca` (G3.6d, retain private classes, class
members and top-level fields) and `a2927e41`. The published cell
`aa9155840d…` predates both.

Pinning {analyzer v6 + cell `aa915584` + producer `a28ba1d9`} would pair a
**post-G3.6c producer with pre-G3.6d retention**. Retention decides what is
reachable, and reachability is a study input — `unreachable-target` was a
`structural` blocker in Phase 0. That baseline would measure a configuration
that has never existed.

A coherent baseline needs a cell minted from current cell sources. That is an
`R3` mint, and `R3` is currently held read-only by the other session.

**2. More producer work is expected.** `PARITY.md`'s claims table notes `R7` is
free but that **`G3.6b` will want it**. Starting Phase 1 against `a28ba1d9` and
having `G3.6b` land mid-run reintroduces exactly the contamination the pinning
is meant to prevent.

## The procedure — wait, then one coherent mint

No mid-flight mint. Coordinating one while `R3` is still owned by active work
recreates exactly the incoherence the study exists to avoid, and starting a few
hours earlier against a baseline nobody shipped buys nothing.

The trigger is the other session declaring **`G3.6` complete** in `PARITY.md`.
Then, in order:

0. **HARD PRECONDITION** — `PARITY.md` says `G3.6` is complete **and** `R3` is
   unclaimed or released. Both, not either. `compat_baseline.py` records the
   `R3` rows and any "G3.6 complete" line verbatim into the baseline object, and
   reports when it finds none; it deliberately does not decide them, because
   that table's format belongs to another session;
1. `G3.6` declares complete;
2. confirm the working tree is clean and the relevant commits have landed —
   `compat_baseline.py` refuses to emit a baseline over a dirty tree, since one
   captured across uncommitted changes describes a tree nobody can check out;
3. mint one cell from those exact sources;
4. audit the published cell and check it resolves;
5. record the immutable baseline tuple below;
6. freeze it;
7. run historical-tree 50 + 50 from zero.

### Baseline A — an atomic tuple

Recorded together or not at all. `compat_baseline.py` captures it, so no field
is transcribed by hand:

| field | |
|---|---|
| analyzer version and `route_b_analyze.aot` sha256 | |
| full compiler-cell manifest hash | the cell address, over all seven files |
| producer commit | |
| `gen_dynamic_interface` version inside that cell | source commit + aot sha256 |
| release/patch CLI commit | if distinct from the producer commit |
| corpus seed and both eligible-set hashes | one per source |
| Phase 0 comparability | version + hash before and after, verdict, and reason |

### Did `G3.6` change analyzer SEMANTICS, or only cell contents?

Recorded at mint time, computed from the artifact rather than from memory:

| condition | `phase0_comparable` |
|---|---|
| same version **and** same hash | **yes** — Phase 0 is directly comparable |
| same version, different hash | **no**, unless the change is explicitly proven behaviour-neutral (`--analyzer-change-proven-neutral`, whose justification is recorded verbatim) |
| version > 6 | **no** — Phase 0 is pilot and historical evidence only; no numerical Phase 0 ↔ Phase 1 comparison |

**This does not gate Phase 1.** Baseline A measures whatever coherent
analyzer / cell / producer product exists once `G3.6` closes. The flag exists so
that an invalid before/after claim cannot be made later, when the pilot's
numbers are the only ones lying around.

After row 1, no producer or cell change enters the study.

## CORRECTION — there is no A-before / B-after in this study

An earlier version of this document claimed baseline A measured *before*
private-receiver support and B *after* would be "close to the ideal experiment".
**That is wrong, and it was wrong when written.** Baseline A is being minted
*after* `G3.6` completes, so it already contains private-receiver support. This
study cannot produce that comparison.

Manufacturing it — deliberately minting an older coherent baseline just to have
something to compare against — would be constructing an experiment to fit a
narrative rather than measuring the product. Phase 0 already established that
private scope matters, in 9 of 10 patches. **Phase 1's job is to measure the
coherent product that actually exists next**, not to re-derive a conclusion
already in hand.

If later work changes private-receiver behaviour again, *that* becomes baseline
B and the before/after comparison arrives naturally, on a boundary the product
actually crossed.
