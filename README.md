## Shorebird — self-hosted fork 🐦

> **This is a self-hosted fork of [Shorebird](https://github.com/shorebirdtech/shorebird).**
> It adds a **self-hosted code-push control plane** so you can run Flutter
> over-the-air updates entirely on your own infrastructure. The unmodified,
> version-pinned Shorebird CLI and on-device updater talk to **your** server, so
> no runtime request depends on `api.shorebird.dev` — and there's no
> per-app/per-user pricing.
>
> **Start here → [`packages/code_push_server/README.md`](packages/code_push_server/README.md)**
> · self-host docs: [`selfhost/README.md`](selfhost/README.md)

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE-MIT)
[![License: Apache](https://img.shields.io/badge/license-Apache-orange.svg)](./LICENSE-APACHE)

## What this fork adds

Upstream Shorebird's CLI and updater point at Shorebird's hosted service
(`api.shorebird.dev`). This fork keeps the CLI and updater **unmodified and
version-pinned**, and adds a drop-in server they talk to instead:

- **[`packages/code_push_server`](packages/code_push_server/README.md)** — the
  self-hosted control plane. One command (`./setup.sh`) brings up releases,
  patches, channels, partial rollouts, multi-tenancy, IdP login, analytics, and
  ops on your own infra. Runs single-container (SQLite + local disk) by default,
  or Postgres + S3/MinIO for scale.
- **[`selfhost/`](selfhost/README.md)** — the self-host documentation set:
  architecture, API reference, integration guide, iOS code signing, and the
  go-live runbook.

## Getting Started

Pin a release rather than tracking `main` — the latest baseline is
[`selfhost-v1.0.0`](https://github.com/mml555/shorebird/releases/tag/selfhost-v1.0.0):

```bash
git clone --branch selfhost-v1.0.0 https://github.com/mml555/shorebird.git
cd shorebird/packages/code_push_server
./setup.sh
```

`setup.sh` generates secrets, pulls the prebuilt image
(`ghcr.io/mml555/code-push-server:1.1.0`, amd64 + arm64), starts the stack, and
prints the next steps. Full walkthrough in
[`packages/code_push_server/README.md`](packages/code_push_server/README.md).

For the Shorebird CLI and general code-push concepts, upstream's docs at
https://docs.shorebird.dev still apply — this fork does not change the CLI's
wire contract.

## Packages

This repository is a monorepo. The package added by this fork is listed first,
then the one it modifies; the rest are inherited unchanged from upstream
Shorebird:

| Package                                                                         | Description                                                                             |
| ------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| [code_push_server](packages/code_push_server/README.md)                         | **This fork:** self-hosted Shorebird control plane (server)                             |
| [shorebird_cli](packages/shorebird_cli/README.md)                               | **Fork build** (`+selfhost.N`): command-line for interacting with Shorebird services    |
| [shorebird_code_push_client](packages/shorebird_code_push_client/README.md)     | Dart library which allows Dart applications to interact with the Shorebird CodePush API |
| [shorebird_code_push_protocol](packages/shorebird_code_push_protocol/README.md) | Dart library which contains common interfaces used by Shorebird CodePush                |
| [artifact_proxy](packages/artifact_proxy/README.md)                             | Dart server which supports intercepting and proxying Flutter artifact requests          |
| [discord_gcp_alerts](packages/discord_gcp_alerts/README.md)                     | Dart server which forwards GCP alerts to Discord                                        |
| [flutter_version_resolver](packages/flutter_version_resolver/README.md)         | Command-line utility that determines which Flutter version should be used for a project |
| [jwt](packages/jwt/README.md)                                                   | Dart library for verifying JSON Web Tokens                                              |
| [redis_client](packages/redis_client/README.md)                                 | Dart library for interacting with Redis                                                 |
| [scoped_deps](packages/scoped_deps/README.md)                                   | A simple dependency injection library built on Zones                                    |
| [stripe_api](packages/stripe_api/README.md)                                     | Dart library for interacting with Stripe                                                |

For more information, please refer to the documentation for each package.

## Contributing

This is a self-hosted fork; contributions here concern the self-hosted server
and its docs. For upstream Shorebird itself, see the
[Shorebird Discord](https://discord.gg/shorebird). The developer setup below
applies to working in this repository.

### Environment setup

Working on Shorebird requires Dart.

`./scripts/bootstrap.sh` will run `pub get` all packages in the repository.

### Running tests

We don't yet have a script to run tests locally. For now, we recommend using
`very_good test -r` in the packages directory to run all shorebird tests.

(If you run it in the root, it will find packages in bin/cache/flutter and try
to run tests there, some of which will fail.)

`code_push_server` is standalone — it has its own `pubspec.lock` and is not a
workspace member — so run its tests from its own directory:

```
cd packages/code_push_server && dart test -x integration
```

`-x integration` skips the tests that need a live Postgres/MinIO.

To generate a coverage report install `lcov`:

```
brew install lcov
```

Then run tests with the `--coverage` flag:

```
very_good test -r --coverage
genhtml coverage/lcov.info -o coverage
```

You can view the generated coverage report via:

```
open coverage/index.html
```

### Tracking coverage

The following command will generate a coverage report for the Dart packages:

```bash
dart test --coverage=coverage && dart pub global run coverage:format_coverage --lcov --in=coverage --out=coverage/lcov.info --packages=.dart_tool/package_config.json --check-ignore
```

Coverage reports are uploaded to [Codecov](https://app.codecov.io/gh/shorebirdtech/shorebird).

## License

Shorebird projects are licensed for use under either Apache License, Version 2.0
(LICENSE-APACHE or http://www.apache.org/licenses/LICENSE-2.0) MIT license
(LICENSE-MIT or http://opensource.org/licenses/MIT) at your option.

See our license philosophy for more information on why we license files this
way:
https://handbook.shorebird.dev/engineering/#licensing-philosophy
