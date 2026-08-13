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
>   `["code","assets"]` (`network.rs:290,307`; no `skip_serializing_if`, so it
>   is never omitted). It is a **capability gate**: our server withholds an
>   assets-only patch unless the client names `assets`
>   (`api.dart` `_patchesCheck`, the `supportedKinds.contains(assetsPatchKind)`
>   branch).
> * **Response `patch` object** — a fifth field `kind`
>   (`network.rs:228 pub kind: PatchPayloadKind`), always present from our
>   server: `code` normally, `assets` for an assets-only payload.
>
> So the request is **eight** fields, not seven, and the patch object is
> **five**, not four — including in §6's requirement table. `compatibility.yaml`
> already documents `supported_patch_kinds`, so this file also disagreed with the
> pin manifest.
>
> **The server-side anchors were ALL stale and have been re-anchored
> (2026-08-13).** Every `api.dart:NNN` / `repository.dart:NNN` citation in this
> file pointed at unrelated code — that file has grown to 3074 lines, so
> `:147-151` landed in an artifact-table comment, `:703` in a releases route and
> `:745-753` in the IdP block. 32 citations were re-pointed and now lead with a
> **symbol name** (`_patchesCheck`, `_patchesEvents`, `_download`, `_isPublic`,
> `_signedUrl`, `rolledBackPatchNumbers`, `insertEvent`, `patchMetrics`) with the
> line as a hint. **Cite the symbol, not the line** — line anchors into a file
> this active decay within days, and a wrong anchor reads as authority.

Citations use `library/src/<file>.rs:<line>` against the pinned updater commit below.

## Provenance / version pinning

