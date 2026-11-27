<!-- cspell:words ARMB -->
# Cell c9208259 (engine 93adf4fb: a payload that does not load is refused, not fatal): the promotion chain, run once on ci-build

All dates are 2026-11-27, UTC throughout. The chain is `selfhost/TOOLCHAIN_PROMOTION.md`. It ran in `/srv/ci-cache/shorebird-engine/promo-c9208259` on ci-build, a workspace cloned from `promo-83198f59` (stated by the minting session's `PROMO_NOTE`; the clone script's log and whether the ledger was emptied were not checked for this record).

This is a new engine, and a replacement of cell `83198f59`:

- engine `93adf4fb25a26fe25e07bf953af33c0a48c435f2`, the merge of mml555/shorebird-flutter #24;
- Dart `e3f6fa90c141db6511844691bb58ca392ddda7da`, the `DEPS` `dart_sdk_revision` of that merge, itself the merge of dart-sdk-shorebird-lineage #11: Route B activation refuses a payload that does not load (an unsupported bytecode format version, or a reference the release lacks) with `invalid-bytecode`, instead of aborting the app before `main`; and a container stops at its first refused target;
- updater `64a458f034c86bca2eff6541a19d73781728b18f`, unchanged: the `DEPS` `updater_rev` at `93adf4fb`, read with `gh api repos/mml555/shorebird-flutter/contents/DEPS?ref=93adf4fb...`, is the same as at `88a7bf8c`;
- fallback engine `f0a7d29193ea6e077e02080a3511b405a4401b6f`, unchanged.

    cell address       c920825972cdc7e096fa114bbb616b306914c4c7   route-b-cell-v2, macos-ios-android, 30 members
    flutter_revision   246fd6f6fc70f2c4a7fb9b563eda5fcdccba2104   shorebird-flutter: parent is the engine commit 93adf4fb itself; delta = bin/internal/engine.version only
    engine bytes       93adf4fb25a26fe25e07bf953af33c0a48c435f2
    fallback           f0a7d29193ea6e077e02080a3511b405a4401b6f
    dart               e3f6fa90c141db6511844691bb58ca392ddda7da
    compiler archive   8fc9712898dbe4c9badd768ec36b74acc65adcc7fbf809431dbd270d51000fb7   19947858 B; route_b_analyze.aot c32198ff7ea64ffa37a1a67d148f7c7853735c71933ee1ba38f093da405e86a2
    updater_revision   64a458f034c86bca2eff6541a19d73781728b18f   unchanged

The selector `246fd6f6` was read with `git ls-remote` and `gh api`:

- branch `selfhost/3.50-cell-c9208259`, tag `selfhost-flutter-cell-c9208259` (annotated tag object `0fbf3d37`);
- commit date 2026-11-27T17:14:44Z, tree `fba09634`, parent the engine commit `93adf4fb`;
- the commit's file list from `gh api repos/mml555/shorebird-flutter/commits/246fd6f6...` is `bin/internal/engine.version` alone.

It is selected by PR #313 (merge `4a7b75ee690815ab9470fda2dbb23663b8b8503d`, merged 2026-11-27T18:33:06Z), which adds `'93adf4fb'` and `'c9208259'` -> `'e3f6fa90'` to `DartSdkCompatibility`.

The CLI under test was `R12_REPO_SHA=4a3adb1dfae837cf4c2d49061cdd5e25ea670391`, the head of #313 (the discovery log's `cloned at` line). The record's `cli_revision` is the merge, `4a7b75ee`. Both have the same `packages/shorebird_cli` tree (`9b4f836e6c70`), the same `bin/internal` tree (`58bdb1f8ce84`) and the same `packages/code_push_server` tree (`afba38b52f09`), checked with `git rev-parse <rev>:<path>`. So the pin is the CLI the chain ran. `cli_version` is `1.6.144+selfhost.1`, the pubspec version at the merge. The previous pin's trees were `dea83097` and `05364f8d`.

## What was minted

