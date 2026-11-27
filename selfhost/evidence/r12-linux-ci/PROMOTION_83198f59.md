<!-- cspell:words ARMB -->
# Cell 83198f59 (engine 88a7bf8c: all-or-nothing container rollback, already-loaded payload refused): the promotion chain, run once on ci-build

All dates are 2026-11-27, UTC throughout. The chain is `selfhost/TOOLCHAIN_PROMOTION.md`. It ran in `/srv/ci-cache/shorebird-engine/promo-83198f59` on ci-build, a workspace cloned from `promo-97f91aff` (by `selfhost/engine/route_b/promo_clone.sh`, as for `9995f957`). Whether its ledger was emptied was not checked for this record.

This is a new engine, and a replacement of cell `97f91aff`:

- engine `88a7bf8cdb2ad206eb91a2275d77a4304c23f98d`, the merge of mml555/shorebird-flutter #23;
- Dart `a42323e3f57d825c52c539578fede871bb71af09`, the `DEPS` `dart_sdk_revision` of that merge, itself the merge of dart-sdk-shorebird-lineage #10: Route B activation refuses a payload library that is already loaded with `invalid-bytecode`, instead of crashing;
- updater `64a458f034c86bca2eff6541a19d73781728b18f`, unchanged: the same as engine `09c6f422`'s;
- fallback engine `f0a7d29193ea6e077e02080a3511b405a4401b6f`, unchanged.

