# Integrating into your own stack

This server is designed to drop into an existing app/infrastructure with minimal
footprint. The default is **one container, one volume, no external services** —
but every piece is overridable so it coexists with what you already run.

## The footprint

| | Single container (default) | Scale profile |
|---|---|---|
| Containers | 1 (the server) | server(s) + Postgres + MinIO/S3 (+ Caddy) |
| Persistence | one `/data` volume (SQLite + artifacts) | your Postgres + object store |
| External deps | **none** | a database + an S3-compatible store |
| Good for | most apps, small–mid fleets, on-prem | horizontal scale, existing managed DB |

You do **not** need Redis, a message queue, or a separate database for the
default path.

## The one hard requirement: `PUBLIC_BASE_URL`

The URL you set here is embedded in the artifact download links the on-device
updater fetches, so **it must be reachable from your users' devices** and should
be stable (it's baked into shipped apps via `base_url`). Everything else has a
safe default except the two secrets below, which have no default at all: the
server refuses to boot on the placeholder `API_KEY` / `URL_SIGNING_SECRET`
committed to this repo, because a published default is a default everyone
knows. `setup.sh` generates both for you.

## Running behind your existing reverse proxy

If you already run Nginx / Traefik / Caddy / an ALB, don't use the bundled Caddy
— just proxy to the container's port 8080 and point `PUBLIC_BASE_URL` at the
external URL:

```
# your proxy terminates TLS for https://cps.yourco.com  ->  server:8080
docker run -d --name code-push \
  -e PUBLIC_BASE_URL=https://cps.yourco.com \
  -e PRODUCTION=true \
  -e API_KEY=$(openssl rand -hex 32) \
  -e URL_SIGNING_SECRET=$(openssl rand -hex 32) \
  -e TRUSTED_PROXIES=172.17.0.1 \
  -p 127.0.0.1:8080:8080 \
  -v code_push_data:/data \
  ghcr.io/mml555/code-push-server:1.3.0
```

`TRUSTED_PROXIES` must be **your proxy's address as the container sees it**, not
`127.0.0.1` — `-p 127.0.0.1:8080:8080` binds the *host* side to loopback, but
Docker rewrites the peer to the bridge gateway (usually `172.17.0.1`). Get the
real value from `docker network inspect bridge`. Set it wrong and the server
ignores `X-Forwarded-For`, so every device in your fleet shares one rate-limit
bucket; set it to `*` on a container anyone can reach and the header becomes
spoofable. See the `TRUSTED_PROXIES` row below.

Health endpoints for your orchestrator / load balancer:
- `GET /healthz` — liveness (always 200 if the process is up)
- `GET /readyz` — readiness (`{"db":true,"object_store":true}`; checks the backends)

## Using your existing Postgres / object store

Set `DATABASE_URL` and/or `S3_ENDPOINT` and the server switches those backends on
automatically (no other flag needed):

```
# Bring your own managed Postgres (RDS/Cloud SQL/Neon/…) and S3/R2:
-e DATABASE_URL=postgres://user:pass@db.internal:5432/code_push
-e S3_ENDPOINT=https://s3.us-east-1.amazonaws.com  -e S3_ACCESS_KEY=…  -e S3_SECRET_KEY=…  -e S3_BUCKET=code-push
```

You can mix them — e.g. Postgres for metadata but keep artifacts on the local
volume (set `DATABASE_URL`, leave `S3_ENDPOINT` unset).

## Getting the image

- **Pull the published image (default):** multi-arch (amd64/arm64), built by
  `.github/workflows/release_code_push_server.yaml` from the release tag and
  what the compose files reference.
  ```
  docker pull ghcr.io/mml555/code-push-server:1.3.0
  ```
  Pin the version tag rather than `:latest` — the server's compatibility with
  the Shorebird CLI/updater is tracked in `selfhost/compatibility.yaml`, which
  names one server version at a time.
- **Build from source:** in this directory, `docker build -t
  code-push-server:latest .`, then point the compose `image:` at it (or
  uncomment the `build:` block above it).
- **Mirror into your own registry** (air-gapped, or policy requires it):
  ```
  docker pull ghcr.io/mml555/code-push-server:1.3.0
  docker tag  ghcr.io/mml555/code-push-server:1.3.0 registry.yourco.com/code-push-server:1.3.0
  docker push registry.yourco.com/code-push-server:1.3.0
  ```

## Full environment variable contract

Read by `lib/src/config.dart`. Everything has a default; set only what you need.

**Core**
| Var | Default | Purpose |
|---|---|---|
| `PUBLIC_BASE_URL` | `http://localhost:8080` | device-reachable base URL (see above) |
| `PORT` | `8080` | listen port inside the container |
| `DATA_DIR` | `./data` (`/data` in image) | SQLite db + filesystem artifacts |
| `PRODUCTION` | unset | `true` → also refuse dev-default DB/S3 credentials and a non-HTTPS `PUBLIC_BASE_URL` |

**Secrets** (generate with `openssl rand -hex 32`; **required in every mode**)
| Var | Default | Purpose |
|---|---|---|
| `API_KEY` | none — the placeholder `sb_api_selfhost_dev` is refused at boot | bootstrap API key; also the credential `/login` accepts. Authenticates as an owner of the root org, so a known value is a full admin bypass. Rotate it (never blank it); issue per-user keys via `/admin/users` |
| `URL_SIGNING_SECRET` | none — the placeholder `dev-url-signing-secret` is refused at boot | signs short-lived artifact download URLs; `/download` is public and gated only by this HMAC |

**Backends** (omit for the single-container default)
| Var | Effect |
|---|---|
| `DATABASE_URL` | set → Postgres backend (else embedded SQLite) |
| `S3_ENDPOINT` / `S3_ACCESS_KEY` / `S3_SECRET_KEY` / `S3_BUCKET` | set → S3/MinIO artifacts (else local files) |
| `DB_BACKEND` / `STORAGE_BACKEND` | force `sqlite`/`postgres` and `file`/`s3` explicitly |

**Identity / login**
| Var | Default | Purpose |
|---|---|---|
| `SHOREBIRD_JWT_ISSUER` | `PUBLIC_BASE_URL` | JWT `iss`; must match the CLI |
| `LOGIN_EMAIL` | `owner@self-host.local` | identity for self-consent `shorebird login` (no IdP) |
| `IDP_CLIENT_ID` / `IDP_CLIENT_SECRET` / `IDP_AUTHORIZE_URL` / `IDP_TOKEN_URL` / `IDP_SCOPES` | — | broker `shorebird login` to Google/Microsoft/Okta (see `IDP_SETUP.md`) |

**Tuning**
| Var | Default | Purpose |
|---|---|---|
| `DOWNLOAD_URL_TTL` | `300` | signed download URL lifetime (seconds) |
| `RATE_LIMIT_PER_MINUTE` | `600` | per-principal (bearer) request cap |
| `RATE_LIMIT_IP_PER_MINUTE` | `10 × RATE_LIMIT_PER_MINUTE` | per-source-IP cap; the ceiling a caller can't rotate out of |
| `TRUSTED_PROXIES` | `127.0.0.1,::1` | proxies whose `X-Forwarded-For` is believed (IPs, IPv4 CIDR, or `*`). Wrong value = no effective IP limit, or the whole fleet in one bucket |
| `RATE_LIMIT_BACKEND` | `memory` | `postgres` for a shared window across replicas |
| `UPLOAD_METHOD` | `multipart` | `resumable` for GCS-style chunked uploads |
| `MAX_UPLOAD_BYTES` | `536870912` (512 MiB) | the `413` ceiling on artifact uploads. Added 2026-08-13 — it was missing from a table titled "full", and an operator whose release artifact exceeds it sees a 413 with nothing in this document to explain it |
| `DB_SSL_MODE` | `disable` | Postgres TLS mode. **Validated at boot against an exact list — an unrecognised spelling refuses to start**, so this is not a free-text field. Added 2026-08-13 for that reason: a boot-fail an operator cannot predict from the docs is the worst kind of missing row |

## Backups

Both paths are certified end to end — see
[`backup_restore/`](backup_restore) for what the guarantee covers and, more
usefully, what it does not.

- **Single container:** the `/data` volume is everything. `./setup.sh --backup`
  stops the server for the snapshot (and **refuses** rather than snapshotting a
  volume something can still write to), then writes a timestamped tarball with a
  manifest of every file's sha256. `./setup.sh --restore <file>` verifies the
  archive against that manifest *before* overwriting anything.
- **Scale:** `packages/code_push_server/ops/backup.sh`. The Postgres dump and the
  object snapshot are **one backup**: both halves carry a shared `backup_id`, and
  `ops/restore.sh` refuses a pair whose halves came from different runs. It is not
  a matched pair because the filenames agree — nothing reads a filename.

Three things worth knowing before you rely on either:

- **A backup is a credential store.** `api_keys.key` holds the plaintext key.
  Store backups encrypted, and if one leaks, revoke those rows — rotating the
  deployment's own `API_KEY` does not.
- **`.env` is not in the backup**, deliberately. Back it up separately and
  encrypted; without `URL_SIGNING_SECRET` every previously issued download URL
  breaks.
- **Restore onto the image the backup came from.** This is enforced, not advice:
  the manifest records that image's digest and restore refuses a different build,
  including the same tag republished over different code. Keep the image
  reachable — releases are also published as `:source-<commit>` for exactly that
  reason.

Snapshotting the volume with your own tooling still works, but you lose the
manifest, so a restore cannot check the archive before destroying what is there.

## Connecting your app

One field points both the CLI and the on-device updater at your server — no
engine rebuild, no fork:

```yaml
# your app's shorebird.yaml
app_id: <from `shorebird init`>
base_url: https://cps.yourco.com
```

Then the normal workflow: `shorebird release <platform>` / `shorebird patch
<platform>`, with `SHOREBIRD_HOSTED_URL` + `SHOREBIRD_TOKEN` set to your server
and API key.