The cell was minted with helpers `aecb777779e54ff4e55027f523d9c3951ccc33b3` (`out/helpers.sha` of the mint), the `route-b-cell-v2` scope `macos-ios-android`, 30 members. Its descriptor is [`cell_manifests/c9208259....v2`](../../engine/route_b/cell_manifests/c920825972cdc7e096fa114bbb616b306914c4c7.v2), 4141 B, sha256 `c920825972cdc7e096fa114bbb616b306914c4c7ba206da74252f387179030d3` (the address is its first 40 hex digits; `shasum -a 256` of the file in this repository agrees). The compiler archive `route-b-compiler-darwin-arm64.zip` is the one in the mint's overlay; its sha256 `8fc97128...` is the listed digest in the overlay's `PROVENANCE.txt`, which names engine `93adf4fb`, Dart `e3f6fa90`, `darwin-arm64`, built 2026-11-27T15:40:22Z. `audit_route_b_compiler.sh --hash 93adf4fb... --overlay out/engine/merged` was run on the mint's merged overlay before the engine was published (mint log `audit_compiler.log`, 2026-11-27): every member present and matching its recorded hash, the served platform dill the one the address was computed over, Dart revision `e3f6fa90`, the capability probe advertising `--target flutter`, ending `AUDIT CLEAN`. The analyzer `route_b_analyze.aot` was unzipped from the archive and hashed (`c32198ff...`). `analysisVersion` in `selfhost/engine/route_b/coverage/analyze_coverage.dart` at the merge is 24; the `.aot` was not run to read its own version.

