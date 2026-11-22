<!-- cspell:words spki rsassa -->

# Shorebird updater contract (self-hosted control plane)

Definitive wire + behavior contract for the Rust updater embedded in Shorebird's
Flutter engine, as required by our self-hosted `code_push_server`.

Source of truth: ~~the `shorebirdtech/updater` Rust crate (NOT in this repo)~~ —
**corrected 2026-08-13.** The crate **is** in this repo, vendored at
[`../vendor/updater`](../vendor/updater) (221 tracked files), and it has been
**forked past the pinned revision**: patch-kind negotiation was added on
2026-07-30 by `c7963536` so a patch can carry assets and no code. Read
`vendor/updater/library/src/network.rs` as the authority on the wire types.
Cross-referenced against on-device observations in
[`BEHAVIORAL_FINDINGS.md`](./BEHAVIORAL_FINDINGS.md) and our server in
`packages/code_push_server/lib/src/api.dart` + `repository.dart`.

> **⚠ This document predates the fork and does not describe two fields that are
> on the wire today.** It was last edited `d11bb058` (2026-07-29); the fork
> landed the day after, and nothing here was revisited. Until the body below is
> reworked, treat these two as part of the contract:
>
> * **Request** — `supported_patch_kinds: Vec<String>`, always sent as
>   `["code","assets"]` (`network.rs`; no `skip_serializing_if`, so it
>   is never omitted). It is a **capability gate**: our server withholds an
>   assets-only patch unless the client names `assets`
>   (`api.dart` `_patchesCheck`, the `supportedKinds.contains(assetsPatchKind)`
>   branch).
> * **Response `patch` object** — a fifth field `kind`
>   (`network.rs pub kind: PatchPayloadKind`), always present from our
>   server: `code` normally, `assets` for an assets-only payload.
>
> So the request is **eight** fields, not seven, and the patch object is
> **five**, not four — including in §6's requirement table. `compatibility.yaml`
> already documents `supported_patch_kinds`, so this file also disagreed with the
> pin manifest.
>
> **Line numbers were removed from every citation (2026-11-16).** Re-anchoring
> by line failed twice: on 2026-08-13 the `api.dart` cites pointed at unrelated
> code, and by 2026-11-16 every `updater.rs`, `lifecycle.rs`, `network.rs` and
> `yaml.rs` cite pointed elsewhere, because the vendored updater was re-vendored
> (see Provenance). Citations now name the file and the function or type; find
> the line with `grep -n`. A wrong line anchor reads as authority, a symbol does
> not. The signature, verification-mode, provenance and event-delivery
> statements below were re-read against the vendored tree at `87c198d3` on that
> date.

> ### ⚠ SECOND ADDITION — 2026-08-23. A fifth event type, a seventh dedupe field, and the flush contract has changed.
>
> The updater this file was first written for (`1f85c4ab`) is **no longer the
> vendored one** (`vendor/updater` is now `87c198d3`, see Provenance). The
> delivery and flush behaviour below was re-read against `87c198d3` on 2026-11-16
> and corrected in place; where a sentence says "pinned" it means the old pin. The
> text that follows was written for the Route B engine cells of 2026-08
> (`f729f958e9be`, cell `2c4443ce…`), whose source was then outside this repo and
> is now vendored. Treat the following as part of the
> contract for that client:
>
> * **A fifth event `type`: `__patch_boot_lifecycle__`** — NON-TERMINAL, unlike all
>   four types in §1. It reports transitions rather than failures, and it exists
>   because terminal events alone are survivor-biased: they show patches that were
>   RETIRED and never the ones that hit one ambiguous unfinished boot and recovered.
> * **Five new payload fields**, all optional and absent from every pre-existing
>   type: `outcome` (`ambiguous_boot_retry` | `recovered_after_ambiguity` |
>   `retired_after_ambiguity`), `ambiguous_attempt_count`, `boot_failure_threshold`,
>   `boot_started_at`, `updater_revision`. The server columnises all five
>   (`repository.dart` migrations 9 and 10) and reads them in `_patchesEvents`.
> * **The dedupe key is SEVEN fields, not six** — `outcome` is appended **only when
>   present**, so every pre-existing event type keeps a byte-identical key and nothing
>   is re-accepted on upgrade (`eventDedupeKey` in `api.dart`, deliberately public so
>   the collision rule is testable directly). This was not cosmetic: a retry and a
>   recovery from the same launch can land in the same timestamp-second, and without
>   `outcome` the RECOVERY was discarded as a duplicate — biasing the one metric the
>   retry threshold is judged on, in the one direction that makes retrying look
>   useless.
> * **Queued events are no longer cleared unconditionally.** Exact acknowledgement:
>   an event is removed only once THAT event was sent. Plus failure rotation, so a
>   batch that fails to send rotates instead of pinning the queue head — without it,
>   n stuck events form a permanent batch and censor everything behind them. §3's
>   *"the entire queue is cleared regardless of send success"* and §6's *"event
>   delivery is at-most-once"* are corrected in place below.
> * **`updater_revision` is the eligibility predicate** for lifecycle-policy
>   analysis, and `NULL` is ineligible: an unknown client cannot be assumed to carry
>   the event-loss fixes. See [`MEASUREMENT_MODE.md`](MEASUREMENT_MODE.md) — this
>   behaviour is **frozen** while fleet data is collected.