- **Updater source pinned to:** `shorebirdtech/updater` HEAD
  `1f85c4ab1ee5b540269b9859c75e1bffbb9050c7` (2026-07-02, "chore(deps): update
  mockall requirement (#365)"). The crate carries no release tag for the library
  itself (`library/Cargo.toml` is version `0.1.0`); the only tag in the repo is
  `shorebird_code_push-v2.0.7` (the Dart wrapper package, unrelated to the Rust
  library version). So there is no semantic version to pin — we pin the commit.
- **Engine → updater mapping is NOT discoverable from the updater repo alone.**
  Our engine revision is `69f9831c360d9152862ec3897c67fb09ae843f3b`; the updater
  commit it was built from lives in the Shorebird engine/buildroot DEPS, not
  here. `BEHAVIORAL_FINDINGS.md` was captured on CLI 1.6.114 / Flutter
  `309dd6573a9fe716410489284cd325a34b950375` (engine `e1eaecbc…`), the pin
  before this one. Those findings carry forward: `updater_rev` in the Flutter
  fork's `DEPS` is byte-identical at both revisions
  (`1f85c4ab1ee5b540269b9859c75e1bffbb9050c7`), so the on-device updater — and
  therefore this entire contract — did not change **with the engine bump**.
  (Scoped 2026-08-13: that sentence is true of the *bump* and was read as
  "the contract has not changed", which is false — our own fork changed it a day
  later. See the fork warning at the top.) **Everything below is pinned to
  updater HEAD and should be treated as "latest".** All behaviors documented
  here (HTTP Range/resume, `PatchVerificationMode` strict/install_only,
  `__patch_update_failure__`, `current_patch_number`) are present at this HEAD;
  an older engine may lack the newest of these (see per-item notes). If you need
  byte-exact fidelity to `e1eaec...`, resolve that commit from the engine DEPS
  and re-diff the four files cited most here: `events.rs`, `network.rs`,
  `updater.rs`, `cache/lifecycle.rs`.

## Endpoint URLs

The updater **hardcodes** the `/api/v1/` prefix (`network.rs:15-21`):

- `POST {base_url}/api/v1/patches/check`
- `POST {base_url}/api/v1/patches/events`

`base_url` comes from `shorebird.yaml` (`base_url:` key) or defaults to
Shorebird's cloud. Our server routes both `/api/v1/patches/*` and bare
`/patches/*` (`api.dart` `_isPublic` (:369) + device router (:533)), so both forms work; the updater only ever
sends the `/api/v1/` form.

Downloads go to whatever absolute `download_url` the check response carries — a
separate host/path is fine (our signed `/download/<token>?exp=&sig=` URLs work).

---

## 1. Event vocabulary (the FULL set)

There are exactly **four** event `type` strings. The enum and its wire strings
are in `events.rs:13-32`:

| Wire `type` string          | Rust variant           | Meaning              |
|-----------------------------|------------------------|----------------------|
| `__patch_download__`        | `PatchDownload`        | patch downloaded + inflated + installed to disk |
| `__patch_install__`         | `PatchInstallSuccess`  | patch booted successfully for the first time |
| `__patch_install_failure__` | `PatchInstallFailure`  | patch failed to boot (crash-detected or engine-reported) |
| `__patch_update_failure__`  | `PatchUpdateFailure`   | download / inflate / hash / install step failed |

Deserialization rejects any unknown string (`events.rs:34-47`) — but that only
affects the updater reading a response; our server never sends these back.

### Payload shape (identical for all four types)

Wrapped in a top-level `event` object (`network.rs:282-285`, `send_patch_event`
at `network.rs:301-307`). Field names and order are fixed by `PatchEvent`
(`events.rs:53-83`):

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

- `type` is the JSON key (`#[serde(rename = "type")]`, `events.rs:65`); the Rust
  field is `identifier`.
- `timestamp` — Unix epoch **seconds** (`u64`).
- `message` — nullable string; **never** null for the two failure events (see
  below), always null for download/install-success. Must never contain PII
  (`events.rs:80-82`).
- Exact serialization is asserted by the crate's own tests
  (`network.rs:362-401`): confirms our `BEHAVIORAL_FINDINGS.md` capture is
  byte-accurate.

### When each event fires

#### `__patch_download__` — after install, before restart
Fired at the **end of a successful `update()` cycle**, once the patch is
downloaded, zstd-inflated against the base, hash-checked, written to
`dlc.vmcode`, and promoted to `next_boot_patch`
(`updater.rs:611-635`, inside `install_downloaded_patch`).
- **Sent immediately, fire-and-forget on a spawned thread** (`updater.rs:624`).
- The patched code is NOT yet running — it runs on the next app restart.
- `message: null`.

#### `__patch_install__` — after successful boot (boot-success)
Fired from `report_launch_success()` (`updater.rs:1147-1204`), which the engine's
`Shell` constructor calls once the Dart VM has booted from the patch
(`docs/boot_state_machine.md:99-116`).
- **Only fires the first time a given patch number boots**: it compares
  `last_successfully_booted_patch` before vs after and suppresses the event if
  the number is unchanged (`updater.rs:1175-1184`). Re-launches of an
  already-booted patch send nothing.
- **Sent immediately, fire-and-forget on a spawned thread** (`updater.rs:1188`).
- `message: null`.
- **This IS the "boot-success" signal.** `BEHAVIORAL_FINDINGS.md` already
  observed it (labeled `__patch_install__`); there is no separate boot-success
  type. The sequence is: launch N downloads → `__patch_download__`; launch N+1
  boots the patch → `__patch_install__`.

#### `__patch_install_failure__` — patch failed to boot
Two trigger paths, **both queued to disk** (not sent immediately), because the
engine typically `abort()`s right after a boot failure:

1. **Crash-detected at next init** (`updater.rs:225-267`,
   `handle_prior_boot_failure_if_necessary`): if a prior process set the
   `currently_booting_patch` breadcrumb but never recorded success (it crashed
   mid-boot), the next `init()` marks the patch `Bad{BootCrash}` and queues this
   event with `message: "crash_recovery: patch N failed to boot (detected_at=…,
   boot_started_at=…,file_ok=…,file_size=…)"`.
2. **Engine-reported** (`updater.rs:1111-1145`, `report_launch_failure`): the
   engine calls this when a patch load fails; queues with
   `message: "engine_report: patch N failed to launch"`.

Queued events are flushed at the **start of the next `update()` cycle**
(`updater.rs:402-408`) — so they arrive on the next launch that reaches a patch
check, not in real time.

#### `__patch_update_failure__` — download/apply step failed
Fired when `download_and_install_patch` returns an error inside `update_internal`
(`updater.rs:459-480`). Covers: download network failure, download size mismatch
vs `Content-Length`, zstd/bipatch inflate failure, and post-inflate hash
mismatch. **Queued to disk** with
`message: "update_failure: patch N failed (<truncated error, ≤256 chars>)"`
(`updater.rs:463-476`, `truncate_error_message` at `updater.rs:487-494`).

> **NOT yet observed on-device (per `BEHAVIORAL_FINDINGS.md`):**
> `__patch_install_failure__` and `__patch_update_failure__`. Both require an
> actual failure (a crash between launch-start and launch-success, or a broken
> download/patch). They are stored fine by our server generically, but are
> invisible in our metrics — see §6.

---

## 2. `POST /api/v1/patches/check`

### Request (`PatchCheckRequest`, `network.rs:226-276`)

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
  (`#[serde(skip_serializing_if = "Option::is_none")]`, `network.rs:256`). On a
  fresh install it is absent, not `0`. It equals `state.running_patch().number`
  — the patch this process is actually running (`updater.rs:409-422`).
- It **supersedes** a legacy `patch_number` field the server may still read for
  old clients (`network.rs:250-257`). Our server accepts either plus a `0`
  fallback (`api.dart:1992`).
- `channel` is currently informational (staged rollout is future work per the
  source comment, `network.rs:236-237`), but our server DOES key patches by
  channel and does deterministic per-client rollout bucketing
  (`api.dart` `_patchesCheck` (:1970)).

### Response (`PatchCheckResponse`, `network.rs:288-298`)

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

- `patch` is `Option`, `#[serde(default)]` (`network.rs:291-292`) — may be null
  or omitted when `patch_available` is false.
- `rolled_back_patch_numbers` is `Option<Vec<usize>>`, `#[serde(default)]`
  (`network.rs:296-297`) — omit, null, or `[]` are all fine.
- `Patch.hash_signature` is `Option`, `#[serde(default)]` (`network.rs:218-219`)
  — omit it when unsigned.
- `Patch.hash` **must be valid hex** or the updater rejects the patch after
  download (`updater.rs:325-327`, `check_hash` runs `hex::decode`). The legacy
  `"#"` sentinel is no longer accepted (`updater.rs:1430-1437`).

### What the updater does with the response

`patch_available` is checked first — if false, `NoUpdate`, no download
(`updater.rs:433-435`). Then the patch (if present) is fed to
`lifecycle.decide_start(number, download_url, hash)` (`updater.rs:439-457`),
which returns Fresh / Resume / Complete / Skip (see §4).

### `rolled_back_patch_numbers` behavior (device-verified + source-confirmed)

Processed on **every** check, before the patch is considered, in **both**
`check_for_downloadable_update` (`updater.rs:306-308`) and `update_internal`
(`updater.rs:429-431`) → `roll_back_patches_if_needed` (`updater.rs:659-666`):

```rust
for patch_number in patch_numbers {
    state.uninstall_patch(patch_number)?;   // updater.rs:661-663
}
```

`uninstall_patch` (`cache/updater_state.rs:396-399`) calls
`lifecycle.cleanup(n)` then `recompute_next_boot()`:
- `cleanup` deletes the patch's artifact files; a `Bad` patch keeps its
  tombstone, anything else has its whole dir forgotten
  (`cache/lifecycle.rs:279-284`).
- `recompute_next_boot` (`cache/lifecycle.rs:644-670`) repoints `next_boot_patch`
  to `last_booted_patch` **only if that patch is still `Installed`**, otherwise
  to `None` (base release). It will **not** clobber a still-valid newer
  `next_boot_patch`.

**Timing:** the currently-running process keeps running the rolled-back patch —
`running_patch` is a session-scoped in-memory value that deliberately survives
rollback (`updater.rs:1085-1090`, `cache/updater_state.rs:309-315`). The revert
takes effect on the **next restart**. This matches the device observation:
server withdrew patch 2 with rollback → check returned
`patch_available:false, rolled_back_patch_numbers:[2]` → **next launch** logged
"no active patch" and reverted to base.

Withdraw **without** rollback (number simply absent from the array) only stops
the server offering it to new checks; already-installed devices keep running it.
Our server distinguishes these via the `rollback` query flag on
`/admin/.../withdraw` (`api.dart` withdraw branch (:2532-2556)), and `rolledBackPatchNumbers` only
returns patches with `cp.rolled_back = true` (`repository.dart` `rolledBackPatchNumbers` (:1352)).

---

## 3. `POST /api/v1/patches/events`

### Wrapper / shape
Exactly the `{ "event": { … } }` object from §1. One event per POST.
`send_patch_event` builds `CreatePatchEventRequest { event }` and POSTs it as
JSON (`network.rs:301-307`, `report_event_default` at `network.rs:136-140`).
Unauthenticated (no bearer). Any 2xx is success; our server returns `204`
(`api.dart` `_patchesEvents`, `204` at :2439). Response body is ignored.

### Queue / retry / offline behavior
This is the subtle part — two different delivery paths:

**Immediate (fire-and-forget), NOT queued, NOT retried:**
- `__patch_download__` (`updater.rs:624-634`) and `__patch_install__`
  (`updater.rs:1188-1200`) are each sent on a **detached `std::thread`**. If the
  send fails (offline, 5xx), the error is only logged (`updater.rs:632-633`,
  `1196-1199`) — **the event is lost**, never retried. At-most-once.

**Queued (disk-persisted), flushed once next cycle:**
- `__patch_install_failure__` and `__patch_update_failure__` are written to
  `state.queued_events` on disk via `queue_event`
  (`cache/updater_state.rs:420-423`).
- At the **start of the next `update()` cycle**, up to **3** queued events are
  copied and sent (`updater.rs:402-408`, `copy_events(3)` at
  `cache/updater_state.rs:425-432`), then the **entire** queue is cleared
  regardless of send success (`updater.rs:409-415`, `clear_events` at
  `cache/updater_state.rs:434-437`).
- **Consequences:**
  - **Cap of 3 per cycle** — if more than 3 are queued, the extras are dropped
    (never sent). Source comment: "We discard any events if we have more than 3
    queued to make sure we don't stall the client" (`updater.rs:401-402`).
  - **No persistent retry** — a failed send is not requeued; the clear happens
    unconditionally. Effectively at-most-once with one delivery attempt on the
    following update cycle.
  - Offline at flush time → those events are lost.

### Dedup identifiers
The updater sends **no** dedup id and no idempotency key. Dedup is entirely the
server's job. Our server derives a dedupe key from six fields
(`api.dart` `_patchesEvents` (:2407+)):

```
client_id | app_id | release_version | patch_number | type | timestamp
```

`insertEvent` is append-only with this key as the uniqueness guard
(`repository.dart` `insertEvent` (:1497), called at `api.dart` `_patchesEvents` (:2423)); duplicates are ignored.
This is robust for the immediate events (unique timestamps) and safe for the
queued failure events. Malformed JSON is still stored raw with no dedupe key
(`api.dart` `_patchesEvents` (:2437)).

---

## 4. Download + apply

### The artifact
The `download_url` serves a **zstd-compressed bipatch binary diff**, not the
final code:
- Outer container: a single **zstd frame** (magic `28 B5 2F FD`), validated
  before inflate (`updater.rs:689-723`, `validate_compressed_patch` +
  `ZSTD_MAGIC`).
- Inner payload: a **bipatch** diff (4-byte magic + 4-byte version header) that
  is applied against the app's base `libapp.so`.

### Inflate + apply (`inflate`, `updater.rs:845-1063`)
Streamed through a pipe: a decompression thread zstd-decompresses the download
into `bipatch::Reader`, which reconstructs the full `libapp.so` from the base +
diff, streamed to `dlc.vmcode`. On Android the base is read from the split APKs
(`updater.rs:354-357`); on iOS via an `ExternalFileProvider`
(`updater.rs:359-362`).

### Hash algorithm + WHAT it covers (confirms our finding)
- **Algorithm:** SHA-256, hex-encoded, streamed (`cache/signing.rs:7-23`,
  `hash_file`).
- **Covers the INFLATED OUTPUT, not the downloaded diff.** `check_hash` runs on
  `installed_path` — i.e. `dlc.vmcode`, the reconstructed `libapp.so` — AFTER
  inflate (`updater.rs:589-607`; `check_hash` at `updater.rs:325-348`). So
  `Patch.hash` in the check response = `sha256(full reconstructed libapp.so)`.
- **Server implication (already correct in our server):** the server can NOT
  recompute a patch's hash from the uploaded bytes (it only has the diff). Our
  server verifies **hash for release artifacts only** and **size only for patch
  artifacts** (`api.dart:1777,1850`, `checkHash: art.ownerKind == 'release'`).
  This is the correct behavior and matches `BEHAVIORAL_FINDINGS.md`; a server
  that sha256-checked the uploaded patch diff would reject every patch. The
  CLI-provided patch `hash` (the inflate-output hash) is stored and echoed
  verbatim in the check response (`api.dart:2099,2164`).
- Hash mismatch after inflate → patch marked `Bad{InstallHashMismatch}`, error
  returned, `__patch_update_failure__` queued (`updater.rs:595-607`).

### Signature verification
- **Algorithm:** RSA PKCS#1 v1.5, SHA-256, via `ring`
  `RSA_PKCS1_2048_8192_SHA256` (`cache/signing.rs:37-66`, `check_signature`).
- **What is signed:** the signature is over the **hex hash string** (the message
  passed to `verify` is the hex `hash` text as bytes, `cache/signing.rs:54`),
  NOT the raw file bytes. `hash_signature` in the response is base64.
- **Public key embedding:** base64-encoded **DER** `RSAPublicKey`, carried in
  `shorebird.yaml` as `patch_public_key` (`yaml.rs:26-27,68`), read into
  `config.patch_public_key`. Generation recipe is in the source doc-comment
  (`cache/signing.rs:25-35`: `openssl rsa -pubin … -RSAPublicKey_out -outform
  DER`).
- **When verified — depends on `patch_verification` mode** (`yaml.rs:1-12`):
  - `strict` (default): re-verified at **every boot** in
    `validate_next_boot_patch` → `validate_installed_patch`
    (`cache/lifecycle.rs:600-725`, sig check at `715-723`). Failure →
    `Bad{ValidationFailed}` + recompute next boot.
  - `install_only`: verified once at install time only (faster boot).
- If no `patch_public_key` is configured, signature verification is skipped
  (`cache/lifecycle.rs:716-722`). **Server is a pure pass-through** of
  `hash_signature` — it stores whatever the CLI registered
  (`api.dart:1549` on upload, `:2099`/`:2164` on serve) and never generates or validates signatures. Confirms
  `BEHAVIORAL_FINDINGS.md`: signing is fully device-side.

### HTTP Range / resume / mid-download failure
`download_to_path_default` (`network.rs:83-134`) supports resume:
- On resume (`resume_from > 0`) it sends `Range: bytes={offset}-`
  (`network.rs:88-91`).
- **Only appends if the server answers `206`**; if the server ignores Range and
  returns `200`, it truncates and starts fresh (`network.rs:110-121`).
- Total size is read from `Content-Range` on 206 (`parse_content_range_total`,
  `network.rs:167-173`) or `Content-Length` on 200 (`network.rs:100-106`).
- **Size-mismatch guard:** if a `Content-Length`/`Content-Range` total was
  advertised and the received bytes differ, the patch is uninstalled and the
  cycle bails with "Download size mismatch" (`updater.rs:547-556`) — surfaces as
  `__patch_update_failure__`.

Resume is driven by the lifecycle state machine `decide_start`
(`cache/lifecycle.rs:422-458`):
- No prior state → `Fresh`.
- `Downloading` with matching **url AND hash** and a partial file present →
  `Resume { offset = partial file size }` (`cache/lifecycle.rs:430-439`).
- `Downloaded` with matching url+hash and file present → `Complete` (skip
  network, go straight to install) (`cache/lifecycle.rs:441-451`).
- `Installed` → `Skip(AlreadyInstalled)`; `Bad` → `Skip(KnownBad)`
  (`cache/lifecycle.rs:453-456`).
- **A url OR hash mismatch discards prior bytes → `Fresh`**
  (`cache/lifecycle.rs:440,452`). `record_download_started` is written to disk
  *before* the network call so a killed download can resume next time
  (`updater.rs:521-529`).

Mid-download failure (connection drop / truncated stream): the `Downloading`
state persists, so the next update cycle resumes from the partial file — **iff**
the server offers the same `download_url` string again.

> **Interaction gap with our rotating signed URLs (important):** our
> `download_url` embeds `exp`/`sig` that **rotate on every check**
> (`api.dart` `_signedUrl`, used at :2097/:2162). `decide_start` compares the stored `url` to the freshly
> offered one by exact string (`cache/lifecycle.rs:433-434,445`). Because the
> query string differs every check, the comparison fails → `DownloadAction::
> Fresh` → **resume across update cycles never triggers**; the partial is
> discarded and the patch is re-downloaded from scratch. This is not a
> correctness bug (Fresh is safe), but it silently defeats the resume
> optimization. If resume matters (large patches, flaky networks), sign a
> **stable** URL (e.g. move `exp`/`sig` into headers, or make the signed path
> component stable across a patch's lifetime). Our server does correctly return
> `206` + `Content-Range` + `Accept-Ranges: bytes` (`api.dart` `_download` (:1889-1932)) and even
> has a `fail_after` fault-injection knob (`api.dart` `_download`, `fail_after` at :1903) for testing
> truncation — so the server side of resume is ready; only the URL rotation
> undercuts it.

---

## 5. Boot / rollback state machine (for completeness)

- `report_launch_start` sets the `currently_booting_patch` breadcrumb + timestamp
  on disk (`updater.rs:1092-1107`; `cache/lifecycle.rs:526-541`). No event.
- Engine boots the Dart VM → `report_launch_success` promotes booting →
  `last_booted_patch`, clears the breadcrumb, and (first boot only) sends
  `__patch_install__` (`updater.rs:1147-1204`).
- If the process dies between start and success, the breadcrumb survives; next
  `init()` detects it and marks the patch `Bad{BootCrash}`, queuing
  `__patch_install_failure__` (`updater.rs:225-267`;
  `docs/boot_state_machine.md:62-73`).
- **Local (client-side) rollback:** a `Bad` patch is never retried within the
  release; `recompute_next_boot` falls back to `last_booted_patch` (if still
  `Installed`) or base. This is independent of server-driven
  `rolled_back_patch_numbers`.

---

## 6. Server implications & gaps vs. `packages/code_push_server`

### What the server MUST do (and does)
| Contract requirement | Server status |
|---|---|
| Accept `POST /api/v1/patches/check` with the **8** request fields (7 + `supported_patch_kinds`; corrected 2026-08-13), treat `current_patch_number`/legacy `patch_number` as "don't offer ≤ this" | ✅ `api.dart` `_patchesCheck` (:1970) |
| Respond with `patch_available` + optional `patch{number,download_url,hash,hash_signature,kind}` (**5** fields — `kind` added by our own fork, corrected 2026-08-13) + `rolled_back_patch_numbers` | ✅ `api.dart` `_patchesCheck` response block (:2085-2170) |
| Send a valid **hex** `hash` = the CLI-registered inflate-output hash (echo, don't recompute) | ✅ `api.dart:2099,2164` |
| Verify **size** (not hash) for patch artifacts; hash only for release artifacts | ✅ `api.dart:1777,1850` — correct per contract |
| Pass `hash_signature` through untouched | ✅ `api.dart:1549` on upload, `:2099`/`:2164` on serve |
| Serve downloads with `Content-Length`, honor `Range` with `206` + `Content-Range` + `Accept-Ranges` | ✅ `api.dart` `_download` (:1889), `206` at :1925 |
| Populate `rolled_back_patch_numbers` from patches withdrawn with rollback=true | ✅ `api.dart:2000`, `repository.dart` `rolledBackPatchNumbers` (:1352) |
| Accept unauthenticated `POST /api/v1/patches/events` with the `{event:{…}}` wrapper, 2xx | ✅ `api.dart` `_patchesEvents` (:2407) (`204`) |
| Dedup events (no client-side dedup exists) | ✅ 6-field dedupe key, `api.dart` `_patchesEvents` (:2407+), `repository.dart` `insertEvent` (:1497) |
| Store all event `type`s, including the two failure types, generically | ✅ generic `insertEvent`, won't crash on any type string |

### Gaps / recommendations (NOT changing server code — research findings)

1. **Failure events are invisible in metrics (main gap).** `patchMetrics` only
   counts `__patch_download__` and `__patch_install__`
   (`repository.dart` `patchMetrics` (:1693)); the admin UI shows only downloads/installs
   (`api.dart:1597`). `__patch_install_failure__` and
   `__patch_update_failure__` are **stored but never surfaced**. These are the
   most operationally important signals — they are how you detect a bad patch in
   the field. **Recommend** adding
   `COUNT(*) FILTER (WHERE type='__patch_install_failure__') AS install_failures`
   and `… '__patch_update_failure__' AS update_failures` to `patchMetrics`, and
   consider using them to auto-halt a rollout. Also capture the event `message`
   (crash-recovery / engine-report / update-failure diagnostics) — it carries
   `patch_number`, timing, file size, and a truncated root-cause string that is
   invaluable for triage. Confirm the events table actually persists `message`
   (the raw JSON is stored, so it's recoverable even if not columnized).

2. **These two failure types were never exercised on-device** (open item in
   `BEHAVIORAL_FINDINGS.md`). To close: inject a boot crash (kill the app between
   launch-start and launch-success, e.g. crash in `main()` of the patched code)
   to produce `__patch_install_failure__`; serve a corrupt/truncated patch (our
   `fail_after` download knob, `api.dart` `_download` `fail_after` (:1903)) or a wrong `hash` to produce
   `__patch_update_failure__`. Note both are **queued** and arrive on the
   **following** update cycle, capped at 3 per cycle — a test must trigger a
   second check to see them, and must not queue >3.

3. **Rotating signed download URLs defeat cross-cycle resume** (see §4). Not a
   correctness issue; a bandwidth/robustness one. Optional fix if large patches
   over flaky networks become a concern.

4. **Event delivery is at-most-once.** Immediate events (download / install
   success) are fire-and-forget with no retry (`updater.rs:632`, `1196`); queued
   failure events get exactly one flush attempt then are cleared unconditionally
   (`updater.rs:409-415`). The server should treat event counts as a **lower
   bound**, never assume exactly-once, and never make correctness decisions
   (e.g. billing, rollback gating) that require every event to arrive. Dedup
   protects against doubles; nothing protects against drops.

5. **No auth on events (by design).** `/patches/events` is public
   (`api.dart` `_isPublic` (:344-378)). `client_id` is a random per-install UUID with no meaning
   outside Shorebird (`network.rs:247-249`) and is spoofable. Treat event data as
   untrusted/attacker-influenceable for anything security-sensitive.

6. **Forward-compat:** the updater ignores unknown `shorebird.yaml` keys
   (`yaml.rs:78`) and unknown JSON response fields default cleanly
   (`#[serde(default)]`). The server can add response fields without breaking
   old updaters. Conversely, if you rely on `current_patch_number`, remember old
   clients send the legacy `patch_number` instead — our server already handles
   both (`api.dart:1992`).
