# Real-patch compatibility study — scope

**Status: Phase 0 complete (10 cases). Phase 1 NOT cleared — see the exit
check.** Analyzer frozen at **v6**, cell
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