Citations are `library/src/<file>.rs` plus the function or type, against the vendored updater named below.

## Provenance / version pinning

- **Updater source pinned to:** `87c198d30f875a3da317d70935e1025dc13064dd`
  (branch `route-b-ca91f4b3` of `mml555/shorebird-updater-mirror`, on upstream
  base `ca91f4b3`), vendored at `vendor/updater` plus one later mirror change
  (#11). `vendor/updater/VENDOR.md` is the record, and
  `selfhost/compatibility.yaml` `updater_revision: 87c198d30f87` must equal its
  first 12 characters; `tool/check_updater_pin.sh` fails CI when they differ.
  The pin before the previous one was upstream
  `1f85c4ab1ee5b540269b9859c75e1bffbb9050c7` (2026-07-02), which most of this
  file's body was first written against; `af6e842c` sat between them. The crate
  carries no release tag for the library (`library/Cargo.toml` is `0.1.0`), so
  we pin the commit.
- **Engine → updater mapping is NOT discoverable from the updater repo alone.**
  The updater commit an engine was built from lives in the Flutter fork's
  `DEPS`, not here. `compatibility.yaml` says the supported pin consumes
  `87c198d3`; the Flutter fork's `DEPS` is not in this tree, so hosted CI cannot
  check that. It was checked by hand on 2026-11-16 against an engine checkout at
  `d0714887`: `updater_rev` is `87c198d30f875a3da317d70935e1025dc13064dd`, and
  `selfhost/ci/engine_updater_evidence_guard.sh` (#206) is the check meant to run
  on a host that has the engine tree. **Flutter 3.50 (engine `e737ede3`, cell `a377ecb7`, 2026-11-22):** the supported pin now consumes `a58774ab8a88a04ae5f96ce4e5a9825561a2f2f3` (`DEPS` `updater_rev` at shorebird-flutter `52347b61`; `mml555/shorebird-updater-mirror`, upstream `91dbbddb958a` merged, 13 commits ahead of `87c198d3`), and `compatibility.yaml` says so. The vendored tree and the `87c198d3` readings in this file are not updated for it, and `tool/check_updater_pin.sh` compares `compatibility.yaml` with the vendored copy. The 2026-07 text below named engine
  `69f9831c360d9152862ec3897c67fb09ae843f3b`, which is no longer the pin. `BEHAVIORAL_FINDINGS.md` was captured on CLI 1.6.114 / Flutter
  `309dd6573a9fe716410489284cd325a34b950375` (engine `e1eaecbc…`), the pin
  before this one. Those findings carry forward: `updater_rev` in the Flutter
  fork's `DEPS` is byte-identical at both revisions
  (`1f85c4ab1ee5b540269b9859c75e1bffbb9050c7`), so the on-device updater — and
  therefore this entire contract — did not change **with the engine bump**.
  (Scoped 2026-08-13: that sentence is true of the *bump* and was read as
  "the contract has not changed", which is false — our own fork changed it a day
  later. See the fork warning at the top.) **The signature and
  verification-mode behaviour below is checked against the vendored `87c198d3`;
  the rest was written for `1f85c4ab`.** An older engine may lack the newest
  behaviours (see per-item notes); an engine built before updater#396
  (install-time verification) does not verify before download. If you need
  byte-exact fidelity to `e1eaec...`, resolve that commit from the engine DEPS
  and re-diff the four files cited most here: `events.rs`, `network.rs`,
  `updater.rs`, `cache/lifecycle.rs`.

## Endpoint URLs

The updater **hardcodes** the `/api/v1/` prefix (`network.rs`):

- `POST {base_url}/api/v1/patches/check`
- `POST {base_url}/api/v1/patches/events`

`base_url` comes from `shorebird.yaml` (`base_url:` key) or defaults to
Shorebird's cloud. Our server routes both `/api/v1/patches/*` and bare
`/patches/*` (`api.dart` `_isPublic` + device router), so both forms work; the updater only ever
sends the `/api/v1/` form.

Downloads go to whatever absolute `download_url` the check response carries — a
separate host/path is fine (our signed `/download/<token>?exp=&sig=` URLs work).

---

## 1. Event vocabulary (the FULL set)

There are exactly **four** event `type` strings at the pinned revision. **Our own
Route B cells add a fifth, `__patch_boot_lifecycle__` — see the 2026-08-23 addition at
the top of this file.** The enum and its wire strings are in `events.rs`:

| Wire `type` string          | Rust variant           | Meaning              |
|-----------------------------|------------------------|----------------------|
| `__patch_download__`        | `PatchDownload`        | patch downloaded + inflated + installed to disk |
| `__patch_install__`         | `PatchInstallSuccess`  | patch booted successfully for the first time |
| `__patch_install_failure__` | `PatchInstallFailure`  | patch failed to boot (crash-detected or engine-reported) |
| `__patch_update_failure__`  | `PatchUpdateFailure`   | download / inflate / hash / install step failed |

Deserialization rejects any unknown string (`events.rs`) — but that only
affects the updater reading a response; our server never sends these back.

### Payload shape (identical for all four types; the lifecycle event adds five optional fields — see the 2026-08-23 addition)

Wrapped in a top-level `event` object (`network.rs`, `send_patch_event`
at `network.rs`). Field names and order are fixed by `PatchEvent`
(`events.rs`):

```json
{
  "event": {
    "app_id": "<shorebird app_id>",
    "arch": "aarch64",
    "client_id": "<stable per-install UUID>",
    "type": "__patch_download__",
    "patch_number": 1,
    "platform": "android",
    "release_version": "1.0.0+1",
    "timestamp": 1784867493,
    "message": null
  }
}
```

- `type` is the JSON key (`#[serde(rename = "type")]`, `events.rs`); the Rust
  field is `identifier`.
- `timestamp` — Unix epoch **seconds** (`u64`).
- `message` — nullable string; **never** null for the two failure events (see
  below), always null for download/install-success. Must never contain PII
  (`events.rs`).
- Exact serialization is asserted by the crate's own tests
  (`network.rs`): confirms our `BEHAVIORAL_FINDINGS.md` capture is
  byte-accurate.

### When each event fires

#### `__patch_download__` — after install, before restart
Fired at the **end of a successful `update()` cycle**, once the patch is
downloaded, zstd-inflated against the base, hash-checked, written to
`dlc.vmcode`, and promoted to `next_boot_patch`
(`updater.rs`, inside `install_downloaded_patch`).
- **Queued to disk, then flushed on a spawned thread** (`updater.rs`
  `queue_or_send_event`, then `spawn_event_flush`). Only if the queue cannot be
  saved is the event sent once on its own thread instead.
- The patched code is NOT yet running — it runs on the next app restart.
- `message: null`.

#### `__patch_install__` — after successful boot (boot-success)
Fired from `report_launch_success()` (`updater.rs`), which the engine's
`Shell` constructor calls once the Dart VM has booted from the patch
(`docs/boot_state_machine.md:99-116`).
- **Only fires the first time a given patch number boots**: it compares
  `last_successfully_booted_patch` before vs after and suppresses the event if
  the number is unchanged (`updater.rs`). Re-launches of an
  already-booted patch send nothing.
- **Queued to disk, then flushed on a spawned thread**, as for
  `__patch_download__`: `report_launch_success` calls `queue_or_send_event`, then
  `spawn_event_flush` when anything is queued.
- `message: null`.
- **This IS the "boot-success" signal.** `BEHAVIORAL_FINDINGS.md` already
  observed it (labeled `__patch_install__`); there is no separate boot-success
  type. The sequence is: launch N downloads → `__patch_download__`; launch N+1
  boots the patch → `__patch_install__`.

#### `__patch_install_failure__` — patch failed to boot
Two trigger paths, **both queued to disk** by `queue_event`, because the engine
typically `abort()`s right after a boot failure:

1. **Crash-detected at next init** (`updater.rs`,
   `handle_prior_boot_failure_if_necessary`): if a prior process set the
   `currently_booting_patch` breadcrumb but never recorded success (it crashed
   mid-boot), the next `init()` marks the patch `Bad{BootCrash}` and queues this
   event with `message: "crash_recovery: patch N failed to boot (detected_at=…,
   boot_started_at=…,file_ok=…,file_size=…)"`.
2. **Engine-reported** (`updater.rs`, `report_launch_failure`): the
   engine calls this when a patch load fails; queues with
   `message: "engine_report: patch N failed to launch"`.

These are not flushed by a thread of their own. They go out in the next flush: the
one `update_internal` runs at the start of the next `update()` cycle, or the one
`report_launch_success` starts on a later launch that has anything queued (also
when `auto_update` is off). So they arrive on a later launch, not in real time.

#### `__patch_update_failure__` — download/apply step failed
Fired when `download_and_install_patch` returns an error inside `update_internal`
(`updater.rs`). Covers: download network failure, download size mismatch
vs `Content-Length`, zstd/bipatch inflate failure, and post-inflate hash
mismatch. **Queued to disk** with
`message: "update_failure: patch N failed (<truncated error, ≤256 chars>)"`
(`updater.rs`, `truncate_error_message` at `updater.rs`).

> **NOT yet observed on-device (per `BEHAVIORAL_FINDINGS.md`):**
> `__patch_install_failure__` and `__patch_update_failure__`. Both require an
> actual failure (a crash between launch-start and launch-success, or a broken
> download/patch). They are stored fine by our server generically, but are
> invisible in our metrics — see §6.

---

## 2. `POST /api/v1/patches/check`

### Request (`PatchCheckRequest`, `network.rs`)

```json
{
  "app_id": "…",
  "channel": "stable",
  "release_version": "1.0.0+1",
  "platform": "android",
  "arch": "aarch64",
  "client_id": "<uuid>",
  "current_patch_number": 1
}
```

- `current_patch_number` — `Option<usize>`, **omitted entirely when null**
  (`#[serde(skip_serializing_if = "Option::is_none")]`, `network.rs`). On a
  fresh install it is absent, not `0`. It equals `state.running_patch().number`
  — the patch this process is actually running (`updater.rs`).
- It **supersedes** a legacy `patch_number` field the server may still read for
  old clients (`network.rs`). Our server accepts either plus a `0`
  fallback (`api.dart` `_patchesCheck`).
- `channel` is currently informational (staged rollout is future work per the
  source comment, `network.rs`), but our server DOES key patches by
  channel and does deterministic per-client rollout bucketing
  (`api.dart` `_patchesCheck`).

### Response (`PatchCheckResponse`, `network.rs`)

```json
{
  "patch_available": true,
  "patch": {
    "number": 1,
    "download_url": "https://host/download/<token>?exp=…&sig=…",
    "hash": "<hex sha256 of the INFLATED output>",
    "hash_signature": "<base64 RSA sig, or omitted>"
  },
  "rolled_back_patch_numbers": [2]
}
```

- `patch` is `Option`, `#[serde(default)]` (`network.rs`) — may be null
  or omitted when `patch_available` is false.
- `rolled_back_patch_numbers` is `Option<Vec<usize>>`, `#[serde(default)]`
  (`network.rs`) — omit, null, or `[]` are all fine.
- `Patch.hash_signature` is `Option`, `#[serde(default)]` (`network.rs`)
  — omit it when unsigned.
- `Patch.hash` **must be an even-length hex string** or the updater rejects the
  patch (`updater.rs` `check_hash`: "Invalid hash string from server"). It is
  compared as a string to the computed lowercase hex, so serve it lowercase. The legacy
  `"#"` sentinel is no longer accepted (`updater.rs`).

### What the updater does with the response

`patch_available` is checked first — if false, `NoUpdate`, no download
(`updater.rs`). Then the patch (if present) is fed to
`lifecycle.decide_start(number, download_url, hash)` (`updater.rs`),
which returns Fresh / Resume / Complete / Skip (see §4).

### `rolled_back_patch_numbers` behavior (device-verified + source-confirmed)

Processed on **every** check, before the patch is considered, in **both**
`check_for_downloadable_update` (`updater.rs`) and `update_internal`
(`updater.rs`) → `roll_back_patches_if_needed` (`updater.rs`):

```rust
for patch_number in patch_numbers {
    state.uninstall_patch(patch_number)?;   // updater.rs
}
```

`uninstall_patch` (`cache/updater_state.rs`) calls
`lifecycle.cleanup(n)` then `recompute_next_boot()`:
- `cleanup` deletes the patch's artifact files; a `Bad` patch keeps its
  tombstone, anything else has its whole dir forgotten
  (`cache/lifecycle.rs`).
- `recompute_next_boot` (`cache/lifecycle.rs`) repoints `next_boot_patch`
  to `last_booted_patch` **only if that patch is still `Installed`**, otherwise
  to `None` (base release). It will **not** clobber a still-valid newer
  `next_boot_patch`.

**Timing:** the currently-running process keeps running the rolled-back patch —
`running_patch` is a session-scoped in-memory value that deliberately survives
rollback (`updater.rs`, `cache/updater_state.rs`). The revert
takes effect on the **next restart**. This matches the device observation:
server withdrew patch 2 with rollback → check returned
`patch_available:false, rolled_back_patch_numbers:[2]` → **next launch** logged
"no active patch" and reverted to base.

Withdraw **without** rollback (number simply absent from the array) only stops
the server offering it to new checks; already-installed devices keep running it.
Our server distinguishes these via the `rollback` query flag on
`/admin/.../withdraw` (`api.dart` withdraw branch), and `rolledBackPatchNumbers` only
returns patches with `cp.rolled_back = true` (`repository.dart` `rolledBackPatchNumbers`).

---

## 3. `POST /api/v1/patches/events`

### Wrapper / shape
Exactly the `{ "event": { … } }` object from §1. One event per POST.
`send_patch_event` builds `CreatePatchEventRequest { event }` and POSTs it as
JSON (`network.rs`, `report_event_default` at `network.rs`).
Unauthenticated (no bearer). Any 2xx is success; our server returns `204`
(`api.dart` `_patchesEvents`, `204`). Response body is ignored. An
event that cannot be stored even verbatim (for example a NUL character on
Postgres) gets `422`, a permanent refusal, not a `500` the updater would retry.

### Queue / retry / offline behavior
This is the subtle part — two different delivery paths:

Every event type goes to the on-disk queue first (`queue_event`; the download and
install-success events through `queue_or_send_event`), and a flush sends from it.

- **When a flush runs** (`updater.rs`): `spawn_event_flush` runs
  `flush_queued_events` on a detached thread right after a patch is installed and
  after a launch that has events queued; `update_internal` also sends the queue at
  the start of every update cycle (`send_queued_events`, skipped if a flush already
  holds `EVENT_FLUSH_LOCK`).
- **How much per flush:** at most `MAX_EVENTS_PER_FLUSH` = **3** events, oldest
  first. The rest stay queued for the next flush; they are not dropped.
- **Acknowledgement:** an event is removed from the queue only after it was sent
  (`remove_event`), one at a time. There is no whole-queue clear.
- **Failure:** the first failed send stops the flush and leaves that event and the
  rest queued, to be retried by a later flush. The exception is an event the
  server refuses with `400`, `413` or `422` (`is_refused_event`): it is dropped,
  since resending gets the same answer. Other statuses (401, 403, 404, 407, 5xx)
  and network errors are retried.
- **Queue bound:** `MAX_QUEUED_EVENTS` = **50** (`cache/updater_state.rs`
  `queue_event`); beyond it the **oldest** events are dropped. If the queue cannot
  be saved at all, `queue_or_send_event` sends that one event once, with no retry.
- **Consequence:** delivery is at-least-once-attempted while the queue holds, with
  loss only on queue overflow, a refused event, a full disk, or an app that is
  never launched again. It is not "at-most-once".

### Dedup identifiers
The updater sends **no** dedup id and no idempotency key. Dedup is entirely the
server's job. Our server derives a dedupe key from six fields
(`api.dart` `_patchesEvents`):

```
client_id | app_id | release_version | patch_number | type | timestamp
```

> **SEVEN fields as of 2026-08-20**, with `outcome` appended **only when present** —
> so this six-field key is still byte-identical for every type documented in §1. See
> the 2026-08-23 addition at the top for why the sixth field alone was not enough.

`insertEvent` is append-only with this key as the uniqueness guard
(`repository.dart` `insertEvent`, called at `api.dart` `_patchesEvents`); duplicates are ignored.
This is robust for the immediate events (unique timestamps) and safe for the
queued failure events. Malformed JSON is still stored raw with no dedupe key
(`api.dart` `_patchesEvents`).

---

## 4. Download + apply

### The artifact
The `download_url` serves a **zstd-compressed bipatch binary diff**, not the
final code:
- Outer container: a single **zstd frame** (magic `28 B5 2F FD`), validated
  before inflate (`updater.rs`, `validate_compressed_patch` +
  `ZSTD_MAGIC`).
- Inner payload: a **bipatch** diff (4-byte magic + 4-byte version header) that
  is applied against the app's base `libapp.so`.

### Inflate + apply (`inflate`, `updater.rs`)
Streamed through a pipe: a decompression thread zstd-decompresses the download
into `bipatch::Reader`, which reconstructs the full `libapp.so` from the base +
diff, streamed to `dlc.vmcode`. On Android the base is read from the split APKs
(`updater.rs`); on iOS via an `ExternalFileProvider`
(`updater.rs`).

### Hash algorithm + WHAT it covers (confirms our finding)
- **Algorithm:** SHA-256, hex-encoded, streamed (`cache/signing.rs`,
  `hash_file`).
- **Covers the INFLATED OUTPUT, not the downloaded diff — for `kind: code`.**
  `check_hash` runs on `installed_path` — i.e. `dlc.vmcode`, the reconstructed
  `libapp.so` — AFTER inflate (`updater.rs`; `check_hash` at
  `updater.rs`). So for a code patch `Patch.hash` = `sha256(full
  reconstructed libapp.so)`.
- **For `kind: assets` the rule INVERTS** (added 2026-08-13 — the rule above was
  stated unconditionally and is wrong for the fork's second payload kind).
  `check_hash` runs on the **downloaded bytes, before install**
  (`updater.rs`), because an asset bundle is self-contained and there is
  no reconstruction step whose output could be verified — the archive *is* the
  artifact. So for an assets patch `Patch.hash` = `sha256(the bytes you serve)`,
  which is the one case where the server *could* recompute it.
- **The installed filename differs too, and it is load-bearing.** A code patch
  installs to `dlc.vmcode`; an assets patch installs to `dlc.assets`
  (`cache/lifecycle.rs`). The absence of the `.vmcode` substring is
  deliberate — it is how both `TryLoadFromPatch` and `PatchCarriesCode` decide
  whether a patch carries code, so `dlc.assets.vmcode` would boot-loop Android.
  `lifecycle.rs` says exactly this.
- **Server implication (already correct in our server):** the server can NOT
  recompute a patch's hash from the uploaded bytes (it only has the diff). Our
  server verifies **hash for release artifacts only** and **size only for patch
  artifacts** (`api.dart` (the `store.verify` calls on the upload and resumable-commit paths), `checkHash: art.ownerKind == 'release'`).
  This is the correct behavior and matches `BEHAVIORAL_FINDINGS.md`; a server
  that sha256-checked the uploaded patch diff would reject every patch. The
  CLI-provided patch `hash` (the inflate-output hash) is stored and echoed
  verbatim in the check response (`api.dart` `_patchesCheck`).
- Hash mismatch after inflate → patch marked `Bad{InstallHashMismatch}`, error
  returned, `__patch_update_failure__` queued (`updater.rs`).

### Signature verification
- **Algorithm:** RSASSA-PKCS1-v1_5 with SHA-256. `cache/signing.rs`
  `check_signature` base64-decodes the key and signature and hands them to the
  engine's verifier (`engine_callbacks::verify_signature`); its doc comment
  names the scheme. (Earlier text said the updater calls `ring`
  `RSA_PKCS1_2048_8192_SHA256`. `ring` is now only a `test-hooks` dependency;
  the verifier is the engine's. The accepted key sizes are UNVERIFIED here.)
- **What is signed:** the **lowercase hex SHA-256 string** of the file the device
  ends up holding (`Patch.hash`), as UTF-8 bytes (`check_signature` is passed
  `message.as_bytes()`), NOT the file bytes and not the downloaded diff.
  `hash_signature` in the response is base64.
- **Public key embedding:** base64 **DER** `RSAPublicKey`, carried in the
  generated (bundled) `shorebird.yaml` as `patch_public_key` (`yaml.rs`
  `YamlConfig`, read into `UpdateConfig.patch_public_key` in `config.rs`).
  Generation recipe: the doc comment on `cache/signing.rs` `check_signature`.
- **When verified:**
  1. **Download time, in every mode.** `updater.rs` `download_and_install_patch`
     calls `check_patch_signature(&patch.hash, patch.hash_signature, patch_public_key)`
     before any network fetch; the later `check_hash` on the inflated file ties
     the installed bytes to that hash. A refusal writes a `Bad{InvalidSignature}`
     tombstone for that exact (hash, signature) pair (`lifecycle.rs`
     `record_signature_refused`, `decide_start`), so a forged offer cannot block
     the genuine patch number.
  2. **Boot, only under `patch_verification: strict`.** `lifecycle.rs`
     `validate_installed_patch` (called by `validate_next_boot_patch`) re-hashes
     the installed file and re-verifies the stored signature only when
     `mode == Strict` **and** a public key is configured. Failure →
     `Bad{ValidationFailed}` and `recompute_next_boot`. In `install_only` it
     checks the file size only.
  3. `lifecycle.rs` `record_install_complete` carries the stored signature
     forward and does not re-verify.
- **The default mode is `install_only`** (`yaml.rs`: `#[default] InstallOnly` on
  `PatchVerificationMode`; test `default_verification_mode_is_install_only`).
  The pin before this one, `af6e842c`, defaulted to `strict`, and this file used to say
  "`strict` (default)", which is false for `87c198d3`. `selfhost/SIGNING.md`
  says what that means for an operator.
- **No `patch_public_key` configured:** `check_patch_signature` returns `Ok`, so
  the device installs whatever hash the server names, signed or not. With a key
  and no signature the offer is refused ("Patch signature is missing").
- **Who makes the signature (changed with upstream 1.6.138).** Still a
  pass-through for `customer` and unsigned releases: the CLI registers a
  `hash_signature` and the server stores and serves it unvalidated. For a
  release built in `managed` mode (the 1.6.138 CLI default: the build embeds the
  org key from `GET /apps/{app}/signing-key`) the server **generates** the
  signature when the patch artifact is registered, with exactly the scheme the
  updater verifies and the CLI's `CodeSigner` produces for customer keys:
  RSASSA-PKCS1-v1_5 / SHA-256 over the UTF-8 bytes of the hex `hash` string
  (`Signer('SHA-256/RSA')` in `code_signer.dart`; `RSA_PKCS1_2048_8192_SHA256`
  in `cache/signing.rs`), base64. Keys are RSA-2048, within the updater's
  2048-8192 range. A release made before this feature embeds no key, so its
  patches are never server-signed. Design and rules: `API_REFERENCE.md`,
  *Managed patch signing*. (This supersedes the earlier finding that signing was
  fully device-side.) The server never sees a customer's key, so it cannot tell a
  bad `customer` signature from a good one; the device refuses it. Today's
  self-hosted CLI never produces a `managed` release (see `SIGNING.md`).

### HTTP Range / resume / mid-download failure
`download_to_path_default` (`network.rs`) supports resume:
- On resume (`resume_from > 0`) it sends `Range: bytes={offset}-`
  (`network.rs`).
- **Only appends if the server answers `206`**; if the server ignores Range and
  returns `200`, it truncates and starts fresh (`network.rs`).
- Total size is read from `Content-Range` on 206 (`parse_content_range_total`,
  `network.rs`) or `Content-Length` on 200 (`network.rs`).
- **Size-mismatch guard:** if a `Content-Length`/`Content-Range` total was
  advertised and the received bytes differ, the patch is uninstalled and the
  cycle bails with "Download size mismatch" (`updater.rs`) — surfaces as
  `__patch_update_failure__`.

Resume is driven by the lifecycle state machine `decide_start`
(`cache/lifecycle.rs`):
- No prior state → `Fresh`.
- `Downloading` with matching **url AND hash** and a partial file present →
  `Resume { offset = partial file size }` (`cache/lifecycle.rs`).
- `Downloaded` with matching url+hash and file present → `Complete` (skip
  network, go straight to install) (`cache/lifecycle.rs`).
- `Installed` → `Skip(AlreadyInstalled)`; `Bad` → `Skip(KnownBad)`
  (`cache/lifecycle.rs`).
- **A url OR hash mismatch discards prior bytes → `Fresh`**
  (`cache/lifecycle.rs`). `record_download_started` is written to disk
  *before* the network call so a killed download can resume next time
  (`updater.rs`).

Mid-download failure (connection drop / truncated stream): the `Downloading`
state persists, so the next update cycle resumes from the partial file — **iff**
the server offers the same `download_url` string again.

> **Interaction gap with our rotating signed URLs (important):** our
> `download_url` embeds `exp`/`sig` that **rotate on every check**
> (`api.dart` `_signedUrl`, used). `decide_start` compares the stored `url` to the freshly
> offered one by exact string (`cache/lifecycle.rs`). Because the
> query string differs every check, the comparison fails → `DownloadAction::
> Fresh` → **resume across update cycles never triggers**; the partial is
> discarded and the patch is re-downloaded from scratch. This is not a
> correctness bug (Fresh is safe), but it silently defeats the resume
> optimization. If resume matters (large patches, flaky networks), sign a
> **stable** URL (e.g. move `exp`/`sig` into headers, or make the signed path
> component stable across a patch's lifetime). Our server does correctly return
> `206` + `Content-Range` + `Accept-Ranges: bytes` (`api.dart` `_download`) and even
> has a `fail_after` fault-injection knob (`api.dart` `_download`, `fail_after`) for testing
> truncation — so the server side of resume is ready; only the URL rotation
> undercuts it.

---

## 5. Boot / rollback state machine (for completeness)

- `report_launch_start` sets the `currently_booting_patch` breadcrumb + timestamp
  on disk (`updater.rs`; `cache/lifecycle.rs`). No event.
- Engine boots the Dart VM → `report_launch_success` promotes booting →
  `last_booted_patch`, clears the breadcrumb, and (first boot only) sends
  `__patch_install__` (`updater.rs`).
- If the process dies between start and success, the breadcrumb survives; next
  `init()` detects it and marks the patch `Bad{BootCrash}`, queuing
  `__patch_install_failure__` (`updater.rs`;
  `docs/boot_state_machine.md:62-73`).

  > **CHANGED IN OUR CELLS — 2026-08-19/20.** That single-strike retirement on an
  > ambiguous death is exactly the defect the lifecycle work removed. A pre-success
  > disappearance with **no explicit failure report** is now AMBIGUOUS: it is retried
  > and reported non-terminally (`ambiguous_boot_retry`), and retires only under an
  > explicitly chosen threshold. An **explicit** Dart-phase failure still retires on
  > the first strike. The asymmetry is the point — retiring too late costs one more
  > bad launch and self-corrects; retiring too early permanently tombstones a WORKING
  > patch on that device, invisibly, and reports it as the safety mechanism working.
  > Contract: [`LIFECYCLE_POLICY.md`](LIFECYCLE_POLICY.md). Frozen behaviour:
  > [`MEASUREMENT_MODE.md`](MEASUREMENT_MODE.md).
- **Local (client-side) rollback:** a `Bad` patch is never retried within the
  release; `recompute_next_boot` falls back to `last_booted_patch` (if still
  `Installed`) or base. This is independent of server-driven
  `rolled_back_patch_numbers`.

---

## 6. Server implications & gaps vs. `packages/code_push_server`

### What the server MUST do (and does)
| Contract requirement | Server status |
|---|---|
| Accept `POST /api/v1/patches/check` with the **8** request fields (7 + `supported_patch_kinds`; corrected 2026-08-13), treat `current_patch_number`/legacy `patch_number` as "don't offer ≤ this" | ✅ `api.dart` `_patchesCheck` |
| Respond with `patch_available` + optional `patch{number,download_url,hash,hash_signature,kind}` (**5** fields — `kind` added by our own fork, corrected 2026-08-13) + `rolled_back_patch_numbers` | ✅ `api.dart` `_patchesCheck` response block |
| Send a valid **hex** `hash` = the CLI-registered inflate-output hash (echo, don't recompute) | ✅ `api.dart` `_patchesCheck` |
| Verify **size** (not hash) for patch artifacts; hash only for release artifacts | ✅ `api.dart` (the `store.verify` calls on the upload and resumable-commit paths) — correct per contract |
| Pass `hash_signature` through untouched (`customer`/unsigned); generate it for `managed` releases | ✅ `_patchHashSignature` on upload, stored value served by `_patchesCheck` |
| Serve downloads with `Content-Length`, honor `Range` with `206` + `Content-Range` + `Accept-Ranges` | ✅ `api.dart` `_download`, `206` |
| Populate `rolled_back_patch_numbers` from patches withdrawn with rollback=true | ✅ `api.dart` `_patchesCheck`, `repository.dart` `rolledBackPatchNumbers` |
| Accept unauthenticated `POST /api/v1/patches/events` with the `{event:{…}}` wrapper, 2xx | ✅ `api.dart` `_patchesEvents` (`204`) |
| Dedup events (no client-side dedup exists) | ✅ **7-field** dedupe key as of 2026-08-20 (`outcome` appended only when present, so pre-existing types are unchanged), `eventDedupeKey` + `api.dart` `_patchesEvents`, `repository.dart` `insertEvent` |
| Store the boot-lifecycle event's five optional fields in queryable columns | ✅ migrations 9 + 10 (`outcome`, `ambiguous_attempt_count`, `boot_failure_threshold`, `boot_started_at`, `updater_revision`) with two indexes; read by `bootLifecycleMetrics()` |
| Store all event `type`s, including the two failure types, generically | ✅ generic `insertEvent`, won't crash on any type string |

### Gaps / recommendations (NOT changing server code — research findings)

1. ~~**Failure events are invisible in metrics (main gap).**~~ **DONE — this
   recommendation has shipped, corrected 2026-08-13.** `patchMetrics`
   (`repository.dart`) already carries the two clauses this section asked
   for, verbatim:
   `COUNT(*) FILTER (WHERE type = '__patch_install_failure__') AS install_failures`
   and `COUNT(*) FILTER (WHERE type = '__patch_update_failure__') AS update_failures`,
   and `GET /apps/{appId}/metrics` returns both — `API_REFERENCE.md` documents
   them as shipped, so the two documents were contradicting each other. Left in
   place rather than deleted because a live "main gap" that is actually closed
   costs somebody a re-implementation, which is the specific waste worth naming.
   The original text follows.

   ~~`patchMetrics` only counts `__patch_download__` and `__patch_install__`;
   the admin UI (`api.dart`) shows only downloads/installs.
   `__patch_install_failure__` and `__patch_update_failure__` are stored but
   never surfaced. These are the most operationally important signals — they are
   how you detect a bad patch in the field. **Recommend** adding the two
   `COUNT(*) FILTER` clauses to `patchMetrics`, and
   consider using them to auto-halt a rollout. Also capture the event `message`
   (crash-recovery / engine-report / update-failure diagnostics) — it carries
   `patch_number`, timing, file size, and a truncated root-cause string that is
   invaluable for triage. Confirm the events table actually persists `message`
   (the raw JSON is stored, so it's recoverable even if not columnized).

2. **These two failure types were never exercised on-device** (open item in
   `BEHAVIORAL_FINDINGS.md`). To close: inject a boot crash (kill the app between
   launch-start and launch-success, e.g. crash in `main()` of the patched code)
   to produce `__patch_install_failure__`; serve a corrupt/truncated patch (our
   `fail_after` download knob, `api.dart` `_download` `fail_after`) or a wrong `hash` to produce
   `__patch_update_failure__`. Note both are **queued** and arrive in a later
   flush, at most 3 per flush — a test must trigger a second check to see them.

3. **Rotating signed download URLs defeat cross-cycle resume** (see §4). Not a
   correctness issue; a bandwidth/robustness one. Optional fix if large patches
   over flaky networks become a concern.

4. **Event delivery is best-effort, not exactly-once.** At the old pin
   (`1f85c4ab`) download and install events were fire-and-forget and queued events
   were cleared after one attempt. At `87c198d3` every event is queued first and
   removed only once sent; a failed send is retried by a later flush, the queue
   holds at most 50 events (oldest dropped), and a `400`/`413`/`422` answer drops
   that event (see §3). Events can still be lost, and can arrive late, in bursts of
   three. The server should treat event counts as a **lower bound**, never assume exactly-once, and never make correctness decisions
   (e.g. billing, rollback gating) that require every event to arrive. Dedup
   protects against doubles; nothing protects against drops.

5. **No auth on events (by design).** `/patches/events` is public
   (`api.dart` `_isPublic`). `client_id` is a random per-install UUID with no meaning
   outside Shorebird (`network.rs`) and is spoofable. Treat event data as
   untrusted/attacker-influenceable for anything security-sensitive.

6. **Forward-compat:** the updater ignores unknown `shorebird.yaml` keys
   (`yaml.rs`) and unknown JSON response fields default cleanly
   (`#[serde(default)]`). The server can add response fields without breaking
   old updaters. Conversely, if you rely on `current_patch_number`, remember old
   clients send the legacy `patch_number` instead — our server already handles
   both (`api.dart` `_patchesCheck`).
