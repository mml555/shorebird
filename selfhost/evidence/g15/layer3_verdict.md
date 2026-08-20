# LAYER-3 RUN — server fix PROVEN; layer 3 NOT closed, because the client did not emit the recovery

Scope was rows 4-5 only, on a fresh patch identity. **Server capability is proven.
Layer 3 with real device data is NOT closed, for a new reason.**

## THE SERVER FIX IS DEPLOYED AND PROVEN

Built `cps-assets:local-m9` from committed source and redeployed with identical
env, ports, mount and restart policy. `applied schema migration version=9`.

Preflight, before any device state was spent:

| check | result |
|---|---|
| lifecycle columns exist | **PASS** — `outcome`, `ambiguous_attempt_count`, `boot_failure_threshold`, `boot_started_at` |
| two outcomes, SAME timestamp, same client/app/release/patch | **PASS** — id 128 `ambiguous_boot_retry` and id 129 `recovered_after_ambiguity` **both persisted as separate rows**, 7-field keys |
| non-lifecycle keys unchanged | **PASS** — `__patch_install__` key still 6 fields, legacy form |
| genuine duplicate still rejected | **PASS** — repeat of an identical event logged `duplicate event ignored`, no second row |

**The collision that destroyed the recovery event in the previous run cannot recur.**

## ROWS 4-5 ON A CLEAN PATCH IDENTITY

Patch 1 was left `Bad{BootCrash}` and never mutated. **Patch 2** published on
release 104 with the same replacement payload (`NEW-kill` verified in
`replacement_0.dart`), downloaded, and booted healthy first (`last=2`, tally 0,
**zero** lifecycle events — the clean-boot guard again).

**Row 4 `hard-kill` — PASS, all four veto conditions:** checkpoint persisted,
nothing after it, SIGKILL landed, no explicit failure event, breadcrumb `cur=2`
with `count=1`, patch 2 still `Installed`.

**Row 5 `success`:**

* **LAYER 1 · device — PASS.** patch 2 `Installed`, `last_booted_patch=2`,
  breadcrumb `None`, `boot_attempt_count=0`. Operator saw `NEW-kill`: the patch
  was retried and booted. **The recovery HAPPENED.**
* **LAYER 2 · client — PARTIAL.** `ambiguous_boot_retry` emitted and POSTed (204).
  **`recovered_after_ambiguity` was NOT emitted** — absent from the queue on two
  separate reads, and absent from every event body the server received.
* **LAYER 3 · server — UNTESTED on real data.** There was nothing to persist.

## THE NEW FINDING

> **Recovery emission is not reliably reproduced.** The identical row-4 -> row-5
> shape emitted `recovered_after_ambiguity` (attempts=1) on patch 1 in the AFTER
> run, and did not emit it on patch 2 here — while the device state in both cases
> shows the recovery occurred.

This matters more than the server fix: **the recovery event is the numerator of
P(recovery | first ambiguity).** An intermittently-missing numerator biases the
metric downward exactly as the dedupe bug did, and would be harder to notice
because nothing is logged as dropped.

**Cause NOT determined.** What is ruled out: the device did recover
(`last=2`, patch `Installed`); the wired engine ran (the retry event proves it);
the server did not drop it (it never arrived); the queue was not merely unflushed
(empty on two reads, minutes apart). Candidate left untested: the ordering between
`report_launch_start`, init-time crash detection, and success, which determines
whether `boot_attempt_count` is 2 or 1 when success computes
`prior_ambiguous_attempts = count - 1`. If it is 1, the guard correctly suppresses
the event — meaning the TALLY, not the emission, is the variable.

## A MEASUREMENT ERROR I MADE, AND THE LESSON

I concluded "event ingestion is broken for all types" and **rolled the server back
on that basis. It was wrong.** The rows had been written; they were not yet visible.

* the host bind-mount read showed 126 rows;
* **`docker cp` of the container's own file showed 126 too**, so this was not a
  Docker bind-mount artifact;
* the four rows appeared only after the container stopped and flushed.

**Corrected wording — the general form of my first phrasing was too broad.**

> Copying or inspecting ONLY the main SQLite database file is not an authoritative
> live-state read for this deployment: committed state may still reside in WAL
> state until checkpoint or close. Query the live database connection, or account
> for its WAL files.

Verify ingestion from the server's own log, from the API, or against a connection
that sees the WAL — not from a copy of the main file alone. The rollback was
harmless and the correct image was redeployed, but the reasoning was faulty and is
recorded as such.

## STATE

* server: `cps-assets:local-m9`, migration 9 applied, dedupe fix live. Previous
  container kept as `cps-ios-prem9-keep` for rollback. DB backed up pre-migration
  at `evidence_preserved/code_push.db.pre_migration9`.
* rig: cell `ac8d8434`, wired engine. Release 104 + patches 1 (Bad) and 2
  (Installed, healthy).
* device: `g15_mode = success`; patch 2 `Installed`, `last=2`, tally 0.
* `compatibility.yaml` still unstamped.

## NEXT

1. **Determine why the recovery event was suppressed.** Cheapest path is a host
   test asserting the tally across the exact production sequence — boot-start,
   ambiguous death, init retry, boot-start, success — checking
   `boot_attempt_count` at each step, since the guard depends only on that.
   The existing `prod_telemetry_success_after_ambiguity_reports_recovery` passes,
   so the host sequence it models differs from the device's in some ordering.
2. Only then re-run rows 4-5 to close layer 3 with real data.
3. Then the `isRouteBEngine()` cold-cache fix.
