#!/usr/bin/env bash
#
# migrate-minio-to-s3.sh — copy the artifact bucket from the old MinIO volume to
# the new object store (SeaweedFS in docker-compose.prod.yaml), once.
#
# MinIO is no longer maintained, and its on-disk format cannot be read by any
# other store, so the data moves over S3: this script starts the old MinIO on
# the old `cps_minio` volume (the `minio-legacy` service, profile `migrate`),
# copies every object with rclone, verifies the copy, and stops the old MinIO.
# It never deletes anything from the old volume.
#
# Usage:
#   ./ops/migrate-minio-to-s3.sh            # migrate, verify, stop the old MinIO
#   DRY_RUN=1 ./ops/migrate-minio-to-s3.sh  # list what would be copied
#   VERIFY=download ./ops/migrate-minio-to-s3.sh   # compare bytes, not hashes
#
# Environment (all optional; .env is read first):
#   MINIO_LEGACY_IMAGE   MinIO image to run for the old volume. Default: the
#                        minio/minio:latest already on this host. Docker Hub no
#                        longer serves it, so the script never pulls.
#   LEGACY_ENDPOINT / LEGACY_ACCESS_KEY / LEGACY_SECRET_KEY
#                        Copy from a MinIO that is already running elsewhere
#                        instead of starting minio-legacy (the volume is then
#                        not touched). The new store is the one in .env.
#
# Safe to re-run: `rclone copy` only adds or updates, and `rclone check` runs
# at the end every time. The server is stopped first, so nothing writes while
# the copy runs; start it again once this prints MIGRATION VERIFIED.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${ROOT_DIR}/docker-compose.prod.yaml}"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"

die() { echo "ERROR: $*" >&2; exit 1; }

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/s3_env.sh"

S3_BUCKET="${S3_BUCKET:-code-push-artifacts}"
export MINIO_LEGACY_IMAGE="${MINIO_LEGACY_IMAGE:-minio/minio:latest}"
DC=(docker compose --progress quiet -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}")
[[ -f "${ENV_FILE}" ]] || DC=(docker compose --progress quiet -f "${COMPOSE_FILE}")
RCLONE=("${DC[@]}" --profile tools run --rm --no-deps -T rclone)
EXTERNAL=0
[[ -n "${LEGACY_ENDPOINT:-}" ]] && EXTERNAL=1
# The legacy credentials default to the MINIO_ROOT_* of the old .env, else the
# S3_* ones (the old and new compose files shared them).
export LEGACY_ACCESS_KEY="${LEGACY_ACCESS_KEY:-${MINIO_ROOT_USER:-${S3_ACCESS_KEY}}}"
export LEGACY_SECRET_KEY="${LEGACY_SECRET_KEY:-${MINIO_ROOT_PASSWORD:-${S3_SECRET_KEY}}}"
export LEGACY_ENDPOINT="${LEGACY_ENDPOINT:-http://minio-legacy:9000}"

config_json="$("${DC[@]}" config --format json 2>/dev/null || true)"
cfg() { python3 -c 'import json,sys; print(eval(sys.argv[1], {"c": json.load(sys.stdin)}))' "$1" <<<"${config_json}" 2>/dev/null || true; }
project="$(cfg 'c["name"]')"
legacy_volume="$(cfg 'c["volumes"]["cps_minio"]["name"]')"
if (( ! EXTERNAL )); then
  docker image inspect "${MINIO_LEGACY_IMAGE}" >/dev/null 2>&1 || die "the old MinIO image '${MINIO_LEGACY_IMAGE}' is not on this host.
   Docker Hub no longer serves minio/minio. Use the image your stack already ran
   (docker image ls | grep minio), then: MINIO_LEGACY_IMAGE=<repo:tag> $0
   Or point LEGACY_ENDPOINT at a MinIO that is running."
  if [[ -n "${legacy_volume}" ]] && ! docker volume inspect "${legacy_volume}" >/dev/null 2>&1; then
    die "no volume '${legacy_volume}': there is no old MinIO data to migrate under compose project '${project}'.
   (Wrong directory or COMPOSE_PROJECT_NAME? A fresh install has nothing to migrate.)"
  fi
