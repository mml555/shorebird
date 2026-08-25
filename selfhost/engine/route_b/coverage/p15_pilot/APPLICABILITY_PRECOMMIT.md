# P1.5 applicability funnel — precommitted BEFORE the measurement

Written 2026-08-25, before Wonderous is cloned and before any number exists.
Fixes what the reading licenses, so the number cannot be interpreted after the
fact.

## What this run does, and what it deliberately does not

Does: clone, `pub get` at HEAD, freeze the HEAD sha, mechanically select the
declared recent eligible window, and attempt **only** the `revert-onto-head`
applicability step.

Does **not**: compile a kernel, generate an interface, or run the analyzer. No
statement about Route B blockers can come out of this run, by construction.

    eligible commits examined
    revert applies cleanly
    revert-does-not-apply
    exclusion %

## The decision gate, fixed now

| exclusion rate | what it licenses |
|---|---|
| **low / moderate** | the corpus model is viable. Proceed to a pilot analysis, then 50 cases if the pilot is clean |
| **high** | **STOP.** Do not widen the window until enough rows happen to apply — that converts applicability into hidden selection, which is the failure this study has already committed twice under pressure of results |
| **near-total, like the fork's 10/10** | `revert-onto-head` is not a usable general corpus model. **Reopen the P1.5 methodology**; claim nothing about Route B |

No threshold number is invented here on purpose: the fork already produced
*near-total* (10 of 10 excluded), and a real product codebase is expected to sit
far from that. If the reading lands somewhere ambiguous, it is reported as
ambiguous rather than rounded toward the outcome that lets the study continue.

## Two rules that hold whatever the number says

* **`revert-does-not-apply` stays separate from compile failure.** An exclusion is
  a property of the corpus; a compile failure is a property of the toolchain.
  Merging them is how "0 analysable" became a claim about Route B once already.
* **Wonderous is not to be modified to make the corpus run.** No dependency
  bumps, no source edits, no constraint relaxation. If HEAD does not resolve on
  the pinned cell, that is a corpus-feasibility RESULT and gets reported as one.

## Why the window is declared rather than tuned

The corpus model already states that it selects *diffs that still apply to
today's code*, which correlates with recency. A window is therefore part of the
declared design, not a response to results — but its size is fixed before the
run and reported in the funnel, and it is not adjusted afterwards.
