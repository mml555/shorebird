# Cell 5f6efd98 over engine d0714887: the frozen chain, run on ci-build

Date 2026-11-16. Chain: `selfhost/TOOLCHAIN_PROMOTION.md`, run as `PROMOTION_82fc78a8.md` was. This mints a
cell address for engine `d0714887` (the merge of shorebird-flutter #13: Dart `b4671ab7`, which lets Route B
patches make direct `super` calls and call SDK methods by name), so a clean install finds that engine through
`cell-manifests/<address>.v2`. CLI commit under test: `d227ec0027935d0d7348623143361998c86fc2c5` (PR #185's
head; its merge `22f14441` has the same `packages/shorebird_cli` and `bin/internal` trees).

    cell address       5f6efd9826ae8fadc6ff66150cbcac8c7201140f   macos-ios-android, 30 members
    flutter_revision   ef0eec1b3868b4d42f9429328554361ad415dbb6   shorebird-flutter: 0987ce0a + engine.version = 5f6efd98 (one line)
    engine bytes       d0714887dd95d2990e0185fe1893523f3d600cc5   published members, byte for byte, except the compiler archive
    fallback           38855c84ca367c58165b8e3844dd7d6a99dec844   as d0714887's own experimental_hashes.map entry
    updater_revision   87c198d30f875a3da317d70935e1025dc13064dd   unchanged

Run in `/srv/ci-cache/shorebird-engine/promo-5f6e` on ci-build, set up from the `82fc78a8` run's workspace:
the same scripts retargeted to this cell, `selfhost/ci` from main `9e48dc66` (PR #183, which recreates a
reused discovery container whose environment no longer matches), and the ledgers taken fresh from main.

## The first cell over d0714887, fb12c60a, and why it was replaced