fi

echo "==> Stopping the server so nothing writes during the copy"
"${DC[@]}" stop server >/dev/null 2>&1 || true
[[ -z "$("${DC[@]}" ps --status running -q server 2>/dev/null)" ]] \
  || die "the server is still running; stop it and re-run"

if (( ! EXTERNAL )) && [[ -n "${project}" ]]; then
  # The old compose file ran MinIO as service `minio`. The new one has no such
  # service, so `docker compose up` leaves that container running as an orphan,
  # and on the shared network it answers to the same name `minio` as the new
  # store. Left alone, the server would reach one or the other at random. Remove
  # the container (the data is in the cps_minio volume, which is kept).
  orphans="$(docker ps -aq --filter "label=com.docker.compose.project=${project}" --filter "label=com.docker.compose.service=minio")"
  if [[ -n "${orphans}" ]]; then
    echo "==> Removing the old MinIO container (its cps_minio volume is kept)"
    # shellcheck disable=SC2086
    docker rm -f ${orphans} >/dev/null
  fi
fi

echo "==> Starting the new object store"
"${DC[@]}" up -d --wait s3 >/dev/null || die "the new object store did not become healthy (docker compose logs s3)"

if (( ! EXTERNAL )); then
  echo "==> Starting the old MinIO on the cps_minio volume (${MINIO_LEGACY_IMAGE})"
  "${DC[@]}" --profile migrate up -d minio-legacy >/dev/null
fi
cleanup() {
  if (( ! EXTERNAL )); then
    echo "==> Stopping the old MinIO (its volume is untouched)"
    "${DC[@]}" --profile migrate stop minio-legacy >/dev/null 2>&1 || true
    "${DC[@]}" --profile migrate rm -f minio-legacy >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "==> Waiting for the old MinIO to answer"
ready=0
for _ in $(seq 1 60); do
  if "${RCLONE[@]}" lsd legacy: --retries 1 --low-level-retries 1 --contimeout 3s >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
(( ready )) || die "the old MinIO did not answer (wrong LEGACY_* credentials, or it failed to start: docker compose logs minio-legacy)"

"${RCLONE[@]}" lsf "legacy:${S3_BUCKET}" >/dev/null 2>&1 \
  || die "the old MinIO has no bucket '${S3_BUCKET}' (S3_BUCKET in .env)"

echo "==> Old bucket:"
"${RCLONE[@]}" size "legacy:${S3_BUCKET}"

if [[ "${DRY_RUN:-0}" == 1 ]]; then
  echo "==> DRY_RUN: would copy these objects"
  "${RCLONE[@]}" copy "legacy:${S3_BUCKET}" "store:${S3_BUCKET}" --dry-run -v 2>&1 | grep -E "Skipped copy|Not copying|NOTICE" | head -50 || true
  exit 0
fi

echo "==> Copying legacy:${S3_BUCKET} -> store:${S3_BUCKET}"
"${RCLONE[@]}" copy "legacy:${S3_BUCKET}" "store:${S3_BUCKET}" \
  --transfers 4 --checkers 8 --stats-one-line --stats 10s 2>&1 | tail -n 5

echo "==> Verifying every old object exists in the new store with identical content"
verify_flags=(--one-way)
[[ "${VERIFY:-hash}" == download ]] && verify_flags+=(--download)
if "${RCLONE[@]}" check "legacy:${S3_BUCKET}" "store:${S3_BUCKET}" "${verify_flags[@]}"; then
  echo "==> New bucket:"
  "${RCLONE[@]}" size "store:${S3_BUCKET}"
  echo "MIGRATION VERIFIED. Start the stack:  docker compose -f ${COMPOSE_FILE##*/} up -d"
  echo "Keep the cps_minio volume until you have run the new stack for a while; see PRODUCTION.md."
else
  die "MIGRATION NOT VERIFIED: some objects differ or are missing (see above). Nothing was deleted; fix and re-run."
fi
