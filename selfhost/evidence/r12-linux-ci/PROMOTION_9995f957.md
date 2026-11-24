<!-- cspell:words ARMB -->
# Cell 9995f957 (f2458551 with Route B analysis 24): the promotion chain, run once on ci-build

All dates are 2026-11-23 and 2026-11-24, UTC throughout. The chain is `selfhost/TOOLCHAIN_PROMOTION.md`. It ran **once, with no resume**, in `/srv/ci-cache/shorebird-engine/promo-9995f957` on ci-build. That workspace was set up by `selfhost/engine/route_b/promo_clone.sh` (#286) from `promo-f2458551`, with an empty ledger.

This is a re-cell. The engine did not move:

- engine `09c6f4225d3ddf276fe4f3473beca79e038360b6`;
- Dart `0cd04a7717f20d5f9ae64014cb2239a3f961f895`;
- updater `64a458f034c86bca2eff6541a19d73781728b18f`;
- fallback engine `f0a7d29193ea6e077e02080a3511b405a4401b6f`.

The cell is `f2458551` re-minted by `mint_cell_v2.sh` (#283). The only change is the compiler archive, which now carries the Route B analyzer of #277 (analysis 24: an await is reported as `Future.then`, the #254 case). The two cells' canonical descriptors (`cell_manifests/*.v2`) differ in one line, `route-b-compiler-darwin-arm64.zip`. Every other member, every device-bound byte among them, has the same canonical digest as in `f2458551`. It replaces `f2458551`.

    cell address       9995f9571ec94b60eca64ec7eaae5fa190285b4d   route-b-cell-v2, macos-ios-android, 30 members
    flutter_revision   8e996caeeba7d826cc27397660a996c1e6194d07   shorebird-flutter: parent is the engine commit 09c6f422 itself; delta = bin/internal/engine.version only
    engine bytes       09c6f4225d3ddf276fe4f3473beca79e038360b6   unchanged from f2458551
    fallback           f0a7d29193ea6e077e02080a3511b405a4401b6f
    dart               0cd04a7717f20d5f9ae64014cb2239a3f961f895
    compiler archive   bf5aabae2ab1cf5c78563e9974f2904a16b5cd2a3dae879fbba367b25724f53b   19767236 B; route_b_analyze.aot 24d20ed19d7be27041d90997e9ffcaba6964010d99c7a0b3294a2d4a25a99493
    updater_revision   64a458f034c86bca2eff6541a19d73781728b18f   unchanged

The selector `8e996cae` was read with `git ls-remote` and `gh api`:

- branch `selfhost/3.50-cell-9995f957`, tag `selfhost-flutter-cell-9995f957` (annotated tag object `279dddab`, tagged 2026-11-23T23:07:06Z);
- tree `79322e36`, parent the engine commit `09c6f422`;
- the delta is `bin/internal/engine.version` alone.

It is selected by PR #285 (merge `2f0b38a6`), which also adds `'9995f957'` -> `'0cd04a77'` to `DartSdkCompatibility`.

The CLI under test was `R12_REPO_SHA=a120bf7f2e4a50050d9fe19f7477ba08f830247d`, the head of #285. The record's `cli_revision` is the merge, `2f0b38a6990b60549152e282c73a66e8ec0ed906`. Both have the same `packages/shorebird_cli` tree (`2ac28976`) and the same `bin/internal` tree (`5fd95eb8`), checked with `git rev-parse <rev>:<path>`. So the pin is the CLI the chain ran. `cli_version` is `1.6.144+selfhost.1`, the pubspec version at the merge. The previous pin's trees were `368f4a2e` and `b891c868`.

## What was minted

The release is `cell-9995f957` on `mml555/shorebird`. From `gh release view cell-9995f957`: `createdAt` 2026-11-23T22:10:51Z, `publishedAt` 2026-11-23T23:19:49Z, targets `4f1dbe6b` (the merge of #283), not a prerelease. Sizes and digests are GitHub's asset digests.

| Asset | Bytes | SHA-256 |
|---|---|---|
| `cell-9995f957....tar` (the 30 addressed members) | 750210048 | `b3d49ac6008bb85ae7989dcdd86df47dc16cb401c16f86d52847067f6d74fc48` |
| `host-extras-9995f957....tar` (f2458551's 26 host files under the new address, by `carry_cell_extras.py`, #284; additive) | 848967680 | `fcead8ff81b860555e64a626759af36cc6af78ccd51ba7c43a1751dab4ccede1` |
| `cell_manifest.v2` (the descriptor; also in-tree at `selfhost/engine/route_b/cell_manifests/9995f957....v2`) | 4141 | `9995f9571ec94b60eca64ec7eaae5fa190285b4db253fb27435da4113b6de1e1` |
| `LAYOUT.txt` | 5993 | `4fd2e8e0a1d10444715a90b294424e22487217f6398656085c866f0b41ec1a99` |
| `CELL.txt`, `MANIFEST.sha256`, `PARTS.sha256`, `files.sha256` | | |
| the full 100-file overlay: `.tar.part-aa` | 1992294400 | `d671e17ef6f041d9c7b9ae0972a3ca59053a5b8d4541aede981c602066221c65` |
| `.tar.part-ab` | 1258496000 | `5fd438da3d4cb281020aac3ed99edf9845ab23bf8c702fbdb61a7c9d8797a3da` |
| the parts joined | | `de9bf52e8da1b24a36d8f3f1b176b348178b6554d3f4538b49bec57a2705fe5f`, as the release notes give it |

The full overlay is the 30 members plus 70 extras carried from `f2458551`. Among the extras, only `PROVENANCE.txt` changed: a `carried_to:` section now lists this cell's files.

Before publishing, on the Mac:

- `verify_cell_members.sh` gave 30 of 30 on both the mint and the full overlay.
- `sd1_bundle_cell.sh`, then `sd1_hydrate_cell.sh --host-extras`, printed `CELL HYDRATED FROM THE DURABLE DISTRIBUTION`, with 26 host files.

After the CDN on ci-build was wired, 101 overlay paths were each fetched through `http://10.0.0.41:8085`: 36 under `download.flutter.io`, 56 under `flutter_infra_release` and 9 under `download.shorebird.dev`. All 101 hashes matched the published bytes. `verify_cell_delivery.sh` (as fixed by #287) printed `DELIVERY VERIFIED` for the compiler archive: 9 of 9 members delivered, 8 of 8 `PROVENANCE.txt` hashes match.

The archive's `PROVENANCE.txt` header is the donor's: engine `09c6f422`, Dart `0cd04a77`, built 2026-11-22T18:29:30Z. Its `repacked` line names the substituted `route_b_analyze.aot`: analyzer v24 from PR 277 (fork/main `8e5014c1`), `analysisVersion 24` as the file self-reports.

## Gates

`chain.log` runs from 23:21:44Z to `CHAIN_DONE` 2026-11-23T23:52:22Z. Arm B started at 2026-11-24T01:04:12Z and printed `ARMB_DONE` at 01:15:38Z. The evidence is in [`promotion-9995f957/`](promotion-9995f957/).

| # | Gate | Result | Evidence |
|---|---|---|---|
| 1 | candidate exists in the owned Flutter mirror | PASS: `8e996cae` served at `refs/heads/selfhost/3.50-cell-9995f957` | `chain.log`, `guard_candidate.log` |
| 2 | exact `engine.version` | PASS: `9995f9571ec94b60eca64ec7eaae5fa190285b4d` | same |
| 3 | SEALED + COLD bootstrap discovery | PASS: `BOOTSTRAP COMPLETED under seal after 0 additions` | `bootstrap_discovery.log` |
| 4 | bootstrap manifest banked | PASS, 2 rows: `dart-sdk-linux-x64.zip` (227469081 B, sha `8f3d92e1...`, the same bytes as `f2458551`'s row) and `engine_stamp.json` (246 B, sha `2c12f813...`). Proxy mapping `73d6a0ec...` -> `371f7720` | `bootstrap_closure.tsv`, `proxy_mapping.tsv` |
| 5 | `bootstrap_closure_guard.sh` | PASS: `CLOSURE OK 8e996cae -> 9995f957`, 2 artifacts with size and sha256 verified (2 of 2 ledger rows), proxy mapping pinned | `guard_candidate.log` |
| 6 | fresh sealed cold bootstrap | PASS: arm BOOT1, exit 0, `Flutter 3.50.1-0.0.pre-254`. Sealed mirror: 7 requests, 5 overlay hits, 0 `/gcs/`, 0 non-overlay 200s. The two 502s are both `GET /`, the harness's probe | `arms/arm-BOOT1`, `boot1_access.txt`, `fresh_bootstrap_launch.log` |
| 7 | sealed release/patch artifact discovery | Arms 1 and 2 exit 0, and the self-tests exit 64/64. The harness's verdict is FAIL on one check, `arm 3 exited 0, expected 64`: the discovery control plane has one release, so the chooser is never reached. That is the designed outcome for this step, as in the `f2458551` record. 36 requests, 35 overlay hits, 0 `/gcs/`; the one 502 is `GET /` | `release_patch_discovery.log`, `rp_access.txt` |
| 8 | fresh Linux release/patch smoke | PASS: R12 arm A, fresh container, fresh cold mirror, exit 0 (container 23:42:18Z to 23:51:55Z). 39 requests, 37 overlay hits, 0 `/gcs/`, 0 non-overlay 200s; the two 502s are `GET /`. Arm 3 refused the chooser by name, exit 64 | `armA.log`, `armA_access.txt`, `arms/arm-A` |
| 8b | R12 arm B (`bin/armB_go.sh`) | PASS: fixture `1.0.1+1` on arm A's control plane (`releases_before.log` lists `0.8.1+1` and `1.0.0+1`), fresh container, fresh cold mirror, exit 0. Detector self-tests exit 64/64, release and patch published, the `--json` patch had 0 prompt hits, and arm 3 refused the chooser by name (exit 64). 39 requests, 37 overlay hits, 0 `/gcs/`, 0 non-overlay 200s; the two 502s are `GET /` | `armB.log`, `armB_access.txt`, `arms/arm-B` |

The request counts are the access logs' `handled request` lines, counted by `status`, by the `X-Overlay: hit` response header and by the `/gcs/` URI prefix, as `PROMOTION_f2458551.md` counted them. Every count equals `f2458551`'s. Bootstrap discovery added 0 closure rows.

## Engine and updater

Neither moved, so `engine_updater_evidence_guard.sh` was not re-run. The `f2458551` run applies: [`promotion-f2458551/engine_updater_evidence_guard.txt`](promotion-f2458551/engine_updater_evidence_guard.txt). `vendor/updater` is unchanged since that record.

## Device run

The iPhone 7 run of #254 is [`ios-cell-9995f957`](../../engine/route_b/evidence/ios-cell-9995f957/RESULT.md) (2026-11-23). The #254 patch was refused before upload. So was every edit that changes or carries a function with an `await` on a `Future` (`p06`, `p07`, `p08`, and a trio carrying `_start`), because the release has no `then` on `TickerFuture` (#289). Those edits published and ran under `f2458551`. An edit with no `await` (`p05`) published, ran and rolled back. The Android run is not done yet.

## Not done

- #289, then a re-run of the refused `await` edits on the iPhone.
- The Android run.
- `selfhost/engine/route_b/verify_supported_state.sh` was not run for this record.
- The items still open from `PROMOTION_f2458551.md`:
  - port the post-step-7 failure check into `selfhost/ci`;
  - make shorebird-flutter's `selfhost-engine-mirror` action read an overlay in parts;
  - re-read the updater's #453-#455 behaviour for `64a458f0`.
