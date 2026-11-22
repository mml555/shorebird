# Cell a377ecb7 over engine e737ede3 (Flutter 3.50): the promotion chain, run on ci-build in two parts

Date 2026-11-22 (UTC throughout). Chain: `selfhost/TOOLCHAIN_PROMOTION.md`, run as `PROMOTION_54117a2f.md` was, in two parts: run 1, then a resume script (`chain7.sh`) that re-ran steps 1 and 2 and steps 7 and 8 and added a check after step 7 that arms 1 and 2 did not fail. This is a **new engine**, not a
re-cell: engine `e737ede3bcf9b18c495498ada78a841e38b4a388` (shorebird-flutter branch `selfhost/3.50-up`, release
`engine-e737ede3...` on `mml555/shorebird-flutter`), Dart `0cd04a7717f20d5f9ae64014cb2239a3f961f895`, upstream
`flutter_engine_revision` `371f7720`, fallback engine `f0a7d29193ea6e077e02080a3511b405a4401b6f` (Shorebird
`flutter_release/3.50.0`). The cell is minted over the engine's published bytes. It replaces `54117a2f` (engine `d0714887`,
Dart `b4671ab7`, selector `f4024608`, CLI pin `37a0434b`).

    cell address       a377ecb7ae1c26172d6e9d517c42321726eec427   route-b-cell-v2, macos-ios-android, 30 members
    flutter_revision   52347b6108fa0e8b84b718e76c920e890da4c0a5   shorebird-flutter: parent is the engine commit e737ede3 itself; delta = bin/internal/engine.version only
    engine bytes       e737ede3bcf9b18c495498ada78a841e38b4a388   published members, byte for byte, except the seven rendered to the address
    fallback           f0a7d29193ea6e077e02080a3511b405a4401b6f
    dart               0cd04a7717f20d5f9ae64014cb2239a3f961f895
    compiler archive   8eb8438e41d26791ca4220293e817e3f1d6d3a6e48ffc278436163e37857de3c   19938443 B; route_b_analyze.aot 05ef9ae8...
    updater_revision   a58774ab8a88a04ae5f96ce4e5a9825561a2f2f3   DEPS updater_rev at the selector (was 87c198d30f87); restamped in compatibility.yaml and the record

The selector `52347b61` (branch `selfhost/3.50-cell-a377ecb7`, tag `selfhost-flutter-cell-a377ecb7`, annotated tag object
`88f0463c`, tree `e1b89f7e`) is selected by PR #263 (merge `64a64473`). #263 also adds `'e737ede3'` and `'a377ecb7'` to
`DartSdkCompatibility.expectedDartSdkRevisions`, both mapping to `'0cd04a77'`, and bumps `selfhost/fixtures/android_signing_app`
(below).

CLI under test. Run 1: `R12_REPO_SHA=3c93f596` (before the fixture bump). Resumed run: `R12_REPO_SHA=3001a3558adc20f35761403725521f2fc63463d1`,
the head of #263. The record's `cli_revision` is `64a64473db6fd735cf348262e0d00ec80758a552`, the merge of #263. The two have the same
`packages/shorebird_cli` tree (`e8cc324c`) and the same `bin/internal` tree (`7eab49a5`), read with `git rev-parse <rev>:<path>`
on both; they do not differ, so the pin is the CLI the resumed run ran. Previous pin's trees were `26b63664` and `06cce90c`.

## What was minted

The release `cell-a377ecb7` on `mml555/shorebird` (GitHub `createdAt` 2026-11-21T23:38:50Z, which is the time of the targeted commit `bbe90d39`; the tag was made 2026-11-22T03:37:50Z and the release published 2026-11-22T03:44:05Z, all UTC):