`fb12c60a9547f2413d8190437781fa81a1a6e935` was minted the same way and installed on ci-build, and was never
recorded here (PR #176, closed). On the iPhone run, `shorebird release ios` printed `Could not check the two
release kernels against each other (The Route B coverage analyzer failed (exit 255): Unhandled exception:
Reference to dart:core::Object is not bound to an AST node)`. The release then uploaded no kernel, and
`shorebird patch ios` refused the patch. The v14 analyzer resolved a supertype through a reference that is
only bound when the platform is linked in, and the release dill is built with `--no-link-platform`. Its own
parity corpus never built a dill that way, so it passed there.

PR #184 fixed the analyzer (each supertype is compared by its reference, with a canonical-name fallback for class identity)
and added that release-shaped dill to the parity corpus: the old analyzer passes 4 of its 19 cases, the new
one all 19. The compiler archive was rebuilt with only the analyzer changed (`3adce5e4...`, 19789182 B;
`route_b_analyze.aot` `0ad7cd52...`), and the cell re-minted.

`fb12c60a`'s files stay in ci-build's overlay and its CDN entries stay, so nothing that fetched it breaks.
Nothing selects it.

## What was minted

Members come from the published `d0714887` overlay. Against `d0714887`'s files, 49 are byte-identical, 7 are
rendered to the new address (`engine_stamp.json` with `git_revision` `%H`, four POMs, `artifacts_manifest.yaml`
regenerated against the 38855c84 base, and the descriptor), and 1 differs: the compiler archive, which
carries PR #184's analyzer. The product's own `v2_transaction` staged, addressed, rendered, verified and
published it; the address qualified (`QUALIFIED`). The same 26 unaddressed host files as `82fc78a8` ship as
`host-extras-<address>.tar` (see `PROMOTION_82fc78a8.md`, "What gates 3-6 prove", which applies unchanged).

Installed on ci-build by `install5f6e.sh` (the owner ran it): 57 files installed without overwriting, the
CDN protection lists extended (MATCHER COVERAGE OK), 57 of 57 served from the overlay and identical, and
`audit` CLEAN for the cell (macos-ios, macos-ios-android) and for d0714887 (all three).

## Gates

| # | Gate | Result | Evidence |
|---|---|---|---|
| 1 | candidate exists in the owned Flutter mirror | PASS: `ef0eec1b` at `refs/heads/selfhost/3.47-cell-5f6efd98` | `promotion-5f6efd98/guard_candidate.log` |
| 2 | exact `engine.version` | PASS: `5f6efd9826ae8fadc6ff66150cbcac8c7201140f` | same |
| 3 | SEALED + COLD bootstrap discovery | PASS, 0 additions | `promotion-5f6efd98/bootstrap_discovery.log` |
| 4 | bootstrap manifest banked | PASS: 2 rows (dart-sdk 214945654 B, sha `91dfc837...`; engine_stamp 239 B, sha `06677562...`), manifest digest `c02ff734...` | `bootstrap_closure.tsv`, `proxy_mapping.tsv` |
| 5 | `bootstrap_closure_guard.sh` | PASS: `CLOSURE OK`, 2 artifacts size + SHA-256 verified, proxy mapping pinned (`c02ff734...` -> `89c39edf`) | `promotion-5f6efd98/guard_candidate.log` |
| 6 | fresh sealed cold bootstrap | PASS: bootstrap-only, fresh container, exit 0; `Flutter 3.46.0-1.0.pre-866`, `Shorebird Engine • revision 5f6efd98...`. Sealed mirror: 5 overlay hits, 0 `/gcs/`, 0 non-overlay 200s; two 502s, both `GET /` (the harness's CA probe) | `promotion-5f6efd98/fresh_bootstrap_launch.log`, `boot1_access.txt`, `arms/arm-BOOT1` |
| 7 | sealed release/patch artifact discovery | PASS for the closure: 10 imports in 11 iterations, the last refused nothing. The discovery harness's own verdict was FAIL, not applicable, as in `PROMOTION_82fc78a8.md` (one release in its control plane, so arm 3's chooser uses it). Arm 3 is decided by arm A | `release_patch_closure.tsv` (10 rows under `5f6efd98`), `promotion-5f6efd98/release_patch_discovery.log`, `rp_access.txt` |
| 8 | fresh Linux release/patch smoke | PASS: R12 arm A on gate 7's control plane, fresh container, fresh cold mirror: 38 overlay hits, 0 `/gcs/`, 0 refused (the two 502s are the harness's `GET /`); arm 3 refused the chooser by name, exit 64 | `promotion-5f6efd98/armA.log`, `armA_access.txt`, `arms/arm-A` |

The ten imports are the same ten stock files as in the `82fc78a8` and `d12e29ec` runs (seven
`android-*/artifacts.zip` and three `android-*-profile/linux-x64.zip`), now under the `5f6efd98` client
path. They are stock engine bytes from the fallback `38855c84`, not built from d0714887: the known gap
stated in `compatibility.yaml` is unchanged.

The first attempt at this chain stopped after gate 7, because its wrapper treated the harness verdict as
the gate. Gate 8 was then run on its own, on the same control plane (no restart between 7 and 8), which is
what arm 3 needs to see two releases.

## Device run

Through the cell address on a physical iPhone 7 (iOS 15.8), 2026-11-16: release, Route B patch applied on
two launches, rollback back to the release. PASS. `selfhost/engine/route_b/evidence/ios-cell-5f6efd98/RESULT.md`.

## Published

The owner created both on 2026-11-16. The tag `selfhost-flutter-cell-5f6efd98` on shorebird-flutter
points at `ef0eec1b`. The release `cell-5f6efd98` on mml555/shorebird targets `22f14441`, and GitHub's
digest of each of its six files matches this record: the bundle `ef568465...`, the host extras
`92478549...`, the layout `37ce7822...` and the descriptor `5f6efd98...`. Both bootstrap ledger URLs
resolve (200), and the members they name hash to the rows' SHA-256 and sizes: `dart-sdk-linux-x64.zip`
`91dfc837...` (214945654 B) and `engine_stamp.json` `06677562...` (239 B). The engine release
`engine-d0714887...` on shorebird-flutter is now marked latest.

## Verification of the record

`verify_supported_state.sh` on the arm64 Mac, against this branch's record with the minted cell's overlay
and the CLI checkout at `22f14441`: SUPPORTED STATE VERIFIED, every check ok (including all addressed cell
members against the bytes served and `audit_route_b_compiler: AUDIT CLEAN`).

## Not done

- R12 arm B was not re-run. No non-interactive semantics changed since the `82fc78a8` record's CLI
  (`357bc24f`): the 11 `packages/shorebird_cli` commits since are all Route B (iOS patch coverage, receiver
  typing, untabled methods), and none of their `lib/` diff touches prompts, `canAcceptUserInput`, the release
  chooser or `--release-version`. `selfhost/ci/r12` changed in PR #177 (mirror startup retries; scripts reach
  their own error instead of exiting silently) and PR #183 (discovery container reuse), neither of which
  changes what the arms run.
