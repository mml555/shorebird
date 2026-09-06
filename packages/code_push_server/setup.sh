#!/usr/bin/env bash
#
# setup.sh — one-click setup for the self-hosted Shorebird control plane.
#
#   ./setup.sh                          # single container, HTTP (dev + device testing)
#   ./setup.sh --domain cps.you.com     # single container + HTTPS (Caddy TLS)
#   ./setup.sh --scale --domain cps.you.com   # Postgres + S3/MinIO scale stack
#   ./setup.sh --down                   # stop everything
#   ./setup.sh --backup                 # snapshot the data volume (single-container)
#   ./setup.sh --restore <file.tgz>     # restore a snapshot (single-container)
#   ./setup.sh --backup --volume NAME   # name the target volume explicitly
#   ./setup.sh --restore F --allow-image-change   # restore into a different version
#
# It generates all secrets, starts the stack, waits until healthy, and prints
# what to do next. Re-running is safe (keeps your .env).
# cspell:words cands cpslib IMGID
set -euo pipefail
cd "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

MODE=single DOMAIN="" EMAIL="" ACTION=up RESTORE_FILE="" VOLUME="" ALLOW_IMAGE_CHANGE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)  DOMAIN="${2:?--domain needs a hostname}"; shift 2 ;;
    --email)   EMAIL="${2:?--email needs an address}"; shift 2 ;;
    --scale)   MODE=scale; shift ;;
    --down)    ACTION=down; shift ;;
    --backup)  ACTION=backup; shift ;;
    --restore) ACTION=restore; RESTORE_FILE="${2:?--restore needs a file}"; shift 2 ;;
    --volume)  VOLUME="${2:?--volume needs a docker volume name}"; shift 2 ;;
    --allow-image-change) ALLOW_IMAGE_CHANGE=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m ✓\033[0m %s\n' "$*"; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
gen()  { openssl rand -hex 32; }

command -v docker >/dev/null 2>&1 || die "Docker is required — install Docker Desktop / Engine first."
docker compose version >/dev/null 2>&1 || die "The Docker Compose plugin is required (docker compose)."

# TLS single-container needs both compose files; scale uses the prod stack.
TLS=0; [[ -n "$DOMAIN" ]] && TLS=1
if [[ "$MODE" == scale ]]; then
  [[ -n "$DOMAIN" ]] || die "--scale needs --domain <host> (the scale stack terminates TLS at Caddy)."
  COMPOSE=(docker compose -f docker-compose.prod.yaml)
elif [[ "$TLS" == 1 ]]; then
  COMPOSE=(docker compose -f docker-compose.yaml -f docker-compose.tls.yaml)
else
  COMPOSE=(docker compose)  # single container, HTTP
fi

# --- resolve the single-container data volume (for backup/restore) ----------
# The compose-derived lookup is the only authoritative one. The old fallback
# was `docker volume ls -q | grep -E 'cps_data$' | head -1`, which picks ANY
# volume on the host whose name ends `cps_data` — and `--restore` had a looser
# one still. Measured 2026-09-04: running `--restore` from a directory with no
# deployment of its own wiped a different, live, healthy deployment's volume,
# announcing the correct-looking `Restoring … into single_cps_data`. Guessing
# the target of a destructive operation is not a convenience worth having, so
# an ambiguous resolution now refuses and asks for --volume.
data_volume() {
  local cid v
  cid="$(docker compose ps -aq server 2>/dev/null | head -1)"
  if [[ -n "$cid" ]]; then
    v="$(docker inspect "$cid" -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' 2>/dev/null)"
    [[ -n "$v" ]] && { echo "$v"; return 0; }
  fi
  return 1
}

# Resolve the volume or refuse, naming what the operator can do about it.
resolve_volume() {
  local v
  if [[ -n "$VOLUME" ]]; then
    docker volume inspect "$VOLUME" >/dev/null 2>&1 || die "no such docker volume: $VOLUME"
    echo "$VOLUME"; return
  fi
  if v="$(data_volume)"; then echo "$v"; return; fi
  local cands; cands="$(docker volume ls -q | grep -E 'cps_data$' || true)"
  if [[ -z "$cands" ]]; then
    die "No data volume for this deployment (no 'server' container here). Scale mode: use ops/backup.sh."
  fi
  die "This directory has no running 'server' container, so the target volume is ambiguous.
   Candidates on this host:
$(printf '     %s\n' $cands)
   Re-run from the deployment's own directory, or name it explicitly:
     $0 --$ACTION --volume <name>"
}

# Wait for the deployment to serve again after a stop, so --backup does not
# return while the server is still starting.
wait_healthy() {
  local port; port="$(grep -E '^PORT=' .env 2>/dev/null | cut -d= -f2)"; port="${port:-8080}"
  for _ in $(seq 1 60); do
    curl -fsS --max-time 2 "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1 && return 0
    sleep 1
  done
  printf '\033[33m !\033[0m the server did not become healthy on 127.0.0.1:%s within 60s\n' "$port" >&2
}

# The image this compose will start. A backup and a server binary are a matched
# pair only if the binary implements the schema the backup carries, so both
# --backup and --restore need to know which image is selected.
compose_image() {
  docker compose config 2>/dev/null \
    | awk '/^  server:/{f=1} f && /^    image:/{print $2; exit}'
}

# Every identity a local image answers to: its repo digests and its own id.
# A backup records ONE of these; any of them identifies the same bytes, so the
# comparison is set membership rather than string equality against whichever
# one happened to be first at backup time.
image_identities() {
  docker image inspect "$1" -f '{{range .RepoDigests}}{{println .}}{{end}}{{.Id}}' 2>/dev/null \
    | sed '/^$/d'
}

# Assert quiescence, and put the deployment back if the assertion refuses.
# Both callers stop the server before asserting, so a bare `die` here left the
# deployment DOWN -- a safety check causing the outage it exists to prevent,
# and (measured) enough to contaminate the next check that assumed a running
# neighbour. assert_quiesced runs in a subshell so its specific reason still
# reaches stderr before the server is brought back.
require_quiesced() {
  if ! ( assert_quiesced "$1" ); then
    "${COMPOSE[@]}" start server >/dev/null 2>&1 || true
    die "refusing to touch $1 while it is still writable — the deployment has been restarted, nothing was changed."
  fi
}

# Prove the deployment cannot be written to. `stop server || true` discarded
# both the output and the exit status, so a no-op stop was indistinguishable
# from a real one and the tar ran against a live volume — measured, and it
# produced a torn archive in 1 of 5 runs while the quiesced arm produced 0 of 5.
# A snapshot is not taken unless this returns cleanly.
assert_quiesced() {
  local vol=$1 cid running port
  cid="$(docker compose ps -aq server 2>/dev/null | head -1)"
  if [[ -n "$cid" ]]; then
    running="$(docker inspect "$cid" -f '{{.State.Running}}' 2>/dev/null || echo unknown)"
    [[ "$running" == "false" ]] || die "the server container is still running ($running) — refusing to snapshot a live volume"
  fi
  # Anything else still holding the volume can write to it too.
  local holders
  holders="$(docker ps -q --filter volume="$vol" 2>/dev/null || true)"
  if [[ -n "$holders" ]]; then
    die "these running containers still have $vol mounted — refusing to snapshot:
$(docker ps --filter volume="$vol" --format '     {{.Names}} ({{.Image}})')"
  fi
  # And nothing may still be answering on the published port.
  port="$(grep -E '^PORT=' .env 2>/dev/null | cut -d= -f2)"; port="${port:-8080}"
  if curl -fsS --max-time 2 "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then
    die "something is still serving on 127.0.0.1:${port} — refusing to snapshot a writable deployment"
  fi
}

case "$ACTION" in
  down)
    say "Stopping the stack…"; "${COMPOSE[@]}" down; ok "Stopped."; exit 0 ;;
  backup)
    V="$(resolve_volume)"
    mkdir -p backups; STAMP="$(date -u +%Y%m%dT%H%M%SZ)"; NAME="cps-backup-$STAMP.tgz"
    BID="$(openssl rand -hex 16)"
    say "Backing up volume $V (the server stops for the snapshot)…"
    "${COMPOSE[@]}" stop server >/dev/null 2>&1 || true
    require_quiesced "$V"

    # The manifest travels INSIDE the archive; it is what lets a restore check
    # the archive before it destroys anything. See ops/lib/write_manifest.sh.
    IMG="$(compose_image)"
    IMGID="$(docker image inspect "$IMG" -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}{{.Id}}{{end}}' 2>/dev/null || echo unknown)"
    docker run --rm -v "$V":/data -v "$PWD/ops/lib":/opt/cpslib:ro \
      -e BID="$BID" -e STAMP="$STAMP" -e IMAGE="$IMG" -e IMAGE_ID="$IMGID" \
      busybox sh /opt/cpslib/write_manifest.sh
    docker run --rm -v "$V":/data -v "$PWD/backups":/backup busybox \
      tar czf "/backup/$NAME" -C /data --exclude='code_push.db-shm' .
    # A sidecar copy, so a backup can be identified without unpacking it.
    docker run --rm -v "$V":/data -v "$PWD/backups":/backup busybox \
      sh -c "cp /data/MANIFEST.json '/backup/${NAME%.tgz}.manifest.json'; rm -f /data/MANIFEST.json"
    "${COMPOSE[@]}" start server >/dev/null 2>&1 || true
    wait_healthy
    ok "Wrote backups/$NAME  ($(du -h "backups/$NAME" | cut -f1)), backup_id $BID."
    say "It contains PLAINTEXT API KEYS (api_keys.key holds the key itself). Store it as you would a password."
    exit 0 ;;
  restore)
    [[ -f "$RESTORE_FILE" ]] || die "no such file: $RESTORE_FILE"
    ABS="$(cd "$(dirname "$RESTORE_FILE")" && pwd)/$(basename "$RESTORE_FILE")"
    V="$(resolve_volume)"
    BN="$(basename "$ABS")"; BD="$(dirname "$ABS")"

    # VALIDATE BEFORE DESTROYING. The previous restore ran `rm -rf /data/*` and
    # then `tar xzf`, validating nothing: a truncated archive destroyed the
    # copy the operator still had (303 rows left with 4 objects on disk), and a
    # well-formed archive with no database restored with exit 0, a green tick
    # and a healthy server holding zero apps, releases and audit records. Both
    # are caught here, with the live volume still intact.
    say "Validating $BN before touching ${V}…"
    docker run --rm -v "$BD":/backup:ro busybox sh -c "tar tzf '/backup/$BN' >/dev/null" \
      || die "archive is not a readable gzip tar (truncated or corrupt): $BN"
    docker run --rm -v "$BD":/backup:ro -v "$PWD/ops/lib":/opt/cpslib:ro busybox sh -c "
      mkdir -p /tmp/r && cd /tmp/r && tar xzf '/backup/$BN' && sh /opt/cpslib/verify_manifest.sh" \
      || die "archive failed verification — NOTHING was changed on $V.
   If this predates manifests, verify it by hand and extract it yourself."

    # "Restore onto the image the backup came from, then upgrade" was
    # documented guidance and nothing enforced it. Measured 2026-09-06:
    # restoring a pre-upgrade backup with the successor image still selected
    # printed `✓ Restored`, came up healthy, and had already migrated the
    # restored database straight back to the schema the operator was rolling
    # back FROM. A rollback that silently re-upgrades is worse than one that
    # fails, because nothing distinguishes it from success.
    WANT_IMG="$(tar xzOf "$ABS" ./MANIFEST.json 2>/dev/null \
      | sed -n 's/.*"server_image": "\([^"]*\)".*/\1/p' | head -1)"
    HAVE_IMG="$(compose_image)"
    if [[ -z "$HAVE_IMG" ]]; then
      die "cannot tell which image this compose would start — it declares no 'server' service.
   Run --restore from the deployment's own directory."
    fi
    if [[ -n "$WANT_IMG" && "$WANT_IMG" != unknown && "$WANT_IMG" != "$HAVE_IMG" ]]; then
      if [[ "$ALLOW_IMAGE_CHANGE" == 1 ]]; then
        say "image differs from the backup's ($WANT_IMG -> $HAVE_IMG); continuing because --allow-image-change was given."
      else
        die "this backup was taken by a different server image.
     backup was taken under : $WANT_IMG
     this compose will start: $HAVE_IMG
   Restoring it here does not roll anything back — the selected image will
   migrate the restored database forward again as soon as it boots.
   Point the compose file at $WANT_IMG and re-run, or pass
   --allow-image-change if you meant to restore into a different version."
      fi
    fi

    # A matching REFERENCE is not a matching image. A tag is mutable: the same
    # `:1.3.0` can be republished over a different build, and this project has
    # already shipped one such image (the git tag code_push_server-v1.3.0
    # carries schema 8; the published :1.3.0 applies 12). Measured 2026-09-06:
    # with the tag repointed at a different build, restoring a backup taken
    # under the first one was ACCEPTED and migrated the restored database to a
    # schema the backup had never seen. So the recorded identity is enforced,
    # not merely recorded.
    WANT_ID="$(tar xzOf "$ABS" ./MANIFEST.json 2>/dev/null \
      | sed -n 's/.*"server_image_id": "\([^"]*\)".*/\1/p' | head -1)"
    if [[ -n "$WANT_ID" && "$WANT_ID" != unknown && "$ALLOW_IMAGE_CHANGE" != 1 ]]; then
      HAVE_IDS="$(image_identities "$HAVE_IMG")"
      if [[ -z "$HAVE_IDS" ]]; then
        die "cannot resolve $HAVE_IMG to an image identity, and this backup records one.
     backup was taken under: $WANT_ID
   Pull or build that image so the identity can be checked, or pass
   --allow-image-change if you accept restoring under an unverified image."
      fi
      if ! printf '%s\n' "$HAVE_IDS" | grep -qxF "$WANT_ID"; then
        die "the selected image has the right NAME but is a different build.
     backup was taken under : $WANT_ID
     $HAVE_IMG resolves to  : $(printf '%s' "$HAVE_IDS" | tr '\n' ' ')
   A tag is mutable; the same reference can be republished over different
   code. Select the recorded build, or pass --allow-image-change."
      fi
    fi

    say "Restoring $ABS into $V (DESTRUCTIVE, brief pause)…"
    "${COMPOSE[@]}" stop server >/dev/null 2>&1 || true
    # The same proof --backup requires, for the same reason. Reading a live
    # volume produces a torn archive; WIPING one loses whatever the writer was
    # in the middle of, and `stop server || true` cannot tell a real stop from
    # a no-op. Validating the archive first is not enough: the destination has
    # to be provably quiet before `rm -rf /data/*` runs.
    require_quiesced "$V"
    docker run --rm -v "$V":/data -v "$BD":/backup:ro busybox \
      sh -c "rm -rf /data/* /data/..?* 2>/dev/null; tar xzf '/backup/$BN' -C /data; rm -f /data/MANIFEST.json"
    "${COMPOSE[@]}" up -d >/dev/null 2>&1
    ok "Restored. Server restarting."
    exit 0 ;;
esac

# --- detect a device-reachable base URL (local mode) ------------------------
lan_ip() {
  if command -v ipconfig >/dev/null 2>&1; then
    ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true
  fi
  command -v hostname >/dev/null 2>&1 && hostname -I 2>/dev/null | awk '{print $1}' || true
}

# --- generate .env once -----------------------------------------------------
if [[ -f .env ]]; then
  say "Using existing .env (delete it to regenerate)."
elif [[ "$MODE" == scale ]]; then
  say "Generating .env with fresh secrets (scale: Postgres + S3/MinIO)…"
  : "${EMAIL:=admin@$DOMAIN}"; DBPW="$(gen)"; MINPW="$(gen)"
  cat > .env <<EOF
# Generated by setup.sh ($(date -u +%FT%TZ)) — SCALE (Postgres + S3). Never commit.
DOMAIN=$DOMAIN
ACME_EMAIL=$EMAIL
PRODUCTION=true
PORT=8080
PUBLIC_BASE_URL=https://$DOMAIN
SHOREBIRD_JWT_ISSUER=https://$DOMAIN
DATABASE_URL=postgres://cps:$DBPW@postgres:5432/code_push
S3_ENDPOINT=http://minio:9000
S3_ACCESS_KEY=cps
S3_SECRET_KEY=$MINPW
S3_BUCKET=code-push-artifacts
API_KEY=sb_api_$(gen)
URL_SIGNING_SECRET=$(gen)
DOWNLOAD_URL_TTL=300
RATE_LIMIT_PER_MINUTE=600
RATE_LIMIT_BACKEND=postgres
# Caddy proxies to the server from the compose bridge network, so its address
# is what the server sees as the peer. Naming that range here is what lets
# X-Forwarded-For be believed -- without it every device in the fleet shares a
# single rate-limit bucket. See PRODUCTION.md section 9.
TRUSTED_PROXIES=172.16.0.0/12
LOGIN_EMAIL=$EMAIL
POSTGRES_USER=cps
POSTGRES_PASSWORD=$DBPW
POSTGRES_DB=code_push
MINIO_ROOT_USER=cps
MINIO_ROOT_PASSWORD=$MINPW
BACKUP_DIR=./backups
EOF
  ok ".env written."
elif [[ "$TLS" == 1 ]]; then
  say "Generating .env with fresh secrets (single container + HTTPS)…"
  : "${EMAIL:=admin@$DOMAIN}"
  cat > .env <<EOF
# Generated by setup.sh ($(date -u +%FT%TZ)) — single container + TLS. Never commit.
# Backend: embedded SQLite + filesystem artifacts (cps_data volume). No Postgres/MinIO.
DOMAIN=$DOMAIN
ACME_EMAIL=$EMAIL
PRODUCTION=true
PUBLIC_BASE_URL=https://$DOMAIN
API_KEY=sb_api_$(gen)
URL_SIGNING_SECRET=$(gen)
# Caddy proxies to the server from the compose bridge network (see above).
TRUSTED_PROXIES=172.16.0.0/12
LOGIN_EMAIL=$EMAIL
EOF
  ok ".env written."
else
  say "Generating .env with fresh secrets (single container, local)…"
  IP="$(lan_ip)"; BASE="http://${IP:-localhost}:8080"
  cat > .env <<EOF
# Generated by setup.sh ($(date -u +%FT%TZ)) — single container, local. Never commit.
# Backend: embedded SQLite + filesystem artifacts (cps_data volume). No Postgres/MinIO.
# PUBLIC_BASE_URL must be reachable from your test device (detected LAN IP).
PUBLIC_BASE_URL=$BASE
# The compose file binds the published port to loopback by default so a stray
# \`docker compose up\` can't put the control plane on every host interface.
# A test device has to reach it over the LAN, so open it here -- now that the
# secrets above are freshly generated rather than the published placeholders.
HOST_BIND=0.0.0.0
API_KEY=sb_api_$(gen)
URL_SIGNING_SECRET=$(gen)
LOGIN_EMAIL=you@example.com
EOF
  ok ".env written."
fi

# --- start ------------------------------------------------------------------
say "Starting the stack (first run pulls the images)…"
"${COMPOSE[@]}" up -d --pull missing

# --- wait for readiness -----------------------------------------------------
set -a; . ./.env; set +a
if [[ -n "$DOMAIN" ]]; then HEALTH="https://$DOMAIN/readyz"; CURLF=(-sk); BASE_URL="https://$DOMAIN"
else HEALTH="http://localhost:8080/readyz"; CURLF=(-s); BASE_URL="$PUBLIC_BASE_URL"; fi

say "Waiting for the server to become ready…"
READY=0
for _ in $(seq 1 60); do
  if curl "${CURLF[@]}" "$HEALTH" 2>/dev/null | grep -q '"db":true'; then READY=1; break; fi
  sleep 1
done
[[ "$READY" == 1 ]] || die "Server did not become ready. Check logs: ${COMPOSE[*]} logs server"
ok "Server is up and ready ($HEALTH)."

# --- print next steps -------------------------------------------------------
[[ "$MODE" == scale ]] && FOOTPRINT="scale: Postgres + S3/MinIO" || FOOTPRINT="single container: SQLite + files (one volume)"
cat <<EOF

────────────────────────────────────────────────────────────────────────────
 🎉  Your self-hosted Shorebird control plane is running.
     ($FOOTPRINT)

   Server URL   : $BASE_URL
   API key      : $API_KEY
   Console      : $BASE_URL/console     (dashboard)

 To ship an app through it — from your Flutter app directory:

   export SHOREBIRD_HOSTED_URL=$BASE_URL
   export SHOREBIRD_TOKEN=$API_KEY
   shorebird init                       # then add to shorebird.yaml:
                                        #   base_url: $BASE_URL
   shorebird release android
   shorebird patch android

 Common commands:
   ${COMPOSE[*]} logs -f server         # tail logs
   ./setup.sh --down                    # stop everything
   ./setup.sh --backup                  # snapshot the data volume
   BASE=$BASE_URL KEY=$API_KEY tool/smoke_test.sh   # self-test (no device)
────────────────────────────────────────────────────────────────────────────
EOF