Since `09c6f422` (the engine of `9995f957`) the engine also gained the all-or-nothing container rollback (shorebird-flutter #20, lineage #8) and the Dart revision-label fix (shorebird-flutter #22, lineage #9). The cells between are not supported: `c9a5421c` / `04e5ef97` were withdrawn for a stale revision label in their Dart SDK zips, and `97f91aff` (engine `64abe347`, Linux promotion passed 2026-11-26) crashed on the iPhone; see [`ios-cell-97f91aff-activation-crash`](../../engine/route_b/evidence/ios-cell-97f91aff-activation-crash/RESULT.md).

    cell address       83198f598d638fb2b5848f64bb377f504185a3da   route-b-cell-v2, macos-ios-android, 30 members
    flutter_revision   b259cf5419ac79d1da59099b2ebbaa9f8f519877   shorebird-flutter: parent is the engine commit 88a7bf8c itself; delta = bin/internal/engine.version only
    engine bytes       88a7bf8cdb2ad206eb91a2275d77a4304c23f98d
    fallback           f0a7d29193ea6e077e02080a3511b405a4401b6f
    dart               a42323e3f57d825c52c539578fede871bb71af09
    compiler archive   36e59039f75932646ee66492b547e643a2ee7f54516b25fff6673ed1af6c9d37   19947818 B; route_b_analyze.aot 6db21b87e04bd0d6babef0fa054ae3fa475e12194eb5eb1142589cc82c595dd9 (analysis version 24, unchanged)
    updater_revision   64a458f034c86bca2eff6541a19d73781728b18f   unchanged

The selector `b259cf54` was read with `git ls-remote` and `gh api`:

- branch `selfhost/3.50-cell-83198f59`, tag `selfhost-flutter-cell-83198f59` (annotated tag object `576fe48e`, tagged 2026-11-27T00:12:42Z);
- commit date 2026-11-27T00:06:46Z, tree `415c8ed8`, parent the engine commit `88a7bf8c`;
- the delta is `bin/internal/engine.version` alone (stated by the owner; the parent and tree were read, the one-file diff was not re-read here).

It is selected by PR #307 (merge `910ff2502d7923768750c7940e43e6013f712af5`, which also contains #308, a `device_run` harness fix) and adds `'88a7bf8c'` and `'83198f59'` -> `'a42323e3'` to `DartSdkCompatibility`.

The CLI under test was `R12_REPO_SHA=6885b3fc6256b743ea364cb2b5f773e56215d87d`, the head of #307 (the discovery log's `cloned at` line). The record's `cli_revision` is the merge, `910ff250`. Both have the same `packages/shorebird_cli` tree (`dea8309747d6`), the same `bin/internal` tree (`05364f8d7bdf`) and the same `packages/code_push_server` tree (`afba38b52f09`), checked with `git rev-parse <rev>:<path>`. So the pin is the CLI the chain ran. `cli_version` is `1.6.144+selfhost.1`. The previous pin's trees were `d3f8639e` and `5fd95eb8`.

## What was minted

The cell was minted with helpers `0100bb3fc155ff2d09ce19cff2c7ebb60867236e` (the merge of #305), the `route-b-cell-v2` scope `macos-ios-android`, 30 members. Its descriptor is [`cell_manifests/83198f59....v2`](../../engine/route_b/cell_manifests/83198f598d638fb2b5848f64bb377f504185a3da.v2), 4141 B, sha256 `83198f598d638fb2b5848f64bb377f504185a3da878269ab7fbc77bf2bf50afe` (the address is its first 40 hex digits). The compiler archive `route-b-compiler-darwin-arm64.zip` was audited clean by `audit_route_b_compiler.sh`. Its `PROVENANCE.txt` names engine `88a7bf8c`, Dart `a42323e3`, `darwin-arm64`, built 2026-11-26T23:45:56Z, and the analyzer `route_b_analyze.aot` as `6db21b87...`.

The release is `cell-83198f59` on `mml555/shorebird`. From `gh release view cell-83198f59`: `createdAt` 2026-11-27T00:07:37Z, `publishedAt` 2026-11-27T00:25:48Z, target `6885b3fc` (the head of #307), not a prerelease. The two parts, `PARTS.sha256` and `files.sha256` were uploaded then. The cell tar, `host-extras`, `CELL.txt`, `LAYOUT.txt`, `MANIFEST.sha256` and `cell_manifest.v2` were uploaded by `repack.sh --run` at 2026-11-27T02:01Z to 02:05Z (asset `updatedAt`); its log is not kept here. Sizes and digests are GitHub's, read after that upload, and the cell tar and `host-extras` equal `shasum -a 256` of the files on the Mac that were uploaded.

| Asset | Bytes | SHA-256 |
|---|---|---|
| `cell-83198f59....tar` (the 30 addressed members) | 750404096 | `a6773274093756a5a1569fb4454391705b122a2ae870745873888c255eeffc6b` |
| `host-extras-83198f59....tar` (26 unaddressed host files; additive) | 848971776 | `73292158ac55f1d67fe3e6fc8d54b304b19341e76e2db58126cacf64f4bda8df` |
| `cell_manifest.v2` | 4141 | `83198f598d638fb2b5848f64bb377f504185a3da878269ab7fbc77bf2bf50afe` |
| `LAYOUT.txt` | 5990 | `e3cd72ea5b1bcb3d803e52e42d19f7a041bd06370a47edd57cdf4a00c3de6eac` |
| `CELL.txt` | 386 | `d16b49f8cd73c70b5f605da8c99711368f1cad20e349f653ee9cf703ee08ad1e` |
| `MANIFEST.sha256` | 276 | `c5c79bfc32e1b606f257b134ee15ce010d20ef6f987a33e39c2bccce0f79705e` |
| `PARTS.sha256` | 248 | `a7fd8e04e134362861e82d004e14920297dc7f71ef3a5728bec90484ab80edba` |
| `files.sha256` | 19237 | `0d0ccb3ea90b13b4303a2ecee3c5c2865f19745f551fffc373797476c964a111` |
| the 100-file overlay: `.tar.part-aa` | 1992294400 | `885bbe83c4aae9d1dd4dd4febe401eebb62d4cf4d210a8fef41ab33c39117074` |
| `.tar.part-ab` | 1258720768 | `93736ee5af686f328ed4326423fb5b50bd7c29e776a1e8d0ab47334c809e7ce9` |
| the parts joined | | `4c793fc1f71726130d03f2c3d93ae7405974e911eefe1813d3353bc8fecfd322`, as the release notes give it (not recomputed) |

On ci-build: the install served 100 files from the overlay; the engine audits (`linux-android`, `macos-ios`, `macos-ios-android`) and the cell audits (`macos-ios`, `macos-ios-android`) were clean, and the cell manifest is served. (Reported by the minting session; the audit logs are not in this repository.)

## Gates

`chain.log` runs from 00:32:39Z to `CHAIN_DONE` 01:14:22Z. Arm B ran as a fresh container from 01:38:55Z to 01:48:41Z and printed `ARMB_DONE` at 01:49:10Z. The evidence is in [`promotion-83198f59/`](promotion-83198f59/) (copied read-only from ci-build, as for `9995f957`; `rp_arms.txt` is new, the output of `check_rp_arms`).

| # | Gate | Result | Evidence |
|---|---|---|---|
| 1 | candidate exists in the owned Flutter mirror | PASS: `b259cf54` served at `refs/heads/selfhost/3.50-cell-83198f59` | `chain.log`, `guard_candidate.log` |
| 2 | exact `engine.version` | PASS: `83198f598d638fb2b5848f64bb377f504185a3da` | same |
| 3 | SEALED + COLD bootstrap discovery | PASS: `BOOTSTRAP COMPLETED under seal after 0 additions` | `bootstrap_discovery.log` |
| 4 | bootstrap manifest banked | PASS, 2 rows: `dart-sdk-linux-x64.zip` (227470486 B, sha `c43c5b85...`) and `engine_stamp.json` (246 B, sha `70f3c1a1...`). Proxy mapping `8edc1049...` -> `371f7720` | `bootstrap_closure.tsv`, `proxy_mapping.tsv` |
| 5 | `bootstrap_closure_guard.sh` | PASS: `CLOSURE OK b259cf54 -> 83198f59`, 2 artifacts with size and sha256 verified, proxy mapping pinned | `guard_candidate.log` |
| 6 | fresh sealed cold bootstrap | PASS: arm BOOT1, exit 0 (container 00:36:18Z to 00:39:41Z), `Flutter 3.50.1-0.0.pre-273`, Dart 3.14.0. Sealed mirror: 7 requests, 5 overlay hits, 0 `/gcs/`, 0 non-overlay 200s. The two 502s are both `GET /`, the harness's probe | `arms/arm-BOOT1`, `boot1_access.txt` |
| 7 | sealed release/patch artifact discovery | `check_rp_arms`: ok. Arms 1 and 2 and both self-tests pass; arm 3 is the expected single-release exit 0. The harness's own verdict is FAIL on that one check, as for `9995f957` (the discovery control plane has one release, so the chooser is never reached). 36 requests, 35 overlay hits, 0 `/gcs/`; the one 502 is `GET /` | `release_patch_discovery.log`, `rp_arms.txt`, `rp_access.txt` |
| 8 | fresh Linux release/patch smoke | PASS: R12 arm A, fresh container, exit 0 (00:56:39Z to 01:13:51Z). 39 requests, 37 overlay hits, 0 `/gcs/`, 0 non-overlay 200s; the two 502s are `GET /`. Arm 3 refused the chooser by name, exit 64 | `armA.log`, `armA_access.txt`, `arms/arm-A` |
| 8b | R12 arm B | PASS: fixture on arm A's control plane (`releases_before.log` lists `0.8.1+1` and `1.0.0+1`), fresh container, exit 0. Detector self-tests exit 64/64, arm 3 refused the chooser by name (exit 64). 39 requests, 37 overlay hits, 0 `/gcs/`, 0 non-overlay 200s; the two 502s are `GET /` | `armB.log`, `armB_access.txt`, `arms/arm-B` |

The request counts are the access logs' `handled request` lines, counted by `status`, by the `X-Overlay: hit` response header and by the `/gcs/` URI prefix, as `PROMOTION_9995f957.md` counted them; every count equals `9995f957`'s. Bootstrap discovery added 0 closure rows. The discovery log shows the container being recreated because its environment named an older revision of the CLI (`5ea19ad0`, wanted `6885b3fc`), then running at `6885b3fc`.

## Engine and updater

The updater did not move (`64a458f0`, the same `DEPS` `updater_rev` as engine `09c6f422`), so `engine_updater_evidence_guard.sh` was not re-run. The `f2458551` run applies: [`promotion-f2458551/engine_updater_evidence_guard.txt`](promotion-f2458551/engine_updater_evidence_guard.txt). The engine did move (`09c6f422` to `88a7bf8c`); that the updater `DEPS` pin is the same at both is the owner's statement, not re-read here.

## Device run

The iPhone 7 run is [`ios-cell-83198f59-forced-partial`](../../engine/route_b/evidence/ios-cell-83198f59-forced-partial/RESULT.md) (2026-11-26, local clock): app `dev.selfhost.untab` release `1.0.0+79`, signed with a fresh key, CLI `6885b3fc`. Patch 1 (the 3-target `p06_async_return` + `p03_setstate_closure` patch) applied 3/3. Three forged patches were each refused and rolled back as a whole: `retarget-last` (`target-missing`, 2/2 rolled back), `reuse-first-payload` (`ROUTEB: payload library ... is already loaded`, `REFUSED (invalid-bytecode)`, 2/2) and `append` (`target-missing`, 3/3). After each, the next boot logged `Patch N is known bad, skipping` and ran patch 1 at 3/3. No crash report. The engine of the superseded `97f91aff` crashed on a forged patch: [`ios-cell-97f91aff-activation-crash`](../../engine/route_b/evidence/ios-cell-97f91aff-activation-crash/RESULT.md).

The Android run is [`android-cell-83198f59`](../../engine/route_b/evidence/android-cell-83198f59/RESULT.md) (2026-11-26, local clock): OnePlus CPH2551, Android 16, arm64 only (arm32 and x86_64 uploaded, not run), app `dev.selfhost.untab.android` release `1.0.0+1`, CLI `6885b3fc` (trees equal `910ff250`'s), signed with a fresh key. Patch 1 (`t254`) and patch 2 (the `awaits` set) each logged `Patch signature is valid` and `Launch success for patch N` (G4; then G2, `count=10..50`, `events=5`). A rollback of patch 2 (`Rolled back: yes`) still ran patch 2 on the learn boot, and the next two boots ran patch 1. No negative signing cases were run; under patch 1 the `route=R1` and `detail=D1` lines are missing because of a harness limit (no frame for the post-frame callback), not a patch defect.

## Not done

- Android device run (above).
- `verify_supported_state.sh`: SUPPORTED STATE VERIFIED (rc 0), run 2026-11-27 with SHOREBIRD_ROOT = a bootstrapped checkout at the recorded selector and OVERLAY = the minted overlay; PyYAML absent, so the stricter load was skipped
- Unsigned patches and ordinary async/`Future` patch shapes were not run on this cell. The `9995f957` runs do not carry over to a new engine.
- The items still open from `PROMOTION_f2458551.md`:
  - port the post-step-7 failure check into `selfhost/ci`;
  - make shorebird-flutter's `selfhost-engine-mirror` action read an overlay in parts;
  - re-read the updater's #453-#455 behaviour for `64a458f0`.
