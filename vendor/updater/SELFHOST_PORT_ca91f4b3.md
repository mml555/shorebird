<!-- cspell:words selfhost tombstoned tombstones unverifiable ureq NSURLSession -->
# Self-host port: route-b onto upstream ca91f4b3

Branch `route-b-ca91f4b3`. A source port, not a rebase. The old branch `route-b`
(tip `af6e842ccf87`) is untouched.

## Base and target

| | commit | date |
|---|---|---|
| Fork base (old route-b parent) | `1f85c4ab1ee5` | 2026-07-03 |
| Fork tip being ported | `af6e842ccf87a083d1598b1e7c9e0868c5731931` | 2026-08-27 |
| Target (`updater_rev` in shorebirdtech/flutter e2c965ff DEPS) | `ca91f4b313e5ff1ddb0471af0442ed2bad983bfe` | |

Every commit was cherry-picked with `-x`, in order, so each message ends with
`(cherry picked from commit <old sha>)`.

## Old to new sha map

| old (route-b) | new (this branch) | result |
|---|---|---|
| 9e74494 | f5925b0 | conflicted: patch/Cargo.toml, Cargo.lock |
| 66c3815 | 3c63737 | clean |
| 5bd51b3 | 54da716 | clean |
| 42d572a | ac8e186 | conflicted: updater.rs |
| 9b129c8 | 3c8d9bd | conflicted: updater.rs (flaky-test part superseded) |
| ae1a484 | ffca74b | conflicted: events.rs, network.rs, updater.rs |
| 123ec0c | 178be2d | conflicted: updater.rs |
| 0474e2f | e6e6ada | conflicted: updater.rs |
| 2199c35 | 631d70a | conflicted: updater_state.rs |
| fe51f22 | 62a40e7 | conflicted; production change superseded by upstream |
| 093b087 | f4f6b71 | conflicted: build.rs, events.rs, network.rs, updater.rs, updater_state.rs |
| f729f95 | 265ff1d | clean |
| af6e842 | 46dff9d | conflicted: updater_state.rs |

A final commit (after 46dff9d) holds the compile fixups and this file.

## Conflicts and resolutions

1. **9e74494, patch crate.** Upstream replaced `comde`/`pipe` with direct `zstd`
   and dropped `hex`. `route_b_artifact` now decodes with `zstd::Decoder` straight
   into `bipatch::Reader` (the same chain the updater's `inflate` uses) and
   formats the sha256 by hand. The only new dependency edge is `bipatch` (already in
   `Cargo.lock`), so no lockfile resolution was needed.
2. **42d572a.** Upstream's `handle_prior_boot_failure_if_necessary` loads through
   `load_state(config)` and holds `StateLock`. Kept that, applied the fork's
   threshold logic inside it.
3. **9b129c8.** The flaky-test fix (fixed 10ms sleep before asserting the download
   event) is superseded: upstream sends and removes events synchronously and tests
   join the flush threads (`testing_wait_for_event_flushes`). Took upstream in both
   conflicts. Kept the fork's poison-tolerant `lock_global!` and `GlobalTestState`.
   `wait_for` is now unused and carries `#[allow(dead_code)]`.
4. **ae1a484, boot-lifecycle events.** `PatchEvent` now has upstream's
   `failure_category` and `event_id` and the fork's `outcome`,
   `ambiguous_attempt_count`, `boot_failure_threshold`, `boot_started_at`. All
   emission points use upstream's `queue_or_send_event` (which falls back to a
   one-shot send when the queue cannot be saved), except the init-time retry and
   retire events, which `queue_event` as the original did (the app is still
   starting). Upstream tests that built `PatchEvent` literals were extended.
   Tests for `handle_network_result_*` were superseded by upstream's transport
   tests and taken from upstream.
5. **123ec0c / 0474e2f.** Re-applied the `shorebird_info!` line and the
   `success_diag.log` witness inside upstream's reshaped `report_launch_success`.
6. **2199c35, lost-update instrumentation.** Kept (LOAD/QUEUE_EVENT/SAVE
   `state_diag.log`). Its original purpose, a whole-file save losing an event, is
   now structurally prevented upstream by `StateLock`, so this is observation only.
   It still appends to `state_diag.log` and `success_diag.log` unboundedly and
   neither is in `SHOREBIRD_OWNED_PATHS`, same as on the fork.
