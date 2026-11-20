# selfhost-v2.0.0

The annotated tag message and the GitHub release text for `selfhost-v2.0.0`.
Order matters, and it is the owner's to run after the release PR merges:

1. Push `code_push_server-v2.0.0` on the merge commit. It builds and publishes
   `:2.0.0` (both architectures), which both compose files pin. Wait for
   `release_code_push_server` to go green.
2. Then create `selfhost-v2.0.0` on the same commit, one step later (both tags
   on one commit at once race on `:source-<sha>`):

```sh
git tag -a selfhost-v2.0.0 -F selfhost/release_notes/selfhost-v2.0.0.md <merge sha>
```

The version is 2.0.0 because the server this checkout pins, `code_push_server`
2.0.0, needs operator attention on some existing deployments (see its
CHANGELOG: `PRODUCTION` values, `PUBLIC_BASE_URL`, the Caddyfile, `IDP_ISSUER`,
irreversible migrations). A `selfhost-v*` tag does not create `:2.0.0` or move
`:latest`; the workflow only gives it a traceability image tag
(`:selfhost-v2.0.0`) and `:source-<sha>`. It is the ref `bootstrap_selfhost.sh`
picks as the newest.

## Pins

```
server image        ghcr.io/mml555/code-push-server:2.0.0 (both compose files)
supported cell      54117a2fe0510a8cb070faf3f5191542179fb4ce  (30 members, macos-ios-android)
engine              d0714887dd95d2990e0185fe1893523f3d600cc5  (Dart b4671ab7)
cli_revision        37a0434bcf986bf2e36549591671f9fa181b5a52  (1.6.144+selfhost.1)
flutter_selector    f4024608592183cbfc27ff404e9fb23e84096f95
cell distribution   release cell-54117a2f, bundle sha256 178b90d2..., host extras 7b81ca82...
```

The bootstrap installs the CLI at `cli_revision` above. It is the same version
(1.6.144+selfhost.1) as the tree at this tag, but an earlier commit.

## Qualification: read this before pinning

- Android: proven on the Linux chain (R12 arms A and B on cell 54117a2f, with
  CLI `f66e3c21`), not on a device.
- iOS: the iPhone 7 run on this cell (2026-11-19) qualifies it, with the limits
  below. The release and all patches were built on CLI `f66e3c21`; every step
  passed or was refused as expected except e1b (an extension getter), whose
  patch the device refused (target missing, no crash, marked bad). #257 fixed
  it, and e1b alone was re-run on `cli_revision` (`37a0434b`) and passed. The
  other patches were not rebuilt on `37a0434b`. Details:
  `selfhost/engine/route_b/evidence/ios-cell-54117a2f/RESULT.md`.
- Limits:
  - Patches in the run were unsigned. This CLI still builds unsigned releases
    on a self-hosted server when no signing key is given; it does not yet
    refuse them. Pass a key (`--private-key-path`/`--public-key-path`) on
    every release and patch.
  - The cell's #254 fix (AnimationController) was not exercised on the device.
- The CLI revision was not itself run through the Linux chain; it differs from
  `f66e3c21` only in the iOS producer path (see
  `selfhost/engine/route_b/SUPPORTED_STATE.yaml`, `lineage.cli_revision`).

## Since selfhost-v1.2.1

- Server 2.0.0 (was 1.4.0): see `packages/code_push_server/CHANGELOG.md`,
  including the breaking configuration changes and the arm64 image.
- Cell 54117a2f (was 82fc78a8): v23 coverage analyzer, on engine d0714887.
  It supersedes a6a48cf6 (v21), which no `selfhost-v*` tag pinned.
- CLI revision 37a0434b (was 357bc24f); upstream 1.6.144 and its fork changes,
  including the Route B fixes #247, #248, #251 (a patch that changes a
  dependency is refused, not silently dropped), #252 and #257.

Start at `selfhost/GETTING_STARTED.md`:

```
TAG=selfhost-v2.0.0
curl -fsSL "https://raw.githubusercontent.com/mml555/shorebird/$TAG/selfhost/scripts/bootstrap_selfhost.sh" -o bootstrap_selfhost.sh
bash bootstrap_selfhost.sh --root ~/shorebird-selfhost --ref "$TAG" --start-mirror
```
