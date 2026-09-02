# D-DEMAND-1 — precommit. Written before any result was computed.

The question P1.5 left open and no static census can answer:

> **What constructs do developers actually change?**

D-CENSUS-2 reached its useful limit. It measured methods that EXIST, and its
two corpora disagree about which blocker dominates — tear-offs lead Wonderous
(49 sole) and barely register on LocalSend (3), while `this_escape` has the
opposite shape (1 vs 12). Adding a third application would break the tie without
answering the question. This measures what was actually EDITED instead.

## Instrument — the product's own two-world path

Not census mode. The shipping analyzer's release-vs-candidate mode:

    analyze_coverage --base-dill <commit N>.dill --patched-dill <commit N+1>.dill

which is the document the producer consumes. It reports `changed`, `added`,
`removed`, per-target `lowering`, `rejections` and a `verdict`. Unlike
D-CENSUS-2's self-census this has TWO worlds, so `releaseSuperTargets` can
genuinely diverge from what a candidate's super site names.

## Corpora and frozen anchors

    Wonderous  /Volumes/build/route-b/wonderous            pin 747b945a7e5239356bf2664261aa2f3b020b8898
    LocalSend  /Volumes/build/route-b/corpus2/localsend     pin 6279d3e30d1d1290caee3b81549f8128a8b01d9f

The same two applications and the same two pins as D-CENSUS-2, so a
demand result and a structural result describe the same code.

**LocalSend was a depth-1 shallow clone with no history.** It was deepened with
`git fetch --unshallow` (1983 mainline commits now reachable), which adds
objects without moving HEAD: the pin is still checked out and its `pubspec.lock`
drift is untouched, so D-CENSUS-2 stays reproducible. Deepening is not a
substitution and the alternative — swapping in a different app — is exactly what
the ruling forbids.

## Selection rule — fixed here, before any measurement

1. Walk the **first-parent mainline** from the frozen pin. First-parent because
   each mainline step is one real merged change set; walking all parents would
   double-count a PR's internal commits.
2. Take the most recent **K** commits on that chain. **K starts at 40.**
3. Pairs are adjacent on that chain: the older commit is the RELEASE, the newer
   is the CANDIDATE.
4. **Extension rule, pre-committed:** if the window yields fewer than 300
   changed instance methods, extend backwards in blocks of 40 and re-measure.
   Stop extending when 300 is reached, the mainline is exhausted, or two
   consecutive blocks each add fewer than 20 changed methods. Extension is by
   YIELD only. No block, commit or pair is ever added, dropped, reordered or
   trimmed because of what construct it contains.
5. A pair whose kernel fails to build at either end is EXCLUDED, counted, and
   its failure reason recorded. Exclusions are reported as a population, not
   quietly skipped.

## Dependencies are held constant, on purpose

Every commit in the window is materialised as a `git worktree` and compiled
with the **frozen checkout's** `package_config.json` and `pubspec.lock`, rather
than re-running `pub get` per commit.

  * It isolates the variable. We are measuring changes to the application's own
    method bodies; re-resolving dependencies per commit would let framework
    version drift move the numbers.
  * It avoids running `~/.shorebird`'s Flutter, which the standing constraint
    forbids perturbing.
  * **It is validated, not assumed:** the worktree pipeline reproduces the
    frozen Wonderous census exactly — 1282 considered / 1179 lowerable, the
    banked D-CENSUS-2 figures — before any pair is measured.

Any commit in the window that CHANGES dependency constraints is flagged, and
its pairs are reported separately, because a constant `package_config` may
misrepresent it.

Generated files are excluded by the same declaration-marker rule as D0.3 and
D-CENSUS-2 — the file head says it was generated — never by filename.

## Unit of observation

**One observation is one instance method whose BODY changed between two adjacent
mainline commits**, as `changed` reports it. Not lines, not construct
occurrences, not every method that exists, and never a synthetic mutation.

Each observation is classified against **its own actual preceding version** as
the release.

## Classification