7. **fe51f22, ack-only removal.** Superseded: upstream's `send_queued_events`
   removes exactly what it sent via `UpdaterState::remove_event`. Production code
   took upstream. `acknowledge_sent_event` survives as a `#[cfg(test)]` wrapper over
   `remove_event` so the fork's four regression tests port unchanged, and
   `remove_event` gained the fork's `ACK_EVENT` diagnostic line.
8. **093b087, revision stamp.** build.rs keeps upstream's `engine_http` cfg and adds
   `emit_updater_revision`. Port change: `updater_revision` is
   `#[serde(default = "unknown_updater_revision")]`. As a bare required `String`, one
   event queued in `state.json` by an updater without the field would fail
   deserialization of the whole state file, which upstream now treats as an
   unreadable-state incident. The commit also contained the failure rotation
   (`requeue_failed_event`) that its message does not mention.
   **Not wired into production** (see decisions below); kept as `#[cfg(test)]`.
9. **af6e842, `prepare_next_boot`.** Upstream deleted the test-only
   `UpdaterState::install_patch`; the fork's new tests used it. The `install()` test
   helper now uses `install_fake_patch_into`. Added `prepare_next_boot_reporting`:
   upstream's `validate_next_boot_patch` queues a `boot_validation`
   `PatchUpdateFailure` (with `failure_category=invalid_signature` in Strict) when a
   candidate is rejected. The fork's `prepare_next_boot` swallowed that error, which
   would have dropped upstream's report. `updater::prepare_next_boot` now queues that
   event itself, through `load_state` (so under `StateLock`).

Also a port change: `init_for_testing(.., None)` now uses `http://127.0.0.1:9`.
Upstream's `report_launch_success` flushes inline in tests, and with the real default
host a 4xx answer would make the updater drop the queued events the fork's tests
assert on.

## Decisions for the owner

* **Failure rotation dropped from production.** The contract says queued events use
  exact acknowledgement plus rotation. Upstream sends oldest-first, stops at the first
  transient failure, and drops events refused with 400/413/422. A head event that fails
  forever with 401/403/404 still blocks the queue (the starvation the rotation
  prevented). Re-adding it is one call in `send_queued_events`'s failure arm.
* **`patch_verification` default flipped to `install_only`** (was `strict`). Self-host
  apps that rely on the default lose the per-boot re-hash. Set it explicitly to keep
  Strict.
* **MEASUREMENT_MODE freeze.** `updater_revision` will stamp the post-port commit sha,
  which is not in `eligibleUpdaterRevisions`. Behaviour also changed (retry/flush
  semantics, inline flush, at-least-once delivery), so adding it is a policy decision.
* **Assets-only work: ported (follow-up).** From the self-host repo's `vendor/updater`
  (format-patch `--relative=vendor/updater`, `git am -3`, same branch):
  `530f5e1a0` -> `cb80a59`, `c7963536d` -> `641830e`, `0b80cdb73` -> `b2863f9`
  (assets patches, `dlc.assets`, `PatchPayloadKind`, `supported_patch_kinds`, the
  test-only `shorebird_test_check_signature`), plus fixup `652bb1b` (below).
* **Self-host default stays `install_only` in code.** Self-host apps that want per-boot
  re-verification must set `patch_verification: strict` explicitly in their checked-in
  shorebird.yaml.
* **Open item: `updater_revision` / `eligibleUpdaterRevisions`.** Not changed. The
  stamped sha is not in `eligibleUpdaterRevisions`; whether to add it is the owner's
  decision (see MEASUREMENT_MODE freeze above).
* **Rotation (`requeue_failed_event`) keeps upstream's stop-at-first-failure.** Server
  contract: `/events` must answer a permanently bad event with 400 or 422 (413 is also
  dropped), never 401, 403 or 404, or the queue blocks behind it. Current
  `packages/code_push_server` (self-host ref `selfhost/upstream-sync-1.6.138`,
  `api.dart` `_patchesEvents`, read-only) breaks this in two ways:
  1. A poison event the DB rejects (for example a NUL character in `raw`, which
     Postgres refuses in text) throws in the `try` insert, then again in the `catch`
     fallback `insertEvent(raw: raw)`, giving 500 via `_route`. 5xx is transient to
     the updater, so that event blocks the queue permanently.
  2. Any path outside `/api/v1/patches/events` or `/patches/events` (a proxy prefix, a
     wrong `base_url`) gets 404 `not_found`, and a request that loses its public-route
     status would get 403 `forbidden` from `_auth`. Both are the refused-forever codes.
  Otherwise fine: malformed JSON or wrong field types answer 204 (stored raw), oversize
  bodies 413, rate limiting 429 (transient, correct). Fix 1 by returning 422 when the
  fallback insert fails.

