# Production runbook — code_push_server (scale profile)

> **Most deployments don't need this.** The default is a single container with
> embedded SQLite + local-disk artifacts — `./setup.sh`, back up one volume,
> done (see `README.md`). This runbook is the **scale profile**: multiple
> stateless replicas behind Caddy TLS, backed by Postgres + S3/MinIO. Reach for
> it when you outgrow one node or want a managed database. `./setup.sh --scale --domain
> <host>` sets it up for you — **`--scale` is required, and corrected
> 2026-08-13**: this line said `--domain <host>` alone, which selects the
> SINGLE-container stack (`docker-compose.yaml` + `docker-compose.tls.yaml`,
> embedded SQLite + local-disk artifacts) plus a Caddy TLS overlay. Only
> `--scale` selects `docker-compose.prod.yaml`, and it refuses to run without a
> domain. An operator following the old line got TLS and believed they had
> Postgres + S3; the `.env` it writes contains neither `DATABASE_URL` nor
> `S3_ENDPOINT`. `setup.sh:6-7` states both forms. The rest of this doc is the
> manual/operational detail.

A self-hosted Shorebird code-push control plane: a stateless Dart (shelf)
server backed by Postgres (metadata) and MinIO (artifact object storage),
fronted by Caddy for TLS.

```
Internet ──HTTPS──▶ caddy ──HTTP──▶ server ──▶ postgres
                                          └──▶ minio (S3)
```

All durable state lives in Postgres + MinIO. The `server` container itself is
stateless and disposable.

---

## 1. Prerequisites

- A Linux host with Docker Engine + the Compose plugin (`docker compose`).
- A DNS A/AAAA record pointing your domain at the host (needed for real TLS).
- Ports **80** and **443** open to the internet (Caddy uses 80 for the ACME
  HTTP challenge and 443 for HTTPS/HTTP-3).
- These files (all in this directory):
  `Dockerfile`, `.dockerignore`, `docker-compose.prod.yaml`, `Caddyfile`,
  `.env.example`, `ops/backup.sh`, `ops/restore.sh`.

---

## 2. Generate secrets

Every secret must be unique and unguessable. Generate each with:

```bash
openssl rand -hex 32
```

You need fresh values for:

- `URL_SIGNING_SECRET` — signs short-lived download URLs.
- `API_KEY` — bootstrap API key (rotate/remove once real users exist).
- `POSTGRES_PASSWORD` (and the matching password inside `DATABASE_URL`).
- `MINIO_ROOT_PASSWORD` (and the matching `S3_SECRET_KEY`).

---

## 3. First boot

```bash
cp .env.example .env
# Edit .env: set DOMAIN, PUBLIC_BASE_URL, ACME_EMAIL, LOGIN_EMAIL,
# and every "CHANGE ME" secret. Keep the paired values consistent:
#   DATABASE_URL password  == POSTGRES_PASSWORD
#   S3_ACCESS_KEY / SECRET  == MINIO_ROOT_USER / MINIO_ROOT_PASSWORD

docker compose -f docker-compose.prod.yaml up -d --pull missing
```

What happens: Postgres and MinIO start and become healthy, `createbuckets`
creates the `${S3_BUCKET}` bucket and exits, the `server` starts once its
dependencies are healthy, and Caddy obtains a TLS certificate and begins
proxying.

Verify:

```bash
docker compose -f docker-compose.prod.yaml ps
curl -fsS https://$DOMAIN/healthz     # liveness
curl -fsS https://$DOMAIN/readyz      # readiness (DB + S3 reachable)
docker compose -f docker-compose.prod.yaml logs -f server caddy
```

---

## 3b. Validate locally before you go live (optional)

To exercise the full wire contract before configuring DNS/TLS, run the local
stack (`./setup.sh`) and point the smoke test at it:

```bash
./setup.sh
BASE=http://localhost:8080 KEY=<API_KEY from .env> tool/smoke_test.sh
```

This runs create → verify → promote → signed-URL range download → rollback end
to end. Once it passes, run `./setup.sh --down` and switch to the domain flow
below (`./setup.sh --domain …`), which is identical but adds Caddy TLS and
`PRODUCTION=true` (so the DB/S3-credential and HTTPS checks in section 8 are
enforced on top of the placeholder-secret checks, which always run).

## 4. TLS / domain setup

