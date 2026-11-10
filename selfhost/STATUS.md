<!-- cspell:words dartdev sbrel -->
# Fork status

As of 2026-11-10. This is the starting point for picking the work back up: what state the
four repositories are in, what is proven, what is open, and what to do next. Update it
when an item here changes; history of how things got here lives in the PRs and in
[`STATE_OF_THE_SYSTEM.md`](STATE_OF_THE_SYSTEM.md).

## The four repositories

| Repository | Active branch | State |
|---|---|---|
| `mml555/shorebird` | `main` | Upstream v1.6.138 merged in (#79). CLI pins Flutter `5b180d22`. `experimental` and `selfhost/cli-backport-1.6.123` are ancestors of `main`: nothing on them is missing from it. |
| `mml555/shorebird-updater-mirror` | `route-b-ca91f4b3` (now the default) | Source port of the updater; vendored here under `vendor/updater/` (see its `VENDOR.md`). Old `route-b` is history only. |
| `mml555/shorebird-flutter` | `shorebird/dev` | PR #1 (the port onto Flutter 3.47.9 / Dart 3.13.7) merged 2026-11-09 as `bb7b68ab`. Its head `3a565f27` was built for android arm, arm64 and x64 plus the linux-x64 host toolchain, and published to the CDN mirror on ci-build (see below). PR #2 (merged 2026-11-09 as `c240f515`) pins `engine.version` to `3a565f27`. Its CI downloads the engine from the GitHub release `engine-3a565f27…` and serves it through `selfhost/cdn` on the runner ([`selfhost-engine-mirror`](https://github.com/mml555/shorebird-flutter/blob/shorebird/dev/.github/actions/selfhost-engine-mirror/action.yml)). Linux and Android jobs pass. Since 2026-11-10 the release also holds the macOS host side of `3a565f27` (built on the owner's Mac, [`selfhost/engine/macos/`](engine/macos/README.md)): darwin arm64 and x64 toolchains and Dart SDKs, the macOS framework, and `patch-darwin-*.zip`. PR #3 (merged 2026-11-10 as `eff7759c`) runs the mirror on macOS runners with `selfhost/cdn/run_native.sh`. PR #4 (merged 2026-11-10 as `206b4fd1`) adds the iOS engine and pins `engine.version` to `255fd850` (see [iOS on `255fd850`](#ios-on-255fd850)). PR #5 (`8b6a30d0`) skips the two jobs that need upstream's paid Namespace runners unless the repository opts in with `vars.NSCLOUD_RUNNERS`. PR #6 (`1ba9785e`) makes the runner-side mirror also install each release's `overlay-extra-<hash>.tar` when its `release_sums` line pins `SHA256SUMS.extra`. PR #7 is held for the next engine rebuild (see In flight). |
| `mml555/dart-sdk-shorebird-lineage` | `selfhost/3.13.7/route-b` | Pushed. The `maot/3.13.7/*` branches are the mutable-AOT research line and are not part of the shipped toolchain. |

## Housekeeping done on 2026-11-08

- Closed 28 superseded PRs on `mml555/shorebird` (the August Route B stacks, cw01-cw05,
  rb01-rb10 and the original feature PRs). Every file they touch is on `main` in a later
  form, except `ios_framework_patcher.dart` from cw05 (see open items).
- Deleted 44 merged or superseded branches. Each tip is kept as an `archive/<branch>` tag,
  so any of them can be restored with
  `git push <remote> archive/<b>:refs/heads/<b>`, where `<remote>` points at `mml555/shorebird`.
- Updater mirror: default branch switched to `route-b-ca91f4b3`, branch protection
  requires the `ci` and `required` checks, stale dependabot PRs against `route-b` closed.
- CI runs only on the home CI host (the GitHub Actions billing limit is reached). The
  host already runs ephemeral runners with an egress allowlist and a registration backoff;
  the scripts that set it up are in the repo since #85 (`selfhost/ci-host/`).
- Commit `a97f0130e` scrubbed infrastructure details from the tree; older history still
  holds them. They belong to a cloud build host the owner has since deleted (confirmed
  2026-11-08), and the TLS key in history was trusted only by that host, so none of it is
  live.

## In flight

As of 2026-11-10. #84 to #100, mirror #10 and shorebird-flutter #1 to #6 are merged. #93 makes `IDP_ISSUER` required in production when an IdP is configured: set it before the next server deploy.

| Item | What | Waiting on |
|---|---|---|
| iOS device run on `255fd850` | A release (1.0.0+1, bundle `dev.selfhost.sbrel`) is built with the fork CLI, published to a scratch code push server on ci-build (compose project `cps-ios`) and re-signed for devices with the team wildcard development profile. On the device: install it, check the screen and that the log says `This engine cannot run iOS patches, not starting the Shorebird updater.`, then `docker compose -p cps-ios down` on ci-build. | An iPhone attached to the Mac, unlocked, trusted, Developer Mode on. |
| shorebird-flutter PR #7 | Drops the stale dSYM entries from `compose.json` and the artifacts manifest, fixes the fetch order in `format.dart` and `git_repo_tools`, and marks the engine's "cannot run iOS patches" log text as read by the CLI (#99). | The next engine rebuild: it changes engine inputs, so it re-keys the engine. Rebuild the Apple shards by name then, so #97 clears their stale `FlutterEngine` stamps. |

## The CDN mirror on ci-build

Our engines (`3a565f27`, and `255fd850`, which shorebird-flutter now pins) are not on `download.shorebird.dev`. On the LAN they are served by the mirror, the
`selfhost/cdn` compose stack on ci-build (`shorebird-cdn-*` containers, restart
`unless-stopped`), on port 8085.

- **Plain HTTP.** Gradle refuses plain-HTTP Maven repositories, so an app's Android build
  needs `isAllowInsecureProtocol` until the HTTPS listener is on. That is
  `selfhost/cdn/tls/trust.sh`, which needs root on the host: the owner's to run.
- **Off-host copy.** The overlay bytes and the `3a565f27 -> 38855c84` map line are also
  on the GitHub release `engine-3a565f273d871d1ef004faf1a87bf45637df8ad0` in
  shorebird-flutter, with a `SHA256SUMS`. The repo's `experimental_hashes.map` still does
  not have that line; it gets it with the promotion.
- **`255fd850` is installed** in the ci-build mirror too (2026-11-10). The Caddyfile has
  `admin off`, so apply a config change with `docker restart shorebird-cdn-cdn-cache-1`.
- **Gaps closed by #100.** `sky_engine.zip`, `flutter_gpu.zip` and the arm64
  `maven-metadata.xml` are published and route-protected for `255fd850` and `3a565f27`,
  and so are the per-hash `linux-x64` and `darwin-x64` `font-subset.zip` (ours is built with
  the fork's `const_finder`, so the stock one breaks releases). The release tars
  hold them as `overlay-extra-<hash>.tar`, pinned by `SHA256SUMS.extra`. `3a565f27`'s sky
  and gpu were packaged from the `255fd850` tree; none of their 290 build inputs differ
  (recorded in its `PROVENANCE.txt`). `audit_overlay.sh` is clean for `255fd850` on all four
  cells, including the new `macos-x64`. For `3a565f27` it is clean except the iOS cells:
  it has no iOS engine.
- **Cold `/gcs/` fetches can hang.** A first fetch of a stock artifact through the mirror's
  `/gcs/` path stalled on 2026-11-10 (`darwin-arm64/font-subset.zip` for `38855c84`).
  Not yet diagnosed.

## iOS on `255fd850`

The iOS engine runs releases but takes no code patches (`shorebird_use_interpreter` is off).
What has been checked, 2026-11-10:

- **Simulator** (iPhone 17, iOS 27, debug, the only mode a simulator runs): host widget test,
  `flutter build ios --simulator --debug` and an integration test pass on Flutter
  `8b6a30d0` with artifacts from the mirror.
- **Release build** with the fork CLI and Flutter `8b6a30d0` needs:
  - `SHOREBIRD_ARTIFACT_ORIGIN=<mirror>`. With only `FLUTTER_STORAGE_BASE_URL` set, the
    patch tool and `aot-tools` still come from `storage.googleapis.com` and 404. Since #98
    the failure says so.
  - `SHOREBIRD_PUBLISHED_IOS_ENGINE_DIR` holding `{ios,ios-profile,ios-release}/artifacts.zip`,
    or the toolchain coherence check stops with `COHERENCE_UNDETERMINABLE`.
  - #99. Before it, the CLI took `255fd850` for a Route B engine (it contains vanilla Dart's
    `InterpretCall`), built with patchable call sites and refused its own release.
- **Engine stamp.** The framework `Info.plist` `FlutterEngine` key in this release reads
  `3a565f27`: `copy_info_plist.py` stamps `git rev-parse HEAD` and ninja does not rerun it.
  Nothing reads it, so it is a label only; #97 fixes it from the next Apple shard rebuild.

## Stable baseline

The project is at a stable point when every row is done.

| # | Condition | State |
|---|---|---|
| 1 | `main` CI green on the home runners | Done: the last push run on `main` passed on the home runners (2026-11-08) |
| 2 | No stale PRs or branches | Done, except the snapshot branches below |
| 3 | Server release matches what compose pins | #86 is merged, tag `code_push_server-v1.4.0` exists and `release_code_push_server` last passed on 2026-11-09. Owner to confirm the 1.4.0 image is the one compose pulls |
| 4 | Docs and manifests name the current revisions | No: `selfhost/compatibility.yaml` still declares CLI 1.6.115 and Flutter `a4a3c0d1`; bump it with the 3.47.9 promotion |
| 5 | Release and patch proven on the current engine | Partly: proven on `3a565f27`, not yet repeated on `255fd850`, which shorebird-flutter now pins (its iOS release is built; the device run waits on a phone). Done by hand, not in CI: on 2026-11-09 release 1.0.3+4 and patch 1 ran end to end on an x86_64 emulator with the CLI downloading engine `3a565f27` through the CDN mirror (no `--local-engine`), host tools included. Proof with screenshots: [shorebird-flutter#1](https://github.com/mml555/shorebird-flutter/pull/1#issuecomment-6735022921) |
| 6 | Publish durability shown (no vanished publishes) | Open, item 3 below |
| 7 | No unbounded growth on devices | Open, item 2 below |
| 8 | Device or emulator signal in CI | Open, item 5 below |
| 9 | `PATCH_SIGNING_KEY_SECRET` and `.env` backed up off the server | Owner to confirm. Losing the key means no device accepts new patches ([`backup_restore/SECRETS_BOUNDARY.md`](backup_restore/SECRETS_BOUNDARY.md)) |

## Open items, in the order to do them

Effort: S under a day, M a few days, L a week or more.

| # | Item | Effort | Notes |
|---|---|---|---|
| 1 | Promote the 3.47.9 engine | M-L | **Blockers fixed (merged):** the `_data` NoSuchMethodError hit every AOT program built with the fork's Dart 3.13.7, app code included. It came from a hash-accessor guard in `aot_call_specializer.cc`, and the dart2js and DDC platform builds rejected the new `external` members in `dart:_internal`. Both are fixed in [dart-sdk-shorebird-lineage#1](https://github.com/mml555/dart-sdk-shorebird-lineage/pull/1) and proven on ci-build. `build.sh --cell` now builds the host toolchain, including `linux-x64/artifacts.zip` with `impellerc`, and `overlay_publish.sh` publishes it. PR #1's conflicts are resolved and it is merged; the release + patch passed through the mirror; the engine is published there. Done since: the engine is on GitHub releases that CI downloads, and shorebird-flutter #2 and #4 pin it (now `255fd850`). Left: bump `bin/internal/flutter.version` and `compatibility.yaml`. Bumping `flutter.version` makes every fork CLI need the mirror, so do it with the promotion (sealed cold bootstrap closure, `bootstrap_closure_guard.sh`, sealed smoke), not before. Rules in [`TOOLCHAIN_PROMOTION.md`](TOOLCHAIN_PROMOTION.md). `eligibleUpdaterRevisions` is frozen by [`MEASUREMENT_MODE.md`](MEASUREMENT_MODE.md): changing it is the owner's call. |
| 1a | Alert when CI jobs sit queued | S | On 2026-11-08 every runner failed registration for about 5 hours (a firewall rule caught `gha-prep`; the fix is live on the host and in #85) and jobs only showed as pending. Add a timer on the CI host that warns when a runner unit has failed registration several times in a row or a job has been queued over 20 minutes. |
| 2 | Bound the updater's diag logs | S | `state_diag.log` and `success_diag.log` are appended on every launch and never cleaned (`vendor/updater/SELFHOST_PORT_ca91f4b3.md`). Rotate or cap in the mirror, then re-vendor. **In review:** [mirror#11](https://github.com/mml555/shorebird-updater-mirror/pull/11) caps each at 64 KiB plus one rotation; the engine gets it when `updater_rev` moves (the owner's call); a device's existing oversized log is deleted at its first append. |
| 3 | Re-test vanished publishes | M | [`PARITY.md`](PARITY.md) still lists accepted-but-missing releases with no root cause. Repro on server 1.4.0 and the current CLI, reading every publish back from the database. |
| 4 | Updater: map the HTTP client's `ConnectProxyFailed` to a transport error | S | Today a proxy refusal surfaces differently from a direct network failure; #84 works around it in CI only. **In review:** [mirror#11](https://github.com/mml555/shorebird-updater-mirror/pull/11) maps it to `NetworkError::Transport` in the ureq builds only (Linux, Windows). Android, iOS and macOS use the engine client, which already reports `HttpError::Transport`; they are unaffected. Moving `updater_rev` is the owner's call. |
| 5 | E2E on the emulator pool | M | All e2e legs need `HOSTED_RUNNERS`. The home emulator pool can serve them; the `3a565f27` engine now includes android-x64, which the pool's x86_64 images run (proven 2026-11-09 by hand). |
| 6 | S3 client retries | S-M | `packages/code_push_server/lib/src/s3_client.dart` has none; a transient S3 error fails the upload. |
| 7 | Document that a proxy must pass `/api/v1/patches/events` | S | Unauthenticated POST; a proxy that blocks it drops install events silently. Belongs in `packages/code_push_server/PRODUCTION.md`. |
| 8 | Make `dart test --concurrency` a workflow input | S | Hard-coded to 4 in `.github/workflows/_shorebird_ci_dart.yaml`. |
| 9 | pub.dev publish via OIDC | S | Wired in `publish_dart_package.yaml`, never exercised. One dry run. |
| 10 | arm64 server image | M | Releases are amd64 only without hosted runners (buildx + QEMU or an arm64 runner). |
| 11 | iOS code push and `aot-tools.dill` | L | The iOS engine is built, published and pinned as `255fd850` (shorebird-flutter PR #4), without code patches: the iOS patch path needs `Shorebird_ReadLinkHeader` and the five-argument `Dart_LoadELF` from Shorebird's private Dart fork, so `shorebird_use_interpreter` is off and iOS apps do not start the updater. Patches on iOS need those in the public Dart fork. A release is built and signed; the device run waits on a phone (In flight). `aot-tools.dill` does not build yet. |
| 11a | Diagnose the mirror's cold `/gcs/` fetch hang | S | See the CDN section. |
| 12 | Apple and desktop paths in CI | L | iOS code push was proven on the owner's devices with earlier Route B engines, not `255fd850`; macOS, Windows and Linux code push are untested ([`DESKTOP_PLATFORMS.md`](DESKTOP_PLATFORMS.md)). Needs a Mac runner. |

Owner decisions, no code needed:

- `ios_framework_patcher.dart` from the closed cw05 PR is the one file never on `main`.
  Glance at `archive/cw05-other-platforms` and keep or drop it.
- Snapshot branches `preserve/*` (three) and `worktree-wf_88d81758-e2a-1`, `-4` hold a few
  files not on `main`, most likely replaced by later rewrites. Archive or delete.
- `stable` is an old ancestor of `main`; keep only if something pins it.
- The `selfhost/` folder has 44 top-level docs, several of them dated handoffs.
  Archiving the `HANDOFF-*` files would make the index easier to use.

Longer research lines, not blocking: foldable-constant patches that attach but do nothing
([`STATE_OF_THE_SYSTEM.md`](STATE_OF_THE_SYSTEM.md)), progressive rollout with no client
surface ([`WORKFLOW_CERTIFICATION.md`](WORKFLOW_CERTIFICATION.md)), Route B `super.foo()`
on device ([`ROUTE_B.md`](ROUTE_B.md)), and the mutable-AOT line
([`engine/mutable_aot/`](engine/mutable_aot)).