## Signature verification in `install_only`

Upstream ca91f4b3 verifies at install time, in every mode:

* `library/src/updater.rs:1032` `download_and_install_patch` calls
  `check_patch_signature(&patch.hash, patch.hash_signature, config.patch_public_key)`
  before anything is fetched. Failure tombstones the pair (`record_signature_refused`,
  `lifecycle.rs:494`) and returns `UpdateError::InvalidSignature` (reported as
  `failure_category=invalid_signature`).
* `updater.rs:1151` `check_hash` then ties the inflated bytes to `patch.hash`, so the
  signature covers what was installed.
* Strict mode adds a per-boot re-hash and re-verify, `lifecycle.rs:770`.
* A missing signature with a key configured is an error (`signing.rs:28`).

The port keeps this: same code at `updater.rs:1094` (call), `1213` (`check_hash`),
`lifecycle.rs:943` (Strict boot), `lifecycle.rs:600` (`record_signature_refused`).
Nothing in the fork commits touches these.

So the premise holds for the fork's old base (`check_signature` only in the Strict
branch at lifecycle.rs ~892 and a `#[cfg(test)]` path at updater_state.rs ~489 on
route-b; the vendor copy at lifecycle.rs:800 and updater_state.rs:394), and is fixed by
the port. Upstream's own comment on the new default says never to backport it to an
updater without install-time verification, which the old fork base lacked.

**Assets-only patches.** `download_and_install_patch` is shared by both payload kinds
and calls `check_patch_signature(&patch.hash, ...)` before any fetch
(`library/src/updater.rs`, top of that function), so an assets patch is verified at
install in every mode. The vendor copy lacked this in `install_only` (signature checked
only by the Strict boot path); the port closes it. Test:
`badly_signed_assets_patch_is_refused_at_install_before_any_download` (bad and missing
signature, `install_only`: `InvalidSignature`, tombstoned, zero downloads, no
`dlc.assets`). The hash on the assets path is `sha256(downloaded bytes)`.

## Server-facing changes versus UPDATER_CONTRACT.md

New event `type` strings: none from upstream. `__patch_boot_lifecycle__` (fork) is
unchanged. Endpoints: unchanged (`/api/v1/patches/check`, `/api/v1/patches/events`,
absolute `download_url`). Check request and response bodies: unchanged on the wire.

Event payload additions (all events):

* `event_id` (uuid string, upstream). Absent only for events queued by older updaters.
  The server can dedupe on it, and should still keep the existing key
  (`client_id|app_id|release_version|patch_number|type|timestamp[|outcome]`).
* `failure_category` (string, upstream), failure events only: `network`, `server`,
  `out_of_space`, `permission_denied`, `filesystem`, `corrupt_patch`,
  `invalid_signature`, `unknown`. `invalid_signature` is a category on
  `__patch_update_failure__`, not an event type.