| Asset | Bytes | SHA-256 |
|---|---|---|
| `cell-a377ecb7....tar` (the 30 addressed members) | 750385664 | `e5b903e17add4e7a2d6893e0b3fcfb090087420225af807600ef27142322cef2` |
| `host-extras-a377ecb7....tar` (the same 26 host files as `54117a2f`'s, additive) | 848963584 | `6187a5b8a63854362e58f7473d3d48e6323fe669291eac53b0d33dd4b2644bf1` |
| `cell_manifest.v2` (the descriptor; also in-tree at `selfhost/engine/route_b/cell_manifests/a377ecb7....v2`) | 4141 | `a377ecb7ae1c26172d6e9d517c42321726eec427d0303027521fc789126167a9` |
| `LAYOUT.txt` | 5993 | `a68e79dc1c77ab8a495b421271d2664438789965e05ed1758143c17cd7fc72b2` |
| `CELL.txt`, `MANIFEST.sha256` | | |
| the full 100-file overlay, `.tar.part-aa` (1992294400 B) and `.part-ab` (1258656768 B), with `PARTS.sha256` and `files.sha256` | | joined: `acc47fdb1483b1935270e043683a023ecc13fb752271fd0baa193ec68fb6e0db` (not recomputed from the downloaded parts: it is the digest of the mint's 100-file tar, the first line of the original `MANIFEST.sha256` asset of this release, replaced in the repack on 2026-11-22; `publish_cell350.sh` checked that the sha256 of the rejoined parts equals it before upload) |

The cell was hydrated from the durable distribution on the Mac with `sd1_hydrate_cell.sh`: `CELL HYDRATED FROM THE DURABLE
DISTRIBUTION`, 30 of 30 members. The bootstrap closure row for the Dart SDK points at the parts (`...tar.part-*`).

## Gates

Run in `/srv/ci-cache/shorebird-engine/promo-a377ecb7` on ci-build. Run 1 started 2026-11-22T04:30Z (`chain.run1.log`); the resume
(`chain7.log`) started 04:55Z.

| # | Gate | Result | Evidence |
|---|---|---|---|
| 1 | candidate exists in the owned Flutter mirror | PASS: `52347b61` at `refs/heads/selfhost/3.50-cell-a377ecb7` | `chain.run1.log`, `guard_candidate.log` |
| 2 | exact `engine.version` | PASS: `a377ecb7ae1c26172d6e9d517c42321726eec427`, served `X-Overlay: hit` | same |
| 3 | SEALED + COLD bootstrap discovery | PASS: `BOOTSTRAP COMPLETED under seal after 0 additions` (run 1) | `bootstrap_discovery.log` |
| 4 | bootstrap manifest banked | PASS: 2 rows (`dart-sdk-linux-x64.zip` 227469081 B, sha `8f3d92e1...`; `engine_stamp.json` 246 B, sha `1624dcf8...`), proxy mapping `4382d059...` -> `371f7720` | `bootstrap_closure.tsv`, `proxy_mapping.tsv` |
| 5 | `bootstrap_closure_guard.sh` | PASS: `CLOSURE OK 52347b61 -> a377ecb7`, 1 artifact size + SHA-256 verified of the 2 banked rows (the first row, `dart-sdk-linux-x64.zip`, is not checked: see below), proxy mapping pinned | `guard_candidate.log` |
| 6 | fresh sealed cold bootstrap | PASS: arm BOOT1, exit 0; `Flutter 3.46.0-1.0.pre-2390`, Dart 3.14.0, `Shorebird Engine revision a377ecb7...`. Sealed mirror: 7 requests, 5 overlay hits, 0 `/gcs/`, 0 non-overlay 200s; the two 502s are both `GET /` (the harness's probe) | `arms/arm-BOOT1`, `boot1_access.txt`, `fresh_bootstrap_launch.log` |
| 7 | sealed release/patch artifact discovery | Run 1: FAIL, 3 checks (release and patch exit 70, arm 3 exit 64 without naming the chooser). Resume on `3001a355`: arms 1 and 2 exit 0, nothing refused by the seal and no import needed (no closure rows), the harness's verdict FAIL on one check, `arm 3 exited 0, expected 64` (the discovery control plane has one release, so the chooser is never reached; the designed outcome for this step, as in the `54117a2f` record). Resume: 36 requests, 35 overlay hits, 0 `/gcs/`, the one 502 is `GET /` | `release_patch_discovery.run1.log`, `release_patch_discovery.log`, `rp_access.txt` |
| 8 | fresh Linux release/patch smoke | Run 1: FAIL, arm A exit 1 (release and patch exit 70, see below). Resume: PASS, R12 arm A, fresh container, fresh cold mirror, exit 0, 05:06Z to 05:16Z: fixture 1.0.0+1; 39 requests, 37 overlay hits, 0 `/gcs/`, 0 non-overlay 200s (two 502s are the harness's `GET /`); arm 3 refused the chooser by name, exit 64 | `armA.run1.log`, `armA.log`, `armA_access.txt`, `arms/arm-A` |
| 8b | R12 arm B (`bin/armB_go.sh`) | PASS: fixture 1.0.1+1 on arm A's control plane (`releases_before.log` lists 0.8.1+1 and 1.0.0+1), fresh container, fresh cold mirror, exit 0, 05:28Z to 05:38Z: detector self-tests exit 64/64, release and patch published, `--json` patch 0 prompt hits, arm 3 refused the chooser by name (exit 64). 39 requests, 37 overlay hits, 0 `/gcs/`, 0 non-overlay 200s (two 502s are `GET /`) | `armB.log`, `armB_access.txt`, `arms/arm-B` |

(The counts above are the access logs' `handled request` lines, counted by status, `X-Overlay` header and `/gcs/` prefix.)

## Gates 4 and 5: 2 rows banked, 1 verified

Step 4 of `chain.sh` appends 2 ledger rows (`dart-sdk-linux-x64.zip`, `engine_stamp.json`) and 1 proxy-mapping row; its `grep: No such file or directory`
comes from the check `grep -q "^$A<TAB>" $LEDGER && die` running before the ledger file exists (the first append creates it), so it is harmless.
The guard (`bootstrap_closure_guard.sh`) printed "closure manifest rows for this engine: 1 ... (1 artifacts, size + sha256 verified)" against the 2 banked rows.
The same happened for `54117a2f` (its `chain.log:28` has the same `grep` error and its `guard_candidate.log` also reports 1 row against 2 banked), so this is the
chain's existing shape and not new in this cell. It is still a gap: the guard did not size and sha-check one of the two banked rows, and the gate's PASS does not say which.
Cause, read in `selfhost/ci/bootstrap_closure_guard.sh`: its loop reads the ledger with `tail -n +2 "$LEDGER"`, which skips the first line as a header, but the ledger
`chain.sh` writes has no header (`bootstrap_closure.tsv` here starts with the `dart-sdk-linux-x64.zip` row). So the guard never size- or sha-checks the first row, which is the
227 MB Dart SDK zip; only `engine_stamp.json` was verified. The banked row's sha256 is the one recorded in gate 4, and the bytes were served to the sealed cold bootstrap that passed
(step 6), but the guard's PASS does not prove that row. A real gap in the chain, present in `54117a2f`'s run too. #266 (`a8d036d0`) fixed it afterwards; this chain's run predates the fix, so gate 5 above stands as run (1 of 2 rows).

## How the run went

Run 1 (`chain.run1.log`, 04:30Z to `CHAIN_DONE` 04:51Z) passed steps 1 to 6 and failed at 7 and 8. The cause, read by the operator from the
build output (read by the operator at 2026-11-22T04:52Z from `/r12out/disc/ci_run_notty.log` inside run 1's discovery container `r12-discovery-rp`, since removed; the resume's discovery overwrote `/r12out/disc`; lines 39 to 43): the fixture `selfhost/fixtures/android_signing_app` used Gradle 9.1.0, and Flutter 3.50 refuses a project whose Gradle is below
9.3.1 (`Your project's Gradle version (9.1.0) is lower than Flutter's minimum supported version of 9.3.1`); the release exited 70. The text:

    * What went wrong:
    An exception occurred applying plugin request [id: 'dev.flutter.flutter-gradle-plugin']
    > Failed to apply plugin 'dev.flutter.flutter-gradle-plugin'.
       > Error: Your project's Gradle version (9.1.0) is lower than Flutter's minimum supported version of 9.3.1. Please upgrade your Gradle version.

The copied run-1 logs show only the exit 70; the full text was not preserved. Flutter 3.50 requires Android Gradle 9.3.1 or newer, AGP 9.1.1 or newer
and KGP 2.4.10 or newer (the 3.50 template uses Gradle 9.5.0, AGP 9.3.1, KGP 2.4.20). #263 bumped the fixture's
`gradle-wrapper.properties` and `settings.gradle.kts`.

A gap in the harness: step 7's own gate passed in run 1 even though the release had failed (the step printed its verdict and the
chain went on). The resume script (`chain7.sh`) added `grep -qE "arm 1 release FAILED|arm 2 FAILED"` after step 7 to catch it. Porting that check into
`selfhost/ci` is an open follow-up; it is not done here.

The resume (`chain7.log`, 04:55Z to 05:16Z) re-ran step 7 and arm A on `R12_REPO_SHA=3001a355`, with steps 3 to 6 standing from run 1 (steps 1 and 2 were re-run by the resume; the engine, the
selector and the cell did not change between the runs; the CLI change was the fixture bump). Arm B (`armB.log`, 05:28Z to `the arm B done marker` 05:38:10Z) ran after it.
`chain.run1.log`, `chain7.log`, `armA.run1.log`, `armA.log` and `armB.log` are copied from the workspace's `logs/` (`release_patch_discovery.run1.log` is its `rp.run1.log`);
the rest of this directory is the workspace's `evidence/` as it stood after arm B. The `SHOREBIRD_TOKEN` lines in the logs say `set (71 chars, not echoed)`;
no token, key or address of a person is in the copied files (searched for private-key headers, `password`, `secret`, `token`, `Authorization` and e-mail addresses).

## Device run

PASSED WITH LIMITS, run after this chain (2026-11-22, [`ios-cell-a377ecb7`](../../engine/route_b/evidence/ios-cell-a377ecb7/RESULT.md)): an iPhone 7 (iOS 15.8.8) run on 2026-11-22 through CLI `64a64473`: release `1.0.0+72` and 12 published patches each showed their values (combo, trio, h1, m1, m2, s1b, s1, i1, i2b, i2, e1b, p16), 9 patch attempts were refused before upload for the expected reasons, and three rollbacks fell back as expected (the last one ended on patch 11, e1b, which published and passed on the first try); no launch failed and no patch was refused by the device. Limits: the patches were unsigned, #254 (await on a `TickerFuture`) was not exercised, and it is one CLI, one device and one app version. No Android device applied a patch on this cell. The chain shows an Android release and patch built and published under seal, with the CLI arms passing; the harness itself frames that as "NOT self-certifying" (`armA.log:147-151`). Android device evidence is that of earlier cells.

## Not done

- The closure guard skipped the first ledger row (`tail -n +2`) although `chain.sh`'s ledger has no header, so the Dart SDK row was never verified (gates 4 and 5, here and in `54117a2f`'s run). Fixed by #266 (`a8d036d0`, "bootstrap_closure_guard checks every ledger row"). This chain ran before the fix, so its gate 5 still verified only 1 of the 2 banked rows, and a re-run of the guard on this ledger is not recorded here.
- The iPhone run (done: see Device run above).
- Port the post-step-7 failure check (`arm 1 release FAILED|arm 2 FAILED`) from the resume script into `selfhost/ci`.
- mml555/shorebird-flutter has no version tags after `3.46.0-0.3.pre` (`git ls-remote --tags https://github.com/mml555/shorebird-flutter.git 3.50.0` printed nothing on 2026-11-22), so the 3.50 selector reports Flutter `3.46.0-1.0.pre-2390` and pub evaluates `environment.flutter` constraints against 3.46. Upstream's `3.50.0` tag (`ab2912035e`) is an ancestor of `e737ede3`; pushing it (an owner step) makes the tree report `3.50.1-0.0.pre-252` (expected, not measured). The 3.47 stack had the same gap.
- shorebird-flutter's `selfhost-engine-mirror` action downloads a single `overlay-<engine>.tar`, but engine `e737ede3`'s overlay is released in parts. It affects
  shorebird-flutter commits whose `engine.version` is `e737ede3`. The fix is a push to shorebird-flutter and is pending.
- `a58774ab8a88` is not in `PolicyEpoch.b`'s `updaterRevisions` (`packages/code_push_server/lib/src/repository.dart`), so measurement mode does not count 3.50
  clients; adding it is the owner's call (`MEASUREMENT_MODE.md`), and this record does not change `repository.dart`.
- `vendor/updater` moved to `a58774ab` plus mirror#11 in #265 (landed with #264), and `tool/check_updater_pin.sh` now agrees.
- The analyzer's analysis version for this archive was not read out; the record names the archive and `route_b_analyze.aot` by digest.
- `verify_supported_state.sh` was run once against a hydrated overlay and a bootstrapped checkout at `64a64473`: SUPPORTED STATE VERIFIED, output in [`VERIFY_a377ecb7.txt`](VERIFY_a377ecb7.txt).
- `selfhost/ci/engine_updater_evidence_guard.sh` passes its vendor-side checks 1 to 3 against `a58774ab`. Check 3 now follows the `record_launch_failure` helper that upstream #455 split out of `report_launch_failure`; the behaviour is unchanged, and a copy with the `record_boot_failure_for_patch` call removed still fails it. Its engine-side checks 4 to 6 (DEPS pin, the wrong-release branch, the Shell constructor) have not been run for `a58774ab`: the only 3.50 tree on the Mac, `~/shorebird-engine/flutter-350`, holds `DEPS` but not the engine sources the guard reads, and nothing was built. The `a58774ab` launch and retention behaviour (#453, #454, #455) has not been re-read, beyond check 3 following #455's `record_launch_failure` split.
