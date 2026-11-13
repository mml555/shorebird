# Cell 82fc78a8 over engine 2c4b0718: the frozen chain, run on ci-build

Date 2026-11-12/13. Chain: `selfhost/TOOLCHAIN_PROMOTION.md`. This minted a cell address for the engine
that `PROMOTION_d12e29ec.md` promoted, so a clean install finds that engine through
`cell-manifests/<address>.v2` (the address is `sha256(manifest)[:40]`; the raw engine revision cannot be
pinned directly). CLI commit under test: `12f2b3d46ea9df3dc3a4b23f6301036c8e0e6492`.

    cell address       82fc78a817ce8290b108cea4dec1ee58317e9a9c   macos-ios-android, 30 members
    flutter_revision   f6bbc8a0b4e4d12f824edea754d05f86047d6c8f   shorebird-flutter: d12e29ec + engine.version = 82fc78a8 (one line)
    engine bytes       2c4b071817c52c27142b35ff789749951e5b4d22   published members, byte for byte
    fallback           38855c84ca367c58165b8e3844dd7d6a99dec844   as 2c4b0718's own experimental_hashes.map entry
    updater_revision   87c198d30f875a3da317d70935e1025dc13064dd   unchanged from d12e29ec's DEPS

Run in `/srv/ci-cache/shorebird-engine/promo-82fc` on ci-build. The setup is the one in
`PROMOTION_d12e29ec.md` (sealed cold mirror `r12cold`, owned Flutter git mirror, throwaway control plane,
`r12-builder:substrate`).

## What was minted

Members come from the published `2c4b0718` overlay (tar sha256 `8a195890...`). Five are rendered to the
new address: `engine_stamp.json` (re-derived, `git_revision` `%H`), four POMs (canonical `%H`), and
`artifacts_manifest.yaml` (regenerated against the 38855c84 base so `flutter_engine_revision` stays
upstream's `89c39edf`; the published 2c4b manifest names itself and the canonicalizer refuses it). The
product's own `v2_transaction` staged, addressed, rendered, verified and published it; re-staging gives the
same address. `audit_route_b_compiler.sh --hash 82fc78a8...` returned AUDIT CLEAN.

26 more host files are served under the same path but are not addressed (dart-sdk-linux-x64,
linux-x64/*, darwin-x64/*, android-*-release/linux-x64, analyze-snapshot and similar), because
`@must_be_local` answers 404 for them when a mapped hash has no overlay file. They are 2c4b0718's bytes
cloned under the new path and ship as the additive release asset `host-extras-<address>.tar`.

## Gates

| # | Gate | Result | Evidence |
|---|---|---|---|
| 1 | candidate exists in the owned Flutter mirror | PASS: `f6bbc8a0` at `refs/heads/selfhost/3.47-cell-82fc78a8` (tag `selfhost-flutter-cell-82fc78a8`) | `promotion-82fc78a8/guard_candidate.log` |
| 2 | exact `engine.version` | PASS: `82fc78a817ce8290b108cea4dec1ee58317e9a9c` | same |
| 3 | SEALED + COLD bootstrap discovery | PASS, 0 additions: `dart-sdk-linux-x64.zip` and `engine_stamp.json` | `promotion-82fc78a8/bootstrap_discovery.log` |
| 4 | bootstrap manifest banked | PASS: 2 rows (dart-sdk 214926677 B, sha `0bfaf194...`; engine_stamp 239 B, sha `45bae610...`), manifest digest `f28c3c8a...` | `bootstrap_closure.tsv`, `proxy_mapping.tsv` |
| 5 | `bootstrap_closure_guard.sh` | PASS: `CLOSURE OK`, 2 artifacts size + SHA-256 verified, proxy mapping pinned (`f28c3c8a...` -> `89c39edf`) | `promotion-82fc78a8/guard_candidate.log` |
| 6 | fresh sealed cold bootstrap | PASS: `launch.sh` bootstrap-only, fresh container, exit 0; 2 overlay hits, 0 `/gcs/`, 0 non-overlay 200s; one 502 for `GET /` (the harness's CA probe) | `promotion-82fc78a8/fresh_bootstrap_launch.log`, `boot1_access.txt`, `arms/arm-BOOT1` |
| 7 | sealed release/patch artifact discovery | PASS for the closure: 10 imports in 11 iterations, the last refused nothing. The discovery harness's own verdict was FAIL, not applicable, for the reason given in `PROMOTION_d12e29ec.md` (one release in its control plane, so arm 3's chooser uses it) | `release_patch_closure.tsv` (10 rows under `82fc78a8`), `promotion-82fc78a8/release_patch_discovery.log`, `rp_access.txt` |
| 8 | fresh Linux release/patch smoke | PASS: R12 arm A, fresh container, fresh cold mirror: 36 overlay hits, 0 `/gcs/`, 0 refused (the one 502 is the harness's `GET /`); arm 3 refused the chooser by name, exit 64 | `promotion-82fc78a8/armA.log`, `armA_access.txt`, `arms/arm-A` |

The ten imports are the same ten stock files as in the d12e29ec run (seven `android-*/artifacts.zip` and
three `android-*-profile/linux-x64.zip`), now under the `82fc78a8` client path. They are stock engine
bytes, not built from 2c4b0718: the known gap stated in `compatibility.yaml` is unchanged.

## Not done

- R12 arm B was not re-run. No non-interactive semantics changed between d12e29ec and this cell (against the 5b555d66 CLI
  of that run, `packages/shorebird_cli`, `bin/internal` apart from `flutter.version`, and `selfhost/ci/r12` are unchanged), which `TOOLCHAIN_PROMOTION.md` says does not require it.
- No device run through the cell address. The 2026-11-11 iPhone 7 run used the engine directly; the cell's
  members are those bytes.
- The checked-in CDN configuration and map do not carry the `255fd`, `7806e` or `2c4b` entries; they exist
  only in ci-build's local copy. This change adds the `82fc78a8` entry to the repo copy and to ci-build's.
  The production `cdn-cache` container on ci-build was not restarted.