* `updater_revision` (fork, always present, now `unknown` if absent in a queued event).
* New message prefixes: `boot_validation:` (rejected candidate at boot),
  `state_unreadable: booted_base=..,patch_installed=..,first_failed_at=..` with
  `patch_number` 0 when no patch (upstream's unreadable-state report), `update_failure:`.

Delivery semantics that differ from the contract's section 3 (the server will see them):

* Events are sent at every launch (`report_launch_success`) and at the start of
  `update()`, up to 3 per flush, oldest first, each removed only after a 2xx.
* A transient failure stops the flush and the event is retried: at-least-once, so
  duplicates are expected after a lost response.
* The server must not answer an event with 400, 413 or 422 unless it means "drop":
  those are discarded. Any other non-2xx (including 401/403/404) blocks the queue.
* Queue cap 50; the oldest are dropped beyond it.
* Request header `Content-Type: application/json; charset=utf-8`, downloads send
  `Accept-Encoding: identity`; JSON responses are capped at 10 MiB; error bodies are
  parsed as `{code, message, details}`.
* The HTTP stack on iOS, macOS and Android goes through the engine's client
  (`engine_http` cfg), so the engine consuming this must match shorebirdtech/flutter
  e2c965ff and still call `shorebird_prepare_next_boot_patch` (fork C symbol).

## Unverified

No Rust toolchain on this Mac (`which cargo` empty, `~/.cargo/bin` absent; `rustup` is
installed but has no toolchain and none was installed). Nothing was compiled or run.
Done instead: no conflict markers in any tracked file; every `PatchEvent` struct
literal names all 16 fields; every symbol the fork code calls
(`load_state`, `queue_or_send_event`, `remove_event`, `check_patch_signature`,
`record_signature_refused`, `BootRecovery`, `BootSuccess`, `lock_global!`) exists.

Needs `cargo build` and `cargo test -p updater --lib` (and `-p patch`) on ci-build or CI:

* the whole library build, in particular `updater.rs` test modules merged by hand
  (imports, helper visibility);
* `patch/src/bin/route_b_artifact.rs` (new zstd/bipatch path, hand-written hex);
* the fork's `prod_*` tests under upstream's inline flush;
* the `prepare_*` tests, which now install through `install_fake_patch_into` and rely
  on upstream's Strict boot validation rejecting an unsigned patch;
* `cargo clippy` and `cargo fmt` (several fork blocks are not rustfmt-shaped);
* `build.rs` stamp when the crate is built outside a git checkout (gives `unknown`);
* cbindgen output for `library/include/updater_engine.h` (edited by cherry-pick, not
  regenerated).

Also needed for the assets work: the assets install/unzip tests and the `zip` crate
feature set (deflate); `library_test_hooks` build (`shorebird_test_check_signature`);
`network.rs` pinned request tests (`supported_patch_kinds`) and every `Patch { .. }`
literal (`kind`); the new assets signature test; `lifecycle.rs` `PatchKind` /
`installed_artifact_path_for` merged with the fork's boot-lifecycle fields.

## CI bring-up (first compile)

All three crates (`library`, `patch`, `library_test_hooks`) pass `cargo fmt --check`,
`cargo clippy --all-targets -- -D warnings` and `cargo test` on the Linux runner. The
generated headers (`library/include`, `library_test_hooks/include`) are byte-identical
to what the build regenerates.

* **Compile and lint.** Missing `bail` import; zip 9 `SimpleFileOptions`; tests updated
  for upstream's fallible `load_or_new_on_error` and `&UpdaterState` from `with_state`;
  `supported_patch_kinds` added to pinned `PatchCheckRequest` literals;
  `clippy::type_complexity` fixed with a `PreparedBoot` alias; a `format!` with no
  arguments removed; `cargo fmt`.
* **Test race (real, in the port's tests).** The `prepare_next_boot` tests in
  `updater_state.rs` write the process-global running patch but were not `#[serial]`,
  so they flaked the serial `c_api` tests. They are now `#[serial]`.
* **Fixture corpus adapted to the fork's behaviour** (`fixtures/cases`, replayed by
  `library_test_hooks/tests/fixture_corpus.rs`). The corpus pins upstream's wire and
  disk shape; the fork changes it on purpose, so the expectations were updated, not
  loosened:
  - patch-check request bodies carry `supported_patch_kinds: ["code","assets"]`;
  - events carry `updater_revision` (matched as `<string>`);
  - `pointers.json` carries `boot_attempt_count` and `last_boot_attempt_patch`;
  - `state_diag.log` (and `success_diag.log` after launch success) appear in trees;
  - the boot-failure threshold (2): a boot that did not finish is retried once
    (`ambiguous_boot_retry`) and retired on the second (`retired_after_ambiguity`),
    which also queues a `__patch_boot_lifecycle__` event next to
    `__patch_install_failure__`. The four `crash_*` cases now preseed a tally at the
    threshold and expect both events; `kill_during_boot_then_relaunch` and
    `second_launch_start_in_process_boots_new_patch` repeat the death before the
    retire. New case `boot/crash_below_threshold_retries_the_patch` pins the retry.