Per changed method:

    ADMISSIBLE   `unsupported` empty, and every super site is narrow-v1
                 admissible (zero SOURCE arguments per the product's own
                 `routeBSuperCallArgs`, plus measured `releaseSuperTargets`
                 containing the site's exact resolved target)
    REFUSED      otherwise, with every blocking construct attributed by D0.3's
                 rules, imported from `census_report.constructs` rather than
                 restated

Pair-level refusals — `added` or `removed` members, signature changes — are
recorded as their OWN category. They would refuse a patch even if every changed
method lowered, and calling them per-method blockers would misattribute them.

## Introduced versus pre-existing

For each refused method, the blocking construct is also looked for in the
**release** version of the same method, by running census mode on the base
kernel and joining on the target key:

    INTRODUCED    the construct is in the candidate and not in the release
    PRE-EXISTING  the construct is in both

This distinction is required by the ruling and it matters: editing a string
constant inside a method that already contained a tear-off is real product pain,
but it is not evidence that developers frequently introduce tear-offs.

## Weighting

Reported BOTH ways, always:

    method-weighted   every changed method counts once
    commit-weighted   every pair counts once, by whether it contains at least
                      one method in that category

and the largest contributing commits are named per category. One mechanical
refactor touching 400 methods must be visible as one commit, not 400
independent evidence points.

## Controls, all four required before any conclusion

1. **Supported historical change classifies supported.** A real changed method
   the census calls admissible, shown admissible.
2. **Mutation flip.** That same historical method, with one real unsupported
   construct injected, must flip to refused and name the intended category.
3. **Production agreement.** At least one historical refusal replayed through
   the actual producer far enough to show the census reason agrees with the
   production refusal — not merely that both refuse.
4. **Super divergence.** A real release→candidate pair where super target
   evidence genuinely differs, if one exists in the window. **If none exists it
   will be reported as absent, not manufactured.**

## What this may not be read as

Two applications are not a distribution, and both are open-source consumer apps
built by small teams. Historical edits are what these developers did change, not
what a commercial team under patch pressure would want to change. A high
compatibility percentage would bound the *observed* demand, not all demand.

## Decision rule, pre-committed by the ruling

    tear-offs dominate real changed methods in BOTH  -> open D-TEAROFF
    this_escape dominates                            -> investigate that
    named/optional ABI accounts for more failures    -> ABI expansion
    already ~97-99% of real patch demand             -> stop language expansion,
                                                        move to productionization

---

# SUPERSEDED, by measurement: "dependencies are held constant"

Added after the first window ran and before any result was interpreted. The
original section above stands as written; only its dependency decision is
withdrawn, and the reason is a measurement, not a preference.

## What happened

Compiling every commit against the FROZEN checkout's resolution failed on the
older half of the window. All failures shared one cause:

    lib/logic/common/platform_info.dart: Error: Couldn't find constructor
    'InternetConnectionChecker'.

The pin's source reads `InternetConnectionChecker.instance.hasConnection`; older
commits read `InternetConnectionChecker().hasConnection`. The app was migrated
to a new package API at `3821b0c6` (2025-12-18), 24 commits back from the pin.
So a single frozen resolution can only compile commits NEWER than that
migration — 25 of the 40, and no amount of extending the window backwards adds
any more. The pre-committed extension rule would have run to exhaustion against
a wall.

A measurement detail worth recording, because it cost a wrong conclusion first:
`git log -S'InternetConnectionChecker'` found nothing, because `-S` counts
OCCURRENCES of a string and the migration kept the count identical. `-G`, which
matches diff content, found it immediately. The first search's silence was read
as "the source never changed", which was false.

## The replacement rule

Commits are grouped into **contiguous runs sharing one committed
`pubspec.lock`**, and each group is resolved ONCE:

    FLUTTER_ROOT=<frozen SDK> <SDK>/bin/cache/dart-sdk/bin/dart pub get

run at the group's first commit, with the resulting `package_config` reused for
every commit in that group. The SDK's own `dart` is used rather than `flutter`,
because the `flutter` tool can rebuild snapshots inside `~/.shorebird`, which
the standing constraint forbids perturbing. Verified: after this ran, that
checkout's only modification is the pre-existing uncommitted `engine.version`
already banked as a separate provenance debt.

Measured on Wonderous, a 60-commit window contains 10 contiguous lockfile
groups (largest 28 commits, 8 distinct lock states), so ~10 resolutions cover
60 commits and kernels are still shared between adjacent pairs inside a group.

**Why this is better rather than merely workable.** A Route B patch cannot
change dependencies. Inside a group the developers' own lockfile did not move,
so the release and candidate genuinely share a resolution — which is the
situation a real patch faces. Across a group boundary the lockfile DID move, and
such a pair is recorded under its own category `pair.dependency_change`: a real
refusal, counted and reported, never silently dropped.

This changes WHICH pairs are analysable on toolchain-feasibility grounds. It
does not select on construct content, and no pair is added, dropped or reordered
because of what it contains.