The release is `cell-c9208259` on `mml555/shorebird`. From `gh release view cell-c9208259`: `createdAt` 2026-11-27T17:15:37Z, `publishedAt` 2026-11-27T17:29:13Z, target `4a3adb1d` (the head of #313), not a prerelease. The two parts, `PARTS.sha256` and `files.sha256` were uploaded 17:21Z to 17:29Z. `CELL.txt`, `LAYOUT.txt`, `MANIFEST.sha256` and `cell_manifest.v2` were uploaded at 18:32:59Z, and the cell tar and `host-extras` at 18:37:50Z and 18:38:08Z (asset `updatedAt`), after the chain ran. An earlier read of the release during this work listed 8 assets, without those two tars. The read at 18:39Z, used below, lists all 10. The chain's bootstrap closure does not use the two tars (it reads the overlay's `dart-sdk-linux-x64.zip` and `engine_stamp.json` from the sealed overlay on ci-build).

| Asset | Bytes | SHA-256 |
|---|---|---|
| `cell-c9208259....tar` (the 30 addressed members) | 750414848 | `59eea64dde1ef697f5be5c3059613748498ebbda7fec62068f4e6c8b6ff1bd95` |
| `host-extras-c9208259....tar` (26 unaddressed host files; additive) | 848965120 | `91535311b4e5a6c9bf43d2ebcfe386a799544c1d3eae96ae053b6a774d665836` |
| `cell_manifest.v2` | 4141 | `c920825972cdc7e096fa114bbb616b306914c4c7ba206da74252f387179030d3` |
| `LAYOUT.txt` | 5990 | `e6f1097fb631216119418f74c59cd45a805e791fade9d809edcc17dec19ae614` |
| `CELL.txt` | 386 | `fe1ceeb76d716ef49e4b6e1e7c00733e0ac1421bbe585388ee88b0d7a45889ea` |
| `MANIFEST.sha256` | 276 | `d0c286332b2dbfadf8e34413318f6e4cb32d6c32b3bf033cc0d6bd75ff01d710` |
| `PARTS.sha256` | 248 | `be2e152b311f1ccb858925b1ce58f5fc8f4b57598cfdfdabb0500dfd7e752b3d` |
| `files.sha256` | 19237 | `52a8da8441a330ef3eaa6be06da351e95218afee8678d57ecda63d928a00e71f` |
| the 100-file overlay: `.tar.part-aa` | 1992294400 | `3280a1e76c387f1802ca1c213bf6130b9b477b498f64a2cb24dd6bfdc49a1887` |
| `.tar.part-ab` | 1258708992 | `eb51dbc5fbd324380952502eb8afadb6c1161d19e7a9ee5ecdbd93aa03671826` |
| the parts joined | | `57996bf7c5078ad5bbea9931beb7d1be9e9090c984c92a19dee8a6b2053dfa81`, as the release notes give it (not recomputed) |

Sizes and digests are GitHub's. They equal the minting session's `notes.md` and, for the tar, `MANIFEST.sha256` and `files.sha256`, the files in the mint's `out/dist` (compared by eye: the digests above are the same as in `notes.md` and `out/dist/MANIFEST.sha256`). The cell tar and `host-extras` were not downloaded and hashed here.

## Gates

`chain.log` runs from 17:40:26Z to `CHAIN_DONE` 18:14:50Z. Arm B ran as a fresh container from 18:17:22Z to 18:28:37Z (`ARMB_DONE`; its container ran 18:17:32Z to 18:27:59Z). The evidence is in [`promotion-c9208259/`](promotion-c9208259/) (copied read-only from ci-build, with the same shape as `promotion-83198f59/`, and the three logs `chain.log`, `armA.log` and `armB.log`).

| # | Gate | Result | Evidence |
|---|---|---|---|
| 1 | candidate exists in the owned Flutter mirror | PASS: `246fd6f6` served at `refs/heads/selfhost/3.50-cell-c9208259` | `chain.log`, `guard_candidate.log` |
| 2 | exact `engine.version` | PASS: `c920825972cdc7e096fa114bbb616b306914c4c7` | same |
| 3 | SEALED + COLD bootstrap discovery | PASS: `BOOTSTRAP COMPLETED under seal after 0 additions` | `bootstrap_discovery.log` |
| 4 | bootstrap manifest banked | PASS, 2 rows: `dart-sdk-linux-x64.zip` (227472064 B, sha `ed82214a...`) and `engine_stamp.json` (246 B, sha `16e1b9f0...`). Proxy mapping `ab776b17...` -> `371f7720` | `bootstrap_closure.tsv`, `proxy_mapping.tsv` |
| 5 | `bootstrap_closure_guard.sh` | PASS: `CLOSURE OK 246fd6f6 -> c9208259`, 2 artifacts with size and sha256 verified, proxy mapping pinned | `guard_candidate.log` |
| 6 | fresh sealed cold bootstrap | PASS: arm BOOT1, exit 0 (container 17:45:24Z to 17:49:10Z), `Flutter 3.50.1-0.0.pre-278`, Dart 3.14.0. Sealed mirror: 7 requests, 5 overlay hits, 0 `/gcs/`, 0 non-overlay 200s. The two 502s are both `GET /`, the harness's probe | `arms/arm-BOOT1`, `boot1_access.txt` |
| 7 | sealed release/patch artifact discovery | `check_rp_arms`: ok. Arms 1 and 2 and both self-tests pass; arm 3 is the expected single-release exit 0. The harness's own verdict is FAIL on that one check (`1 check(s) failed`), as for `83198f59` (the discovery control plane has one release, so the chooser is never reached). 36 requests, 35 overlay hits, 0 `/gcs/`; the one 502 is `GET /` | `release_patch_discovery.log`, `rp_arms.txt`, `rp_access.txt` |
| 8 | fresh Linux release/patch smoke | PASS: R12 arm A, fresh container, exit 0 (container 18:03:13Z to 18:14:24Z). 39 requests, 37 overlay hits, 0 `/gcs/`, 0 non-overlay 200s; the two 502s are `GET /`. Arm 3 refused the chooser by name, exit 64 | `armA.log`, `armA_access.txt`, `arms/arm-A` |
| 8b | R12 arm B | PASS: fixture on arm A's control plane (`releases_before.log` lists `0.8.1+1` and `1.0.0+1`), fresh container, exit 0. Detector self-tests exit 64/64, arm 3 refused the chooser by name (exit 64). 39 requests, 37 overlay hits, 0 `/gcs/`, 0 non-overlay 200s; the two 502s are `GET /` | `armB.log`, `armB_access.txt`, `arms/arm-B` |

The request counts are the access logs' `handled request` lines, counted by `status`, by the `X-Overlay: hit` response header and by the `/gcs/` URI prefix, as `PROMOTION_83198f59.md` counted them (re-counted here with a script over the copied logs); every count equals `83198f59`'s. Bootstrap discovery added 0 closure rows. The discovery log shows the container being recreated because its environment named an older revision of the CLI (`6885b3fc`, wanted `4a3adb1d`), then running at `4a3adb1d`.

## Engine and updater

The updater did not move (`64a458f0`, the same `DEPS` `updater_rev` as engine `88a7bf8c`), so `engine_updater_evidence_guard.sh` was not re-run. The `f2458551` run applies: [`promotion-f2458551/engine_updater_evidence_guard.txt`](promotion-f2458551/engine_updater_evidence_guard.txt). The engine did move (`88a7bf8c` to `93adf4fb`); the `DEPS` `updater_rev` at `93adf4fb` is `64a458f034c86bca2eff6541a19d73781728b18f` (read 2026-11-27 from shorebird-flutter at that commit).

## Device run

The iPhone 7 run is [`ios-cell-c9208259-forced-partial`](../../engine/route_b/evidence/ios-cell-c9208259-forced-partial/RESULT.md) (2026-11-27, local clock): app `dev.selfhost.untab` release `1.0.0+80`, signed with a fresh key, CLI `4a3adb1d`. Patch 1 (the 3-target patch) applied 3/3. Five forged patches were each refused and rolled back as a whole: `retarget-last` (`target-missing`, 2/2), `reuse-first-payload` (`ROUTEB: payload library ... is already loaded`, `REFUSED (invalid-bytecode)`, 2/2), `append` (`target-missing`, 3/3), and the two new modes, `bad-format-last` (`ROUTEB: payload does not load, refused: Unsupported Dart bytecode format version 4294967295`) and `unresolve-last` (`Unable to find library dart:cor_`), each `REFUSED (invalid-bytecode)` and rolled back 2/2. After each, the next boot logged `Patch N is known bad, skipping` and ran patch 1 at 3/3. No crash report. On engine `88a7bf8c` the two new modes aborted the app before `main`: [`device_run/README.md`](../../engine/route_b/device_run/README.md), "The two load-failure modes". That is why `83198f59` is superseded.

The Android run is [`android-cell-c9208259`](../../engine/route_b/evidence/android-cell-c9208259/RESULT.md) (2026-11-27, device clock): OnePlus CPH2551, Android 16, arm64 only (arm32 and x86_64 uploaded, not run), app `dev.selfhost.untab.android` release `1.0.0+1`, CLI `4a3adb1d`, signed with a fresh key. Patch 1 (`t254`) and patch 2 (the `awaits` set) each logged `Patch signature is valid` and `Launch success for patch N`. A rollback of patch 2 (`Rolled back: yes`) still ran patch 2 on the learn boot, and the next two boots ran patch 1. No negative signing cases were run. The Android CLI does not exercise the iOS engine change of this cell.

## Record checks

`tool/check_supported_state_record.sh` is run on this record's final text; see the PR body for the result. `verify_supported_state.sh` was not run for this record (it needs a bootstrapped checkout at the recorded selector and the minted overlay; neither is in this worktree).

## Not done

- Unsigned patches were not run on this cell. Ordinary async/`Future` patch shapes ran on Android only (`t254`, the `awaits` set), not on the iPhone. The `9995f957` runs do not carry over to a new engine.
- The Linux chain does not exercise the engine's load-failure refusal; only the iPhone run does.
- The items still open from `PROMOTION_f2458551.md`:
  - port the post-step-7 failure check into `selfhost/ci`;
  - make shorebird-flutter's `selfhost-engine-mirror` action read an overlay in parts;
  - re-read the updater's #453-#455 behaviour for `64a458f0`.
