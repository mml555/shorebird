# P1.5 applicability funnel — HIGH EXCLUSION. Stopped, per the precommit.

Run 2026-08-25 against `gskinnerTeam/flutter-wonderous-app`, HEAD
`747b945a7e5239356bf2664261aa2f3b020b8898`, window 40, seed `20260825`,
cell `93a3756…`. **No kernel was compiled and the analyzer never ran**, so
nothing here says anything about Route B blockers.

## Corpus feasibility at HEAD: YES

`flutter pub get` resolves at HEAD on the pinned toolchain (`sdk ^3.11.5`,
`flutter ^3.41.9` against the rig's Dart 3.12.2 / Flutter 3.44.8). Nothing was
modified to achieve that — no dependency bumps, no source edits. So the
historical-tree problem really was about *history*, not about this app.

## The funnel

    eligible commits examined   40
    revert applies cleanly      11
    revert-does-not-apply       29
    exclusion                   72%

Every commit in the declared window was attempted, so this is a rate rather than
a sample of one.

## Reading it against the precommitted gate

The gate said: low/moderate → proceed; **high → STOP, and do not widen the window
until enough rows apply**, because that converts applicability into hidden
selection; near-total → reopen the methodology.

**72% is high.** It is not the fork's near-total 10-of-10, and it is not
moderate. Per the precommit this run stops here, and the window is not widened.

## The stronger finding is CONTENT, not rate

The survivors are systematically the most trivial diffs:

    churn (added+removed Dart lines)
      revert applies          n=11  median   5  mean 36.4   <=10 lines: 7/11
      revert-does-not-apply   n=29  median  18  mean 29.9   <=10 lines: 11/29

Seven of the eleven survivors are ten lines or fewer, and reading their subjects
makes the shape plain: *"Removed unused hoverColor"*, *"Set flex to 50 for better
readability"*, *"Removed incorrect spacing"*, *"Forgot to update EditorialScreen
imports"*. The median survivor is a 5-line cosmetic change; the median exclusion
is 18 lines.

**So applicability correlates with triviality.** That matters more than the rate,
because P1.5's question is *what prevents realistic patches from publishing*. A
corpus whose surviving members are mostly one-line cosmetics would answer a
different question and would flatter Route B while doing it — the structural
blockers (added/removed members, signature changes) are exactly what a trivial
diff does not contain.

## What this licenses

* **Not** a blocker ranking. Zero cases analysed, by design.
* **Not** "proceed to the 50-case study" — the gate says stop, and the content
  bias is a second, independent reason to.
* It **does** settle that `revert-onto-HEAD` is not the general corpus model this
  study needs. It computes *something* where historical-trees computed nothing,
  but what it computes is biased toward changes too small to exercise the
  question.

## What it leaves open, stated as a question rather than a plan

How to obtain a corpus of *realistic* patch-shaped diffs that both (a) compiles
against one pinned toolchain and (b) is not selected on the basis of applying
cleanly to today's tree. Three directions exist and none is chosen here:
per-commit dependency pinning against an era-appropriate SDK (needs more than one
toolchain); synthesising patch-shaped diffs from real code (loses "real change"
provenance); or narrowing the claim to a named recent window and reporting the
survivor-triviality bias alongside every number (cheapest, weakest).

That is a methodology decision of the same weight as the one taken on 2026-08-25,
and this run is the evidence it needs to be retaken rather than the answer to it.
