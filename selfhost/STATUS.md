<!-- cspell:words dartdev -->
# Fork status

As of 2026-11-08. This is the starting point for picking the work back up: what state the
four repositories are in, what is proven, what is open, and what to do next. Update it
when an item here changes; history of how things got here lives in the PRs and in
[`STATE_OF_THE_SYSTEM.md`](STATE_OF_THE_SYSTEM.md).

## The four repositories

| Repository | Active branch | State |
|---|---|---|
| `mml555/shorebird` | `main` | Upstream v1.6.138 merged in (#79). CLI pins Flutter `5b180d22`. `experimental` and `selfhost/cli-backport-1.6.123` are ancestors of `main`: nothing on them is missing from it. |
| `mml555/shorebird-updater-mirror` | `route-b-ca91f4b3` (now the default) | Source port of the updater; vendored here under `vendor/updater/` (see its `VENDOR.md`). Old `route-b` is history only. |
| `mml555/shorebird-flutter` | `shorebird/dev`; draft PR #1 ports onto Flutter 3.47.9 / Dart 3.13.7 | PR #1 has merge conflicts. An android-arm64 engine was built from it (`selfhost/engine/README.md`). |
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
  the scripts that set it up are added to the repo by #85 (`selfhost/ci-host/`), not yet
  merged.
- Commit `a97f0130e` scrubbed infrastructure details from the tree; older history still
  holds them. They belong to a cloud build host the owner has since deleted (confirmed
  2026-11-08), and the TLS key in history was trusted only by that host, so none of it is
  live.

## In flight

As of 2026-11-08.

| PR | What | Waiting on |
|---|---|---|
| #84 + mirror #10 | Run the updater's cargo tests without the runner proxy | CI, then owner LGTM |
| #85 | CI host: ephemeral runners, egress allowlist, registration backoff (already running on the host) | Owner LGTM |
| #86 | Release `code_push_server` 1.4.0 (amd64 only) and pin compose to it | Owner LGTM; then tag `code_push_server-v1.4.0` and run `release_code_push_server` (steps in the PR body) |
| #87 | This page | Owner LGTM |

## Stable baseline

The project is at a stable point when every row is done.

| # | Condition | State |
|---|---|---|
| 1 | `main` CI green on the home runners | Done: the last push run on `main` passed on the home runners (2026-11-08) |
| 2 | No stale PRs or branches | Done, except the snapshot branches below |
| 3 | Server release matches what compose pins | After #86 and its release run |
| 4 | Docs and manifests name the current revisions | No: `selfhost/compatibility.yaml` still declares CLI 1.6.115 and Flutter `a4a3c0d1`; bump it with the 3.47.9 promotion |
| 5 | Release and patch proven on the current engine | Partly: release, patch download and patched boot passed on an emulator with the 3.47.9 android-arm64 engine (2026-11-08), but only with the official Dart host tools standing in for the fork's (item 1). Run by hand on the CI host against a local 1.4.0 server; screenshots and logs are not checked in |
| 6 | Publish durability shown (no vanished publishes) | Open, item 3 below |
| 7 | No unbounded growth on devices | Open, item 2 below |
| 8 | Device or emulator signal in CI | Open, item 5 below |
| 9 | `PATCH_SIGNING_KEY_SECRET` and `.env` backed up off the server | Owner to confirm. Losing the key means no device accepts new patches ([`backup_restore/SECRETS_BOUNDARY.md`](backup_restore/SECRETS_BOUNDARY.md)) |

## Open items, in the order to do them

Effort: S under a day, M a few days, L a week or more.

| # | Item | Effort | Notes |
|---|---|---|---|
| 1 | Promote the 3.47.9 engine | M-L | **Blocker first:** host AOT snapshots built with the fork's Dart 3.13.7 tools (`dartdev`, `frontend_server`, `const_finder`) fail at run time with `NoSuchMethodError: Class '_Map<…>' has no instance getter '_data'`, most likely a bug in the 3.13.7 port's precompiler. Not yet checked whether app code from the fork's `gen_snapshot` is affected (the test app ran). Also: the web platform builds (`dart2js`, `ddc`) reject the new `external` members in `dart:_internal`, and `build.sh` leaves out `impellerc`. Then: resolve shorebird-flutter PR #1 conflicts, finish the emulator release + patch, publish, bump `bin/internal/flutter.version` and `compatibility.yaml`. Rules in [`TOOLCHAIN_PROMOTION.md`](TOOLCHAIN_PROMOTION.md). `eligibleUpdaterRevisions` is frozen by [`MEASUREMENT_MODE.md`](MEASUREMENT_MODE.md): changing it is the owner's call. |
| 1a | Alert when CI jobs sit queued | S | On 2026-11-08 every runner failed registration for about 5 hours (a firewall rule caught `gha-prep`; the fix is live on the host and in #85) and jobs only showed as pending. Add a timer on the CI host that warns when a runner unit has failed registration several times in a row or a job has been queued over 20 minutes. |
| 2 | Bound the updater's diag logs | S | `state_diag.log` and `success_diag.log` are appended on every launch and never cleaned (`vendor/updater/SELFHOST_PORT_ca91f4b3.md`). Rotate or cap in the mirror, then re-vendor. |
| 3 | Re-test vanished publishes | M | [`PARITY.md`](PARITY.md) still lists accepted-but-missing releases with no root cause. Repro on server 1.4.0 and the current CLI, reading every publish back from the database. |
| 4 | Updater: map the HTTP client's `ConnectProxyFailed` to a transport error | S | Today a proxy refusal surfaces differently from a direct network failure; #84 works around it in CI only. Needs a new updater revision. |
| 5 | E2E on the emulator pool | M | All e2e legs need `HOSTED_RUNNERS`. The home emulator pool can serve them; the engine is arm64 and the pool images are x86_64, so either add an x86_64 engine build or arm64 images. |
| 6 | S3 client retries | S-M | `packages/code_push_server/lib/src/s3_client.dart` has none; a transient S3 error fails the upload. |
| 7 | Document that a proxy must pass `/api/v1/patches/events` | S | Unauthenticated POST; a proxy that blocks it drops install events silently. Belongs in `packages/code_push_server/PRODUCTION.md`. |
| 8 | Make `dart test --concurrency` a workflow input | S | Hard-coded to 4 in `.github/workflows/_shorebird_ci_dart.yaml`. |
| 9 | pub.dev publish via OIDC | S | Wired in `publish_dart_package.yaml`, never exercised. One dry run. |
| 10 | arm64 server image | M | Releases are amd64 only without hosted runners (buildx + QEMU or an arm64 runner). |
| 11 | linux-x64 engine | L | Only android-arm64 has been built; Linux hosts cannot release from the fork's engine. |
| 12 | Apple and desktop paths in CI | L | iOS was proven on the owner's devices; macOS, Windows and Linux code push are untested ([`DESKTOP_PLATFORMS.md`](DESKTOP_PLATFORMS.md)). Needs a Mac runner. |

Owner decisions, no code needed:

- `ios_framework_patcher.dart` from the closed cw05 PR is the one file never on `main`.
  Glance at `archive/cw05-other-platforms` and keep or drop it.
- Snapshot branches `preserve/*` (three) and `worktree-wf_88d81758-e2a-1`, `-4` hold a few
  files not on `main`, most likely replaced by later rewrites. Archive or delete.
- `stable` is an old ancestor of `main`; keep only if something pins it.
- The `selfhost/` folder has 46 top-level docs, several of them dated handoffs.
  Archiving the `HANDOFF-*` files would make the index easier to use.

Longer research lines, not blocking: foldable-constant patches that attach but do nothing
([`STATE_OF_THE_SYSTEM.md`](STATE_OF_THE_SYSTEM.md)), progressive rollout with no client
surface ([`WORKFLOW_CERTIFICATION.md`](WORKFLOW_CERTIFICATION.md)), Route B `super.foo()`
on device ([`ROUTE_B.md`](ROUTE_B.md)), and the mutable-AOT line
([`engine/mutable_aot/`](engine/mutable_aot)).
