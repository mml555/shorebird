# G15 / Route B — WHAT CURRENTLY STANDS

2026-08-17. **Read this before any file in `evidence/g15/`.** Several verdicts in
this directory were WITHDRAWN the same day they were written; they are kept
unedited under withdrawal headers so the reasoning stays legible, and a reader who
opens them cold will otherwise take a retracted attribution for a live one.

## THE MECHANISM — CLOSED

> A foldable constant-return release target can be successfully patched and
> attached while its callers no longer execute or consume that target at runtime,
> because optimization has substituted/eliminated the call. Making the same
> target opaque restores a surviving consumed call; the target becomes
> `TPOOL_UNIQUE`, and the replacement value renders.

**Attachment was green on BOTH sides.** What changed was the observation path, not
delivery — which is what makes this causal rather than correlational:

    12 B / NOT LOCATED / ABSENT / OLD-kill
        -> one-line opaque-body repair ->
    128 B / CONSUMED @0xea0b4 / UNIQUE idx 4211 / NEW-kill

Demonstrated in both directions:
* **synthetically** — matched pair, one screen: `foldability_verdict.txt`
* **by repair** — the long-failing target itself: `routebvalue_repair_verdict.txt`

## STANDING LEDGER

| claim | status | anchor |
|---|---|---|
| Route B iOS end-to-end execution | **PROVEN** (8 specimens) | `routeb_behavioral_evidence_audit.md` |
| Foldability as the discriminator | **ISOLATED**, then **CONFIRMED by repair** | `foldability_verdict.txt`, `routebvalue_repair_verdict.txt` |
| Target kind (top-level vs member) | **REFUTED** as a discriminator | `target_kind_verdict.txt` |
| Claim 1 — `0012`/`0013` instrument | **ESTABLISHED**, positive locator **PROVEN**; `AMBIGUOUS` still unexercised | `claim1_0012_instrumentation_verdict.txt` |
| Mint provenance generator | **PROVEN** | `mint-provenance/proven_verdict.txt` |
| **Arm A (original specimen)** | **INCONCLUSIVE — unchanged, not re-scored** | `gate5_armA_inconclusive.txt` |
| Arm A confirming successor | PASS-EQUIVALENT on a **repaired** specimen | `routebvalue_repair_verdict.txt` |
| release-91 `NEW-kill` | **CONTRADICTED** by stronger current evidence | `manual_launch_control_verdict.txt` |
| Inlining (as 91-vs-96 differentiator) | REFUTED — both ABSENT | `r91_vs_r96_tpool_verdict.txt` |
| **Arm B — crash-backout** | **PASS** — first bad launch, no process death | `armB_crash_backout_verdict.txt` |

### The arm A distinction, stated once so it is not blurred

`gate5_arms_precommit.md` contains **no fixture-repair provision**. The repair run
therefore proves the MECHANISM and the REPAIR without touching the frozen arm.
Its observations happen to match arm A's PASS row; that is a PASS-equivalent on a
repaired specimen, **not** a PASS of arm A.

## WITHDRAWN — do not cite these conclusions

| file | what was withdrawn | why |
|---|---|---|
| `r91_behavioral_verdict.txt` | "engine lineage is a behavioral discriminator"; "one variable, and the outcome flips" | cells `80e493e4` and `87130ae8` ship the **byte-identical** engine binary; the method was never controlled |
| `cd137db6_bisect_verdict.txt` | exoneration of `0012`/`0013`; "flip present at `cd137db6`" | same confound |
| `gate5_armA_fold_refuted.txt` | its **conclusion** only | the objection (release 91 worked) was later withdrawn. **Its evidence and reasoning were sound at the time** — the hypothesis survived, the objection did not |

The `OLD-kill` observations in the first two remain FACTS about what those runs
displayed; only the lineage inferences are void.

## History worth carrying

* The mechanism was documented in `airgap_probe` from the beginning
  (`lib/main.dart:52-56`), discovered on the HOST: *"a literal is constant-folded
  by the type-flow analysis even under `vm:never-inline`… the gate then reports a
  working mechanism as OLD."* It was never connected to the device failure until
  2026-08-17.
* **Attachment evidence never substitutes for output evidence.** Release 96 had
  `applied 1/1`, `rc=0`, bytecode attached, entry point moved, and a payload
  carrying `NEW-kill` — and rendered `OLD-kill`.
* **Verify the image, not the filename.** `releases/37/r37_patch1_PARAM.png` is
  named for a value it does not display; release 37's own verdict says so.
* Three corpus differences were identified in sequence, and only the second was
  causal: target kind (refuted), **body foldability (causal)**, pragma presence
  (never tested — both halves of the fold pair were pragma-free).

## Open

* **Arm A itself** — INCONCLUSIVE. Would need a run against its original frozen
  specimen, or an explicit precommit amendment permitting repair.
* **Tombstone / retry lane** — `boot_attempt_count: 1` caught mid-flight is
  preserved unread at `r91_hybrid_device/state/`. Needs counters bracketed per
  launch by design. **Arm B is now CLOSED** (`armB_crash_backout_verdict.txt`);
  the pre-success termination rows remain parked as unmeasurable on this rig.
* **C3/C4 ARE NOT WIRED INTO PRODUCTION** (found 2026-08-19). The boot-attempt
  threshold's function has no production caller; a single ambiguous process death
  tombstones a healthy patch today. `arm2_verdict.txt`'s attribution to `0010` is
  superseded. **Blocks the telemetry work**, whose C3 population is empty by
  construction until this is wired in.
* **Lifecycle policy** — now written as a contract in `selfhost/LIFECYCLE_POLICY.md`.
  C1/C2 are device-proven; **C3/C4 (ambiguous death, threshold) are BUILT by
  `0010` but never deterministically exercised**, and the threshold is not yet
  ratified as a product decision. No further manual tombstone experiments.
* **§15's gate wording** — it says a Dart-phase *crash* backs the patch out. What
  is proven is that an unhandled Dart *error* suffices, **with the process still
  alive**. The app hangs on a white screen until the user force-quits it. Correct
  the wording; do not merely mark the gate closed.
* **One hung launch per bad patch** — backout takes effect on the NEXT launch, so
  a broken patch costs the user one white-screen launch they must kill by hand.
  Real product gap, newly identified, nothing built for it.
* **Synchronous `main`** — takes `hooks.dart:476`'s `catch`/`rethrow`, not the
  `onError` path arm B measured. Untested.
* **`TPOOL_AMBIGUOUS`** — never observed in the field.
* **Pragma presence** — the third corpus difference, uncontrolled and untested.
* **`audit_log` content-read** — never completed this cycle (needs `docker exec`);
  publish durability is verified on the `releases`/`patches` half only.
* **`SHOREBIRD_JWT_ISSUER`** — still `169.254.189.3` against `PUBLIC_BASE_URL`
  `10.0.0.7`. Real defect; re-login cannot fix it; needs a control-plane restart.

## Rig state at close

Fixture bodies are back at their RELEASE values (`OLD-kill`, `OLD-CONST`,
`OLD-OPAQUE`, `OLD-MEMBER`, `OLD-TOP`) — the patch values were reverted after each
publish. Versions are bumped to what was cut: `killswitch_probe 1.0.8+1`,
`airgap_probe 41.0.0+1`. `~/.shorebird` is on cell
`50bdae36f6dafbe1da17852a42e119518e8e5cf4`. Nothing is committed; the working tree
carries this cycle's fixtures, evidence and three preserved releases (40, 41, 98).