- **Public domain (default):** set `DOMAIN` and `ACME_EMAIL` in `.env`. Caddy
  automatically obtains and renews a Let's Encrypt certificate. Certs persist
  in the `caddy_data` volume — **do not delete it** or you may hit ACME rate
  limits on redeploy.
- **Local / no public DNS:** in `Caddyfile`, comment out `tls {$ACME_EMAIL}`
  and uncomment `tls internal`. Caddy issues a self-signed cert from its own
  CA. You can set `DOMAIN=localhost`. Clients must trust Caddy's local CA (or
  use `curl -k` for testing).
- `PUBLIC_BASE_URL` and `SHOREBIRD_JWT_ISSUER` must match the HTTPS URL devices
  and the CLI use to reach the server, e.g. `https://$DOMAIN`.

---

## 5. Backups & restore

Back up **both** Postgres and MinIO. They are one backup: the metadata
references object keys, and the two halves are only a matched pair if they came
from the same run.

```bash
# Back up. Stops the server for the snapshot, then brings it back and waits
# until it is serving again. Writes three things under $BACKUP_DIR (./backups):
#   postgres_<STAMP>.dump
#   postgres_<STAMP>.dump.manifest.json
#   minio/<STAMP>/          (with its own MANIFEST.json)
./ops/backup.sh

# Restore (DESTRUCTIVE — the script refuses while the server is running)
docker compose -f docker-compose.prod.yaml stop server
./ops/restore.sh backups/postgres_<STAMP>.dump backups/minio/<STAMP>
docker compose -f docker-compose.prod.yaml up -d server
```

**The backup file is a secret.** `api_keys.key` stores the API key itself, not
a digest, and one of those keys authenticates as an owner of the root org.
Anyone holding a backup holds working credentials. Store it where you would
store a password, and rotate keys if a backup is ever exposed.

### What the manifests are for

Both halves carry a shared `backup_id`. `ops/restore.sh` refuses a pair whose
ids disagree, verifies the dump's sha256 and every object's sha256 **before**
touching the target, and reconciles per-table row counts afterwards. This is
not theoretical caution: restoring one run's dump alongside another run's
object snapshot used to succeed silently and leave artifacts the control plane
reported as `verified` and answered 404 for — `patches/check` handed devices a
download URL that did not resolve. Two files sharing a timestamp in their
*names* is not provenance; nothing reads a filename.

The backup also refuses to run unless the server is genuinely stopped. A
snapshot taken while the deployment was serving reliably captured objects that
no row in the same backup accounted for.

### Operational notes

- Copy backups off-host (another disk / bucket / region), encrypted.
- Test a restore into a throwaway stack periodically — an untested backup is
  not a backup.
- Apply a retention policy (the scripts never delete old snapshots).
- Keep a half with its partner. A dump without its `.manifest.json`, or an
  object snapshot without its `MANIFEST.json`, cannot be verified and
  `ops/restore.sh` will refuse it.

### What is NOT in these backups

This is a **control-plane data backup**, not full disaster recovery. Restoring
it into a fresh stack requires you to supply, separately:

