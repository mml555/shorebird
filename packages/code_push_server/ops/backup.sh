#!/usr/bin/env bash
#
# backup.sh — back up the code_push_server persistent state.
#
#   * Postgres metadata  → pg_dump (custom format, compressed) via the running
#                          `postgres` compose service.
#   * MinIO artifacts    → `mc mirror` of the artifact bucket to a local dir,
#                          run in a throwaway `mc` container on the stack's
#                          network.
#
# Usage:
#   ./ops/backup.sh                 # uses .env + docker-compose.prod.yaml
#   BACKUP_DIR=/mnt/backups ./ops/backup.sh
#   COMPOSE_FILE=docker-compose.prod.yaml ./ops/backup.sh
#
# Restore the output with ops/restore.sh. Store backups off-host (S3, another
# disk) and test restores regularly. Both artifacts are timestamped so runs
# never clobber each other; prune old ones with your own retention policy.

set -euo pipefail

# Resolve paths relative to this script so it works from any CWD.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"

COMPOSE_FILE="${COMPOSE_FILE:-${ROOT_DIR}/docker-compose.prod.yaml}"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"

# Load .env so POSTGRES_*, MINIO_*, S3_BUCKET, BACKUP_DIR are available.
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

BACKUP_DIR="${BACKUP_DIR:-${ROOT_DIR}/backups}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PG_OUT="${BACKUP_DIR}/postgres_${STAMP}.dump"
MINIO_OUT="${BACKUP_DIR}/minio/${STAMP}"

DC=(docker compose -f "${COMPOSE_FILE}")

mkdir -p "${BACKUP_DIR}" "${MINIO_OUT}"

echo "==> Postgres backup → ${PG_OUT}"
# -Fc = custom (compressed) format, restorable with pg_restore.
"${DC[@]}" exec -T postgres \
  pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -Fc \
  > "${PG_OUT}"

echo "==> MinIO bucket '${S3_BUCKET}' backup → ${MINIO_OUT}"
# Throwaway mc container on the compose network. `local` alias points at the
# in-network minio service; mirror the bucket into a mounted host directory.
"${DC[@]}" run --rm --no-deps \
  -v "${MINIO_OUT}:/backup" \
  --entrypoint /bin/sh \
  createbuckets -c "
    mc alias set local http://minio:9000 '${MINIO_ROOT_USER}' '${MINIO_ROOT_PASSWORD}' &&
    mc mirror --overwrite --remove local/'${S3_BUCKET}' /backup
  "

echo "==> Done."
echo "    postgres : ${PG_OUT}"
echo "    minio    : ${MINIO_OUT}"
