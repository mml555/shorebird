# selfhost-v2.0.0

The annotated tag message and the GitHub release text for `selfhost-v2.0.0`.
Cut it from the merge commit of the release PR:

```sh
git tag -a selfhost-v2.0.0 -F selfhost/release_notes/selfhost-v2.0.0.md <merge sha>
```

The version is 2.0.0 because the server this checkout pins, `code_push_server`
2.0.0, needs `.env` changes on some existing deployments (see its CHANGELOG:
`PRODUCTION` values, `PUBLIC_BASE_URL`, the Caddyfile, `IDP_ISSUER`). The tag is
a distribution tag: it publishes no image (the `code_push_server-v2.0.0` tag
does) and it is the ref `bootstrap_selfhost.sh` picks as the newest.

## Pins

```
server image        ghcr.io/mml555/code-push-server:2.0.0 (both compose files)
supported cell      a6a48cf673a291f607323e89b41839c4b8b74e5d  (30 members, macos-ios-android)
engine              d0714887dd95d2990e0185fe1893523f3d600cc5  (Dart b4671ab7)
cli_revision        e7384444fad53cdd35317fe3dc0abc4d3c7b1c36  (1.6.140+selfhost.1)
flutter_selector    cc4fc222c210836f89bde6e91f7580e8241432da
cell distribution   release cell-a6a48cf6, bundle sha256 cdeb3922..., host extras fb9f6fc5...
```

The tree at this tag is the CLI 1.6.144+selfhost.1 and the server serves it,
but the bootstrap installs the CLI at `cli_revision` above (1.6.140+selfhost.1):
the pair is only re-qualified by the promotion chain.

## Qualification: read this before pinning

- Android: proven on the Linux chain (R12 arms A and B on cell a6a48cf6), not on
  a device.
- iOS: the iPhone 7 run on this cell (2026-11-19) was PARTIAL. This cell is NOT
  device-qualified. The last device-qualified cell is 2fc41d3f. Details:
  `selfhost/engine/route_b/evidence/ios-cell-a6a48cf6/RESULT.md`.
- The CLI revision was not itself qualified on this cell (see
  `selfhost/engine/route_b/SUPPORTED_STATE.yaml`, `lineage.cli_revision`).

## Since selfhost-v1.2.1

- Server 2.0.0 (was 1.4.0): see `packages/code_push_server/CHANGELOG.md`,
  including the breaking configuration changes and the arm64 image.
- Cell a6a48cf6 (was 82fc78a8): v21 coverage analyzer, on engine d0714887.
- CLI revision e7384444 (was 357bc24f); upstream 1.6.140 and its fork changes.

Start at `selfhost/GETTING_STARTED.md`:

```
TAG=selfhost-v2.0.0
curl -fsSL "https://raw.githubusercontent.com/mml555/shorebird/$TAG/selfhost/scripts/bootstrap_selfhost.sh" -o bootstrap_selfhost.sh
bash bootstrap_selfhost.sh --root ~/shorebird-selfhost --ref "$TAG" --start-mirror
```
