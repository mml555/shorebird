#!/usr/bin/env bash
# cspell:words PYMANIFEST objm
#
# backup.sh — back up the code_push_server persistent state (scale profile).
#
#   * Postgres metadata  → pg_dump (custom format, compressed)
#   * MinIO artifacts    → `mc mirror` of the artifact bucket to a local dir
#
# Usage:
#   ./ops/backup.sh                 # uses .env + docker-compose.prod.yaml
#   BACKUP_DIR=/mnt/backups ./ops/backup.sh
#   COMPOSE_FILE=docker-compose.prod.yaml ./ops/backup.sh
#
# Restore the output with ops/restore.sh.
#
# THE TWO HALVES ARE ONE BACKUP. They are snapshotted at different instants, so
# unless the deployment is quiesced between them the pair describes a state the
# system was never in. Measured 2026-09-04 on an unquiesced run of the previous
# version of this script: every backup taken while serving contained at least
# one object that no row in the same backup accounted for (4 of 4 runs), and
# some contained an object whose row still said `pending` (2 of 4) — a
# combination the live server cannot produce, because the row is always
# INSERTed before the bytes are written.
#
# So this script now:
#   1. stops the `server` service and REFUSES to snapshot until nothing can
#      write (a `stop || true` that silently no-ops is not quiescing);
#   2. stamps both halves with one shared `backup_id`, so ops/restore.sh can
#      refuse a crossed pair. Two files sharing a timestamp in their names is
#      not provenance — nothing reads a filename.
#
# The output contains PLAINTEXT API KEYS: `api_keys.key` stores the key itself,
# and one of them authenticates as an owner of the root org. Treat a backup as
# a credential store.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"

COMPOSE_FILE="${COMPOSE_FILE:-${ROOT_DIR}/docker-compose.prod.yaml}"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"

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
BACKUP_ID="$(openssl rand -hex 16)"
PG_OUT="${BACKUP_DIR}/postgres_${STAMP}.dump"
PG_MANIFEST="${PG_OUT}.manifest.json"
MINIO_OUT="${BACKUP_DIR}/minio/${STAMP}"

DC=(docker compose -f "${COMPOSE_FILE}")

die() { echo "ERROR: $*" >&2; exit 1; }

mkdir -p "${BACKUP_DIR}" "${MINIO_OUT}"

# --- quiesce, and prove it -------------------------------------------------
echo "==> Stopping the server so both halves describe the same instant"
"${DC[@]}" stop server || die "could not stop the server service — refusing to snapshot a live deployment"

running="$("${DC[@]}" ps -aq server 2>/dev/null | head -1)"
if [[ -n "$running" ]]; then
  state="$(docker inspect "$running" -f '{{.State.Running}}' 2>/dev/null || echo unknown)"
  [[ "$state" == "false" ]] || die "the server container is still running ($state) — refusing to snapshot"
fi
if [[ -n "${PUBLIC_BASE_URL:-}" ]] && curl -fsS --max-time 2 "${PUBLIC_BASE_URL}/healthz" >/dev/null 2>&1; then
  die "something is still serving at ${PUBLIC_BASE_URL} — refusing to snapshot a writable deployment"
fi

# Bring the deployment back and WAIT for it, so the script does not hand back
# control while the server is still starting. Fire-and-forget left a window in
# which the stack looked down to anything scripted around this.
restart_server() {
  "${DC[@]}" start server >/dev/null 2>&1 || true
  [[ -n "${PUBLIC_BASE_URL:-}" ]] || return 0
  for _ in $(seq 1 60); do
    curl -fsS --max-time 2 "${PUBLIC_BASE_URL}/healthz" >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "WARNING: the server did not become healthy at ${PUBLIC_BASE_URL} within 60s" >&2
}
trap restart_server EXIT

echo "==> Postgres backup → ${PG_OUT}"
"${DC[@]}" exec -T postgres \
  pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -Fc \
  > "${PG_OUT}"

# Per-table counts, taken while nothing can write, so a restore can reconcile
# against something more specific than "it did not error". psql emits plain
# `table<TAB>count` lines and python builds the JSON: hand-assembling JSON in
# SQL produced `    apps: 1` — unquoted keys, and an unparseable manifest the
# verifier could not read.
"${DC[@]}" exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -At -F $'\t' -c "
  select tablename,
         (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I', tablename), false, true, '')))[1]::text::bigint
  from pg_tables where schemaname='public' order by tablename" > "${BACKUP_DIR}/.counts.tsv"

python3 - "${PG_OUT}" "${PG_MANIFEST}" "${BACKUP_ID}" "${STAMP}" "${BACKUP_DIR}/.counts.tsv" <<'PYMANIFEST'
import hashlib, json, os, sys
dump, out, bid, stamp, counts_tsv = sys.argv[1:6]
h = hashlib.sha256()
with open(dump, 'rb') as f:
    for chunk in iter(lambda: f.read(1 << 20), b''):
        h.update(chunk)
counts = {}
for line in open(counts_tsv):
    line = line.rstrip('\n')
    if not line:
        continue
    t, n = line.split('\t')
    counts[t] = int(n)
json.dump({
    'format': 'cps-backup/1',
    'backup_id': bid,
    'created_at': stamp,
    'profile': 'scale',
    'half': 'postgres',
    'db_engine': 'postgres',
    'dump_file': os.path.basename(dump),
    'dump_sha256': h.hexdigest(),
    'row_counts': counts,
}, open(out, 'w'), indent=2)
print(f"    tables: {len(counts)}")
PYMANIFEST
rm -f "${BACKUP_DIR}/.counts.tsv"

echo "==> MinIO bucket '${S3_BUCKET}' backup → ${MINIO_OUT}"
"${DC[@]}" run --rm --no-deps \
  -v "${MINIO_OUT}:/backup" \
  --entrypoint /bin/sh \
  createbuckets -c "
    mc alias set local http://minio:9000 '${MINIO_ROOT_USER}' '${MINIO_ROOT_PASSWORD}' &&
    mc mirror --overwrite --remove local/'${S3_BUCKET}' /backup
  "

# The object half carries the SAME backup_id. This is the only thing that makes
# a pair a pair; ops/restore.sh refuses when the two ids disagree.
python3 - "${MINIO_OUT}" "${BACKUP_ID}" "${STAMP}" <<'PY'
import hashlib, json, os, sys
root, bid, stamp = sys.argv[1], sys.argv[2], sys.argv[3]
files = {}
for dirpath, _, names in os.walk(root):
    for n in names:
        p = os.path.join(dirpath, n)
        rel = os.path.relpath(p, root)
        if rel == 'MANIFEST.json':
            continue
        h = hashlib.sha256()
        with open(p, 'rb') as f:
            for chunk in iter(lambda: f.read(1 << 20), b''):
                h.update(chunk)
        files[rel] = h.hexdigest()
json.dump({
    'format': 'cps-backup/1',
    'backup_id': bid,
    'created_at': stamp,
    'profile': 'scale',
    'half': 'objects',
    'object_store': 's3',
    'objects': len(files),
    'files': dict(sorted(files.items())),
}, open(os.path.join(root, 'MANIFEST.json'), 'w'), indent=2)
print(f"    objects: {len(files)}")
PY

echo "==> Done.  backup_id ${BACKUP_ID}"
echo "    postgres : ${PG_OUT}"
echo "    manifest : ${PG_MANIFEST}"
echo "    minio    : ${MINIO_OUT}"
echo "    NOTE: this backup contains plaintext API keys. Store it as a secret."
