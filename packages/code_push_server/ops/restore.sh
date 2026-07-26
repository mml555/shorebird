#!/usr/bin/env bash
#
# restore.sh — restore code_push_server state from a backup produced by
# ops/backup.sh.
#
#   * Postgres  → pg_restore into the running `postgres` service.
#   * MinIO     → `mc mirror` a local artifact snapshot back into the bucket.
#
# Usage:
#   ./ops/restore.sh <postgres_dump_file> <minio_snapshot_dir>
#
# Example:
#   ./ops/restore.sh backups/postgres_20260724T120000Z.dump \
#                    backups/minio/20260724T120000Z
#
# WARNING: this is DESTRUCTIVE. pg_restore runs with --clean, dropping and
# recreating objects; the MinIO mirror uses --remove, deleting bucket objects
# that are absent from the snapshot. Stop the `server` service first so nothing
# writes mid-restore:
#
#   docker compose -f docker-compose.prod.yaml stop server

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"

COMPOSE_FILE="${COMPOSE_FILE:-${ROOT_DIR}/docker-compose.prod.yaml}"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <postgres_dump_file> <minio_snapshot_dir>" >&2
  exit 2
fi

PG_DUMP="$1"
MINIO_SNAPSHOT="$2"

[[ -f "${PG_DUMP}" ]]        || { echo "no such postgres dump: ${PG_DUMP}" >&2; exit 1; }
[[ -d "${MINIO_SNAPSHOT}" ]] || { echo "no such minio snapshot dir: ${MINIO_SNAPSHOT}" >&2; exit 1; }

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

POSTGRES_USER="${POSTGRES_USER:-cps}"
POSTGRES_DB="${POSTGRES_DB:-code_push}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-cps}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD must be set}"
S3_BUCKET="${S3_BUCKET:-code-push-artifacts}"

DC=(docker compose -f "${COMPOSE_FILE}")

# Absolute path so it mounts cleanly into the mc container.
MINIO_SNAPSHOT="$(cd -- "${MINIO_SNAPSHOT}" >/dev/null 2>&1 && pwd)"

echo "!! DESTRUCTIVE restore. Ctrl-C within 5s to abort."
sleep 5

echo "==> Restoring Postgres from ${PG_DUMP}"
# --clean --if-exists drops existing objects first; -Fc matches backup.sh.
"${DC[@]}" exec -T postgres \
  pg_restore --clean --if-exists --no-owner \
  -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
  < "${PG_DUMP}"

echo "==> Restoring MinIO bucket '${S3_BUCKET}' from ${MINIO_SNAPSHOT}"
"${DC[@]}" run --rm --no-deps \
  -v "${MINIO_SNAPSHOT}:/restore:ro" \
  --entrypoint /bin/sh \
  createbuckets -c "
    mc alias set local http://minio:9000 '${MINIO_ROOT_USER}' '${MINIO_ROOT_PASSWORD}' &&
    mc mb --ignore-existing local/'${S3_BUCKET}' &&
    mc mirror --overwrite --remove /restore local/'${S3_BUCKET}'
  "

echo "==> Done. Restart the server:"
echo "    ${DC[*]} up -d server"
