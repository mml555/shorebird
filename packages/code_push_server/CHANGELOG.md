# Changelog

All notable changes to `code_push_server` are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
package follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.0.0 — 2026-07-27

First production release of the self-hosted Shorebird control plane. Runs
Flutter code-push (over-the-air) updates on your own infrastructure — the
unmodified, pinned Shorebird CLI and on-device updater talk to this server, so
no runtime request depends on `api.shorebird.dev` and there is no
per-app/per-user pricing. Device-verified end-to-end on Android, iOS, and macOS
(release → patch → boot → rollback).

### Added

- **Releases & patches** — full CLI wire contract with lifecycle state-machine
  guards and sha256 verification.
- **Channels** — promote, withdraw, and rollback (installed devices revert).
- **Partial rollouts** — deterministic 5 / 25 / 100 % by client, fail-closed.
- **Signed patches** — `hash_signature` pass-through, verified on-device.
- **Multi-tenancy** — users + per-user API keys, orgs + roles, collaborators,
  and invitations, managed in the console **Team** tab.
- **Login** — `shorebird login` via self-consent or a real IdP
  (Google/Microsoft), RS256 JWT mint/verify.
- **Analytics** — adoption / version / install metrics with a web console at
  `/console`.
- **Ops** — signed download URLs, migrations, audit log, rate limiting, health
  checks, and backup/restore tooling.
- **iOS code-signing tooling** (`tool/ios_*.sh`) — auto / manual / resign paths
  with automatic mode selection, a one-command `ios_ship.sh` release+patch flow,
  export-options-plist generation, and a headless CI keychain recipe. See
  `../../selfhost/IOS_ONDEVICE.md`.
- **Observability** — structured JSON logs (all lifecycle logs routed through
  the structured logger) and a Prometheus `/metrics` endpoint.
- **One-command setup** — `./setup.sh` generates secrets, starts everything in
  Docker, waits for health, and prints the server URL, API key, and ship
  commands. `./setup.sh --domain <host>` adds Caddy TLS.

### Deployment profiles

- **Single container (default)** — embedded SQLite + local-disk artifacts under
  one `/data` volume. No Postgres, MinIO, or Redis required.
- **Scale** — stateless replicas backed by Postgres + S3/MinIO behind Caddy TLS,
  selected automatically when `DATABASE_URL` / `S3_ENDPOINT` are set. Same
  features, same wire contract, same code — only the storage backends differ.

### Security & hardening

- Production hardening pass: rate-limit keying, upload size cap, and request
  timeouts.
- Refuses to boot with dev-default secrets when `PRODUCTION=true`.

### Notes

- Billing is intentionally omitted — a self-host does not bill itself.
- Not published to pub.dev (`publish_to: none`); the deliverable is the Docker
  image and this repository at a known-good commit.
