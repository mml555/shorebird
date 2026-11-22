<!-- cspell:words selfhost tombstoned -->
# Self-host port: route-b merged with upstream 91dbbddb958a

Branch `route-b-91dbbdd`: a merge commit (not a rebase) of upstream `91dbbddb958a`
into `route-b` at `87c198d`. Upstream's Flutter 3.50 line pins this updater
revision. 12 upstream commits since `ca91f4b3`: #451 (host fields), #453
(launch paused/resumed), #454 (never retire the patch a boot is using), #455
(launch reports name the loaded patch), #446, CI and docs.

## Conflicts and how each was settled

* `library/src/cache/lifecycle.rs`, `record_boot_success`. Upstream returns
  `Option<usize>` (`None` when the breadcrumb names a patch no longer
  Installed: it clears the breadcrumb without promoting). The fork returns
  `BootSuccess` carrying the ambiguity that preceded the boot. Merged:
  `Result<Option<BootSuccess>>`. The tally is captured before the reset as before;
  a non-Installed patch yields `None` (nothing promoted, no install event, no
  recovery event, no witness line). Upstream's `uninstall` (clears a breadcrumb
  naming the removed patch) came in unchanged.
* `updater_state.rs`: same signature change; kept the fork's `prepare_next_boot`
  and `detect_boot_crash_on_init`, took upstream's `uninstall_patch` doc.
* `updater.rs`: kept `prepare_next_boot` (atomic validate, select, attribute) AND
  took upstream's `report_launch_paused` / `report_launch_resumed`. The success path
  wraps the fork's durable witness and recovery event in `if let Some(success)`,
  then upstream's install-event logic uses `success.patch`. Tests: upstream's
  `host_field_tests` kept next to the fork's `terminal_failure` helper.
* Workflows: kept the fork's runner gates (`[self-hosted, linux, x64, updater]`,
  `HOSTED_RUNNERS`, no hosted Android job, `check_android` on the home runner).
  `build_patch_artifacts` takes upstream's explicit build and zip upload (with
  `TARGET` env) in place of `upload-rust-binary-action`; the matrix gains
  `"target": "x86_64-pc-windows-msvc"` for the Windows leg, which the new build step
  needs. `shorebird_ci` takes upstream's `permissions` block, with the fork's runner.

## Where both changed lifecycle logic

1. **Pause/resume vs the boot tally (a real interaction, fixed).** Upstream's
   resume re-arms the breadcrumb through `set_breadcrumb`, which the fork made
   count an attempt. With the Route B sequence start, paused, resumed, success, a
   normal boot would tally 2: `prior_ambiguous_attempts` 1 (a recovery event for a
   boot that never failed), and a first real crash after resume would be at the
   retire threshold (2) at once, defeating the retry. Fix: `record_boot_pause` gives
   back the attempt `record_boot_start` counted when it clears the breadcrumb, and
   `record_boot_resume` counts it again. A death while paused is then not an
   attempt at all; a death after resumed is exactly one ambiguous attempt.
   Test: `start_pause_resume_counts_one_attempt`.
2. **#454 guard and attribution.** `promote_to_next_boot(n, running_patch)` keeps the
   previous next-boot patch if it is last booted, currently booting, or the running
   patch. `prepare_next_boot` sets the running patch and the breadcrumb in the same
   state transition, so the guard sees the executed patch, not the pointer.
3. **Threshold vs upstream's single-death retire.** Upstream tests assumed a
   death after resumed marks the patch Bad at once. The fork retries below
   `BOOT_FAILURE_THRESHOLD` (2). Kept the fork's rule and adapted the tests/fixtures
   (`death_after_resumed_marks_patch_bad_at_the_threshold`,
   `kill_after_resumed_rolls_back`, `install_during_boot_then_death`): the first
   death retries (or, with a newer patch installed, lets that patch take over while
   1 stays installed), the second tombstones.
4. **`record_boot_success` on a non-Installed patch** now returns `None` even for
   the fork's `BootSuccess` consumers; the fork's recovery event is only queued for
   an actually recorded boot.
5. **Numbered `*_for_patch` reports (#455)** are taken as is. `report_launch_start_for_patch`
   arms through `record_boot_resume` (no next-boot match, no validation). The Route B
   engine does not call them; it uses `shorebird_prepare_next_boot_patch` plus the
   unnumbered reports, so attribution stays atomic with selection.

## Fixtures

Upstream's new boot and patch-check fixtures were extended for fork fields:
`boot_attempt_count` / `last_boot_attempt_patch` in pointers, `supported_patch_kinds`
in patch-check bodies, `updater_revision` in events, `state_diag.log` in the tree.

## Wire changes the server must accept (from #451)

Patch check (`POST patches/check`) and events (`POST patches/events`, inside
`event`): `host_bundle_id` (string, optional, omitted when unknown) and
`host_version` (string, optional, omitted unless it differs from
`release_version`). `release_version` itself is, for an add-to-app module, the
version baked into the generated shorebird.yaml. Already sent by the fork:
`supported_patch_kinds` (array of string, patch check) and `updater_revision`,
`event_id`, `failure_category`, boot-lifecycle fields (events).
The launch paused/resumed/success reports send nothing new on the wire.

## Mirror #10 and #11 (merged from route-b-ca91f4b3, 2026-11-22)

`route-b-ca91f4b3` was merged into this line after `a58774ab`. It brings the
bounded diag logs (`diag_log.rs`; the success witness in `record_launch_success`
now writes through `diag_log::append`, inside 91dbbdd's `if let Some(success)`),
the refused proxy CONNECT classified as a transport error (`http.rs`), and the
fork-PR and proxy CI changes. `SELFHOST_PORT_ca91f4b3.md` comes with it and
describes that line, not this one.
