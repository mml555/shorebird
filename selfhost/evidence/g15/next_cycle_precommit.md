# The next build/mint/device cycle — TWO INDEPENDENT CLAIMS, precommitted

Written 2026-08-16, before the cycle exists. One cycle can economically answer
both; they are **two claims and get two verdicts**, in separate files.

## The hazard this document exists to prevent

**A green instrumentation result becoming an arm A verdict by association.** The
cycle produces one trace file, read once, by one person, in one sitting. If
`tpool_status=UNIQUE` comes back and `routeBValue`'s identity is finally in hand,
the pull toward "so arm A is explained" is exactly the pull that produced every
retraction in this investigation. The claims share a cycle, a trace and an
operator. They do not share evidence.

## Claim 1 — `0012` instrumentation verdict

Question: *does the derived target→pool measurement work, and is the
assertion-path demotion real?*

| # | required | why it is not optional |
|---|---|---|
| 1 | a `v=5` trace is produced at all | a v4 trace means the built engine is not the patched one; everything downstream would be measuring the old instrument |
| 2 | `tpool_*` fields are POPULATED — `tpool_status` ∈ {ABSENT, UNIQUE, AMBIGUOUS}, `tpool_scanned` > 0 | `NOT_REQUESTED` (0) would mean the derived scan did not run, which is the defect `0012` exists to remove, reappearing |
| 3 | **the stale-offset negative control demonstrably MISMATCHES or REFUSES** — supply the historical `0xd4a8` where it points at a valid but different object; the assertion path must report `POOL_ENTRY_NOT_FUNCTION` or `pool_entry_equals_target=0`, **while the derived scan independently reports the true location in the same trace** | without it the demotion is design plus compile evidence only. A passing assertion proves nothing; only a FAILING one proves the two instruments are separate |

**Only all three together move the demotion beyond compile evidence.** Rows 1 and
2 with row 3 absent is a partial result and is reported as such — not as
"instrumentation works".

Note the shape of row 3: it is the only row whose PASS is a negative result. An
arm that can only come back green is the failure mode this project has named five
times.

## Claim 2 — arm A measurement

Question: *where does `routeBValue` actually live, and does that explain
`OLD-kill`?*

| observation | verdict |
|---|---|
| `tpool_status=UNIQUE` with an index/offset | target identity obtained. **This is a measurement, not an explanation.** Feed the offset to `assert_result_consumed.sh --pool-offset` against release 95's preserved `App` — that, and only that, retires or confirms consumption for this target |
| `tpool_status=ABSENT` | the patched `Function` is **not in the global pool**. That is the inlining hypothesis's signature and would be the first positive evidence for it — but it must then explain why release 91 worked, and until it does it is a lead |
| `tpool_status=AMBIGUOUS` | more than one slot holds it. Report both indices; do NOT pick one to feed the probe. `--pool-offset` on a chosen-from-several slot would be a confident wrong answer wearing a measurement's clothes |
| any of the above | **none of them is an `OLD-kill` explanation on its own.** Arm A's precommitted outcome table (`gate5_arms_precommit.md`) is unchanged and still requires `NEW-kill` on screen for a PASS |

## What must NOT happen

* arm A is **not** re-scored by this cycle unless a launch produces its
  precommitted observations. A pool measurement is not a screen.
* the arm A target is **not** changed. Nothing has established a defect in it,
  and `gate5_armA_fold_refuted.txt` removed the condition that would have.
* claim 1 passing is **not** written in the same file as claim 2, and neither
  verdict cites the other as support.

## Order, and why

Claim 1 first, on its own trace. If the instrument is not established, claim 2's
input is not evidence — and reading them in the other order is how an instrument
gets validated by the result it produced.

## STEP ZERO, before any mechanism is proposed

**Ask the retrieval question first: what is already on disk that constrains this
claim?** Not after a hypothesis forms — before. Five of the six corrections in the
session that produced this document were retrieval failures, not coverage
failures: the contradicting measurement already existed and was not brought to
bear. Coverage failures cost new instrumentation; these cost only the discipline
of reconciling evidence already paid for.

For this cycle specifically, the corpus that constrains it is already preserved:
`arm2_verdict.txt` (the same target rendering `NEW-kill` on 2026-08-14),
`gate5_armA_fold_refuted.txt` (91 and 95 share the consumed/discarded shape),
`routeb_caller_scan_gap.txt` (why the trace was silent), and releases 91/95 with
their dSYMs and supplements on the control plane. **Read those before proposing
what a new trace means.**

## Prerequisites carried forward

* every publish content-read (`releases`/`patches` + `audit_log`), success
  provisional until then; a vanish is preserved, auth state untouched;
* the capture invariant applies to any patch this cycle produces: declare the
  expected tracked-diff count, verify it, enumerate untracked files separately;
* `isRouteBEngine` returns false on a merely-absent `ios-release` binary — warm
  and confirm it EXISTS before cutting, or the release silently takes the
  non-Route-B path and still reports success.
