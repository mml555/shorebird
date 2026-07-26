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
safe default.

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
  -e JWT_SECRET=$(openssl rand -hex 32) \
  -e URL_SIGNING_SECRET=$(openssl rand -hex 32) \
  -p 127.0.0.1:8080:8080 \
  -v code_push_data:/data \
  code-push-server:latest
```

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

- **Build from source (default):** `./setup.sh` builds `code-push-server:latest`
  locally, or `docker build -t code-push-server:latest .` in this directory.
- **Publish to your registry** (so app teams `docker pull` instead of building):
  ```
  docker build -t registry.yourco.com/code-push-server:1.0 .
  docker push registry.yourco.com/code-push-server:1.0
  ```
  Pin a version tag; the server's compatibility with the Shorebird CLI/updater is
  tracked in `selfhost/compatibility.yaml`.

## Full environment variable contract

Read by `lib/src/config.dart`. Everything has a default; set only what you need.

**Core**
| Var | Default | Purpose |
|---|---|---|
| `PUBLIC_BASE_URL` | `http://localhost:8080` | device-reachable base URL (see above) |
| `PORT` | `8080` | listen port inside the container |
| `DATA_DIR` | `./data` (`/data` in image) | SQLite db + filesystem artifacts |
| `PRODUCTION` | unset | `true` → refuse to boot on dev-default secrets / non-HTTPS |

**Secrets** (generate with `openssl rand -hex 32`; required when `PRODUCTION=true`)
| Var | Default | Purpose |
|---|---|---|
| `API_KEY` | `sb_api_selfhost_dev` | bootstrap API key (rotate; issue per-user keys via `/admin/users`) |
| `JWT_SECRET` | dev value | signs session JWTs (OAuth login) |
| `URL_SIGNING_SECRET` | dev value | signs short-lived artifact download URLs |

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
| `LOGIN_EMAIL` | `you@example.com` | identity for self-consent `shorebird login` (no IdP) |
| `IDP_CLIENT_ID` / `IDP_CLIENT_SECRET` / `IDP_AUTHORIZE_URL` / `IDP_TOKEN_URL` / `IDP_SCOPES` | — | broker `shorebird login` to Google/Microsoft/Okta (see `IDP_SETUP.md`) |

**Tuning**
| Var | Default | Purpose |
|---|---|---|
| `DOWNLOAD_URL_TTL` | `300` | signed download URL lifetime (seconds) |
| `RATE_LIMIT_PER_MINUTE` | `600` | per-client request cap |
| `RATE_LIMIT_BACKEND` | `memory` | `postgres` for a shared window across replicas |
| `UPLOAD_METHOD` | `multipart` | `resumable` for GCS-style chunked uploads |

## Backups

- **Single container:** the `/data` volume is everything. `./setup.sh --backup`
  writes a timestamped tarball (brief pause for a consistent snapshot);
  `./setup.sh --restore <file>` restores it. Or just snapshot the volume with
  your own tooling.
- **Scale:** back up your Postgres and object store as you already do (or see
  `packages/code_push_server/ops/backup.sh`). They must be restored as a pair.

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