| not backed up | why it matters |
|---|---|
| `.env` — `API_KEY`, `URL_SIGNING_SECRET`, DB and S3 credentials | the stack will not boot without them, and `URL_SIGNING_SECRET` must match or every previously-issued download URL breaks |
| TLS material (Caddy's cert store) | reissued automatically on a reachable domain; a private CA is not |
| the container image tag | a restore onto a newer image runs its migrations against the restored schema |
| in-flight resumable upload chunks | staged in the server container's ephemeral filesystem; an interrupted upload does not survive |
| host, DNS, firewall, and volume topology | the compose files describe them, they are not captured |

---

## 6. Upgrades and rollback

```bash
# 1. Back up FIRST (section 5). This backup is the rollback boundary, and it
#    records the image that produced it.
./ops/backup.sh

# 2. Upgrade.
git pull                                  # get the new server source/image
docker compose -f docker-compose.prod.yaml build server
docker compose -f docker-compose.prod.yaml up -d server
```

Migrations run at boot, each in its own transaction.

### Rolling back

```bash
docker compose -f docker-compose.prod.yaml stop server
#   point the compose file back at the previous image, then:
./ops/restore.sh backups/postgres_<STAMP>.dump backups/minio/<STAMP>
docker compose -f docker-compose.prod.yaml up -d server
```

**A rollback moves the binary back. It does not move the schema back.** The two
things that follow from that are enforced, not left to care:

- Starting an old server against a database a newer one has migrated is
  refused: it exits 65 with `FATAL: database schema is at version N but this
  server implements only up to M`. Without that check it boots, answers
  `/healthz` **and** `/readyz` with 200, and 500s the device update path —
  measured, and the reason the check exists.
- Restoring a backup under a different image than the one that produced it is
  refused. Restoring a pre-upgrade backup with the new image still selected
  does not roll anything back; it migrates the restored database forward again
  and reports success. Pass `ALLOW_IMAGE_CHANGE=1` when you mean it.
- Keep the image, not just its name. Every release is also published as
  `:source-<full commit>`, a reference nothing in normal publishing moves; that
  is what keeps a backup's recorded digest pullable after `:latest` and the
  semantic tag have moved on.
- The check is on the image **digest**, not its name. A tag is mutable, and
  this project has published one that misdescribes its code, so a reference
  republished over a different build is refused even though the name matches.
  If the recorded image is not present locally, restore refuses rather than
  falling back to comparing names — pull or build it first.

### If an upgrade fails part-way

Migrations commit one at a time, so a failure at version N leaves versions
before N **already applied**. The failing migration itself rolls back cleanly on
both SQLite and Postgres — no partial DDL survives, and the server refuses to
serve rather than coming up half-migrated — but the database is no longer at the
version you started from.

So the recovery is not "put the old image back", and it is not "retry":

```
stop the candidate  ->  select the old image  ->  restore the pre-upgrade backup
```

Putting the old image back appears to work whenever the migrations in between
happened to be additive, which is exactly the case that hides the problem until
one of them is not. Certified in `selfhost/upgrade_rollback/`.

---

## 7. Scaling notes

The `server` keeps no session state in memory — logins, OAuth codes, refresh
tokens and IdP CSRF state all live in Postgres — so it scales horizontally
behind Caddy:

```bash
docker compose -f docker-compose.prod.yaml up -d --scale server=3
```

**Two things are still per-instance. Check both before scaling past one:**

- **`UPLOAD_METHOD=resumable` requires a single replica** (or sticky sessions).
  Resumable uploads stage `.partial` chunks on the instance's local disk, so
  chunks that land on different replicas produce a truncated artifact. The
  default `multipart` is a single request and scales fine.
- **`RATE_LIMIT_BACKEND=memory` counts per instance**, making the effective
  limit `RATE_LIMIT_PER_MINUTE × replicas`. Set `RATE_LIMIT_BACKEND=postgres`
  for a shared window (section 9).

Caddy's `reverse_proxy server:8080` load-balances across replicas via
Docker's internal DNS. All replicas share the **same** Postgres and MinIO, so
those become the scaling bottleneck — scale them independently:

- **Postgres:** move to a managed instance or a primary + read replicas;
  point `DATABASE_URL` at it and drop the in-compose `postgres` service.
- **MinIO:** run a distributed MinIO cluster or use a managed S3-compatible
  store; point `S3_ENDPOINT` / credentials at it.

For real load, run Postgres and MinIO as managed/external services and keep
only stateless `server` replicas + Caddy in compose.

---

## 8. Security checklist

- [ ] **Rotate the bootstrap API key** (`API_KEY`) once real per-user keys are
      seeded. Set it to a fresh random value — never to an empty string, which
      the server refuses to boot on.
- [ ] **Never run the published placeholders.** `API_KEY=sb_api_selfhost_dev`
      and `URL_SIGNING_SECRET=dev-url-signing-secret` are committed to this
      repository; the server refuses to boot on either in *every* mode, not
      just `PRODUCTION=true`. The first authenticates as an owner of the root
      org (server admin), the second forges `/download` URLs.
- [ ] **Set real secrets** — no `CHANGE_ME`, no dev defaults. Confirm
      `URL_SIGNING_SECRET`, DB and MinIO credentials are all
      unique `openssl rand -hex 32` values.
- [ ] **Restrict the MinIO console** — it is bound to `127.0.0.1:19001` only;
      reach it via SSH tunnel (`ssh -L 19001:127.0.0.1:19001 host`), never
      expose it publicly.
- [ ] **Network isolation** — only Caddy publishes ports (80/443). The
      `server`, `postgres`, and MinIO S3 API stay on the internal `cps`
      network with no host ports.
- [ ] **`.env` hygiene** — never commit it; restrict file perms
      (`chmod 600 .env`); rotate secrets if leaked.
- [ ] **TLS** — verify HTTPS works and HTTP redirects; keep the `caddy_data`
      volume backed up so certs survive redeploys.
- [ ] **Host firewall** — allow only 80/443 (and your admin SSH) inbound.
- [ ] **Backups verified** — a restore has been tested end to end.
- [ ] **`LOGIN_EMAIL`** set to the intended operator account for OAuth login.
- [ ] **`TRUSTED_PROXIES` matches your actual proxy** (section 9). Wrong either
      way and the IP rate limit is useless or throttles everyone as one client.
- [ ] **`DB_SSL_MODE=verify-full`** whenever `DATABASE_URL` points at a
      managed/external Postgres. The server logs a warning at boot when a
      non-local database is reached with SSL off.
- [ ] **`POST /admin/users` is operator-only** — it issues API keys and returns
      the existing account on an email conflict, so it requires an owner/admin
      of the root organization (the identity `API_KEY` maps to). Keep that key
      out of app-team hands; give teammates their own per-user keys. Every use
      is audited as `user.create`, with `account_existed` and a fingerprint of
      the key it issued — periodically review
      `?operation=user.create&result=success`.
- [ ] **Review access-control history after any incident** —
      `?operation=app.collaborator.add,app.collaborator.remove,org.member.role,org.domains`.
      Refused attempts are recorded too, with the role they asked for.
- [ ] **`GET /admin/audit` is operator-only** — the mutation trail names who
      shipped what across the whole deployment, so it requires an owner/admin
      of the root organization. Reading it is not something an app-team
      `developer` collaborator needs.
- [ ] **Decide `AUDIT_RETENTION_DAYS`** — unset (the default) keeps the audit
      trail forever, which is usually what you want. Set it only if you have a
      retention policy that says otherwise.
- [ ] **Alert on `code_push_audit_write_failures_total > 0`** — above zero, the
      durable trail has holes: some mutation happened whose row did not land.
      The event is still on stdout (with `audit_persisted: false`) and logged as
      `AUDIT WRITE FAILED`, so nothing is lost if you ship logs.
- [ ] **Updates** — keep base images (postgres/minio/caddy/dart) patched.

---

## 8b. Answering "who changed this?"

Every mutating patch-lifecycle request writes one structured row, readable
without SQL:

```bash
KEY=<root-org API key>; BASE=https://your.host

# What happened to release 142?
curl -sH "Authorization: Bearer $KEY" \
  "$BASE/admin/audit?release_id=142&operation=patch.create,patch.promote,patch.withdraw"

# Everything one request did, from the X-Request-Id a caller reported
curl -sH "Authorization: Bearer $KEY" "$BASE/admin/audit?request_id=req_…"

# Everything refused in the last day
curl -sH "Authorization: Bearer $KEY" \
  "$BASE/admin/audit?result=refused&since=$(date -u -v-1d +%Y-%m-%dT%H:%M:%SZ)"

# Who changed access to an app, what did they attempt, did it succeed?
curl -sH "Authorization: Bearer $KEY" \
  "$BASE/admin/audit?app_id=$APP&operation=app.collaborator.add,app.collaborator.remove"

# Everything ever done to one account, and which key was issued to it
curl -sH "Authorization: Bearer $KEY" \
  "$BASE/admin/audit?target_kind=user&target=someone@example.com"

# Which request issued a key you found in a CI config (fingerprint, then search)
printf %s "$suspect_key" | shasum -a 256 | cut -c1-12
```

Role and policy changes bank both sides (`role_before` / `role_after`,
`domains_before` / `domains_after`), and a refused attempt keeps the value it
asked for — so a self-granted `owner` that was rejected is still visible as an
attempt to grant `owner`.

Field reference and the pattern for proving something published *nothing* (the
`ceiling` snapshot): [`../../selfhost/API_REFERENCE.md`](../../selfhost/API_REFERENCE.md#audit-log).

`LOG_FORMAT=json` also puts each event on stdout as one
`{"msg":"audit", …}` object, so a stack that ships container logs can query
mutations there. The database table stays the durable record; the log line is
the copy that survives the database being the thing that broke.

---

## 9. Optional feature configuration

These env vars (read by `lib/src/config.dart`) are all optional and ship with
safe defaults. Add them to `.env` only when you want the behavior.

### Rate-limit backend

```bash
# `memory` (default): in-process fixed window, per server instance, resets on
# restart. `postgres`: shared window across restarts AND replicas.
RATE_LIMIT_BACKEND=memory
```

Set `RATE_LIMIT_BACKEND=postgres` when you run more than one `server` replica
(section 7) — otherwise each replica keeps its own counter and the effective
limit is `RATE_LIMIT_PER_MINUTE × replicas`.

### Client identification behind a proxy

```bash
# Proxies whose X-Forwarded-For is believed: literal IPs, IPv4 CIDR, or `*`.
# Default: 127.0.0.1,::1
TRUSTED_PROXIES=172.16.0.0/12

# Per-source-IP ceiling. Default: 10 × RATE_LIMIT_PER_MINUTE.
RATE_LIMIT_IP_PER_MINUTE=6000
```

Every request is charged against two buckets: its source IP
(`RATE_LIMIT_IP_PER_MINUTE`) and its bearer token
(`RATE_LIMIT_PER_MINUTE`). The IP bucket is the one that actually holds — the
bearer is supplied by the caller and is not validated until after rate limiting
runs, so a caller rotating it would otherwise get a fresh window per request.

That makes `TRUSTED_PROXIES` load-bearing. `X-Forwarded-For` is written by the
client, so it is used only when the socket peer is a proxy on this list:

- **Set it too wide** (`*` on a server reachable from the internet) and any
  caller can rotate the header for an unlimited supply of buckets. `*` means
  "believe `X-Forwarded-For` from any peer" — use it only when nothing but
  your proxy can reach the server, e.g. a load balancer whose address is
  dynamic or IPv6 (the CIDR matcher is IPv4-only).
- **Set it too narrow** and every request arrives as your proxy's IP, so the
  whole fleet shares one window.

With the shipped compose, Caddy is the only thing that can reach `server` (no
host ports are published), and it lives on the Docker bridge network — hence
`172.16.0.0/12`, which `setup.sh` writes into `.env` for both proxied modes.
Confirm the actual subnet with `docker network inspect
code_push_server_default` (single container + TLS) or
`docker network inspect code_push_server_cps` (scale profile).

### Upload method

```bash
# `multipart` (default): single POST upload. `resumable`: GCS-style chunked
# PUT with Content-Range/308, advertised to the CLI on artifact register.
UPLOAD_METHOD=multipart
```

Leave as `multipart` unless you specifically need resumable uploads (large
artifacts over flaky links).

### External OAuth IdP broker

Point `shorebird login` at a real IdP (Google, Microsoft/Entra, Okta, …).
Broker mode activates only when `IDP_CLIENT_ID` + both URLs are set; otherwise
`/login` serves a form that requires an API key and signs the caller in as
whoever that key belongs to (the bootstrap key maps to `LOGIN_EMAIL`, which is
made an owner of the root organization at boot). Register the redirect URI
`<PUBLIC_BASE_URL>/oauth/callback` at the IdP. Full walkthrough:
`selfhost/IDP_SETUP.md`.

```bash
IDP_CLIENT_ID=                       # empty = broker OFF
IDP_CLIENT_SECRET=CHANGE_ME          # OAuth client secret (secret — treat like a password)
IDP_AUTHORIZE_URL=                   # e.g. https://accounts.google.com/o/oauth2/v2/auth
IDP_TOKEN_URL=                       # e.g. https://oauth2.googleapis.com/token
IDP_SCOPES=openid email              # MUST include a scope that yields the email claim
```

- Google: authorize `https://accounts.google.com/o/oauth2/v2/auth`,
  token `https://oauth2.googleapis.com/token`.
- Microsoft/Entra: authorize
  `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize`,
  token `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token`.

Add to the security checklist when broker mode is on:

- [ ] **`IDP_CLIENT_SECRET`** is a real secret, kept out of git (like every
      other secret in `.env`).
- [ ] The IdP redirect URI is `<PUBLIC_BASE_URL>/oauth/callback` over HTTPS.
