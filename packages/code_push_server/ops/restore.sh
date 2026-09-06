#!/usr/bin/env bash
# cspell:words objm
#
# restore.sh — restore code_push_server state from a backup produced by
# ops/backup.sh (scale profile).
#
#   * Postgres  → pg_restore into the running `postgres` service.
#   * MinIO     → `mc mirror` a local artifact snapshot back into the bucket.
#
# Usage:
#   ./ops/restore.sh <postgres_dump_file> <minio_snapshot_dir>
#
# WARNING: this is DESTRUCTIVE. pg_restore runs with --clean, dropping and
# recreating objects; the MinIO mirror uses --remove, deleting bucket objects
# absent from the snapshot.
#
# THE TWO HALVES MUST BE ONE BACKUP. The previous version took two independent
# paths and compared nothing. Measured 2026-09-04: restoring `pair2`'s dump
# with `pair1`'s mirror exited 0, silently, and produced an artifact the
# restored control plane reported as `verified` and answered 404 for —
# `patches/check` said `patch_available: true`, the download URL it handed the
# device 404'd. The shared `backup_id` written into both halves is what makes
# that detectable; a matching timestamp in two filenames is not provenance,
# because nothing reads a filename.
#
# It also refuses to run against a live server. The old script only *documented*
# stopping it, and a crossed-pair restore ran to completion against a serving
# stack while pg_restore dropped its tables underneath it.

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

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "${PG_DUMP}" ]]        || die "no such postgres dump: ${PG_DUMP}"
[[ -d "${MINIO_SNAPSHOT}" ]] || die "no such minio snapshot dir: ${MINIO_SNAPSHOT}"

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

MINIO_SNAPSHOT="$(cd -- "${MINIO_SNAPSHOT}" >/dev/null 2>&1 && pwd)"
PG_DUMP="$(cd -- "$(dirname "${PG_DUMP}")" >/dev/null 2>&1 && pwd)/$(basename "${PG_DUMP}")"

# --- verify the pair BEFORE destroying anything ----------------------------
PG_MANIFEST="${PG_DUMP}.manifest.json"
OBJ_MANIFEST="${MINIO_SNAPSHOT}/MANIFEST.json"
[[ -f "${PG_MANIFEST}" ]]  || die "the postgres half has no manifest (${PG_MANIFEST}).
   A backup from before manifests cannot be checked against its object half.
   Verify the pairing yourself and run pg_restore / mc mirror by hand."
[[ -f "${OBJ_MANIFEST}" ]] || die "the object half has no manifest (${OBJ_MANIFEST})."

echo "==> Verifying the two halves are one backup"
python3 - "${PG_MANIFEST}" "${OBJ_MANIFEST}" "${PG_DUMP}" "${MINIO_SNAPSHOT}" <<'PY'
import hashlib, json, os, sys
pgm_p, objm_p, dump, root = sys.argv[1:5]
pgm  = json.load(open(pgm_p))
objm = json.load(open(objm_p))

def fail(msg):
    print(f"ERROR: {msg}", file=sys.stderr); sys.exit(1)

for m, name in ((pgm, 'postgres'), (objm, 'objects')):
    if m.get('format') != 'cps-backup/1':
        fail(f"{name} manifest has unsupported format {m.get('format')!r}")
    if m.get('half') != name:
        fail(f"{name} manifest says half={m.get('half')!r}")

if pgm['backup_id'] != objm['backup_id']:
    fail("CROSSED PAIR — these halves come from different backup runs.\n"
         f"   postgres half: backup_id {pgm['backup_id']}  created_at {pgm.get('created_at')}\n"
         f"   object   half: backup_id {objm['backup_id']}  created_at {objm.get('created_at')}\n"
         "   Restoring them together produces artifacts the server reports as ready\n"
         "   and cannot serve. Use the halves that share a backup_id.")

h = hashlib.sha256()
with open(dump, 'rb') as f:
    for chunk in iter(lambda: f.read(1 << 20), b''):
        h.update(chunk)
if h.hexdigest() != pgm['dump_sha256']:
    fail(f"postgres dump digest mismatch: manifest {pgm['dump_sha256']}, file {h.hexdigest()}")

bad = []
for rel, want in objm['files'].items():
    p = os.path.join(root, rel)
    if not os.path.isfile(p):
        bad.append(f"MISSING {rel}"); continue
    hh = hashlib.sha256()
    with open(p, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            hh.update(chunk)
    if hh.hexdigest() != want:
        bad.append(f"DIGEST MISMATCH {rel}")
present = sum(len(n) for _, _, n in os.walk(root)) - 1  # minus MANIFEST.json
if present != objm['objects']:
    bad.append(f"snapshot holds {present} objects, manifest lists {objm['objects']}")
if bad:
    fail("object half failed verification:\n   " + "\n   ".join(bad[:10]))

print(f"    backup_id {pgm['backup_id']}  created_at {pgm['created_at']}  "
      f"objects {objm['objects']}  tables {len(pgm.get('row_counts', {}))}")
PY
echo "    Verified. Nothing has been changed yet."

# --- refuse a backup taken by a different server image ---------------------
# "Restore onto the image the backup came from, then upgrade" was documented
# guidance that nothing enforced. Restoring a pre-upgrade dump with the
# successor still selected re-runs its migrations on the restored data and
# reports success -- indistinguishable from a rollback that worked.
WANT_IMAGE="$(python3 -c "
import json,sys
try: print(json.load(open('${PG_MANIFEST}')).get('server_image','unknown'))
except Exception: print('unknown')")"
HAVE_IMAGE="$("${DC[@]}" config 2>/dev/null | awk '/^  server:/{f=1} f && /^    image:/{print $2; exit}')"
if [[ -n "$WANT_IMAGE" && "$WANT_IMAGE" != unknown && "$WANT_IMAGE" != "$HAVE_IMAGE" ]]; then
  if [[ "${ALLOW_IMAGE_CHANGE:-0}" == 1 ]]; then
    echo "==> image differs from the backup's (${WANT_IMAGE} -> ${HAVE_IMAGE}); continuing because ALLOW_IMAGE_CHANGE=1."
  else
    die "this backup was taken by a different server image.
     backup was taken under : ${WANT_IMAGE}
     this compose will start: ${HAVE_IMAGE}
   Restoring it here does not roll anything back — the selected image will
   migrate the restored database forward again as soon as it boots.
   Point ${COMPOSE_FILE} at ${WANT_IMAGE} and re-run, or set
   ALLOW_IMAGE_CHANGE=1 if you meant to restore into a different version."
  fi
fi

# A matching REFERENCE is not a matching image. A tag is mutable: the same
# `:1.3.0` can be republished over a different build, and this project has
# already shipped one such image (the git tag code_push_server-v1.3.0 carries
# schema 8; the published :1.3.0 applies 12). Measured 2026-09-06 on the single
# profile: with the tag repointed at a different build, restoring a backup
# taken under the first one was ACCEPTED and migrated the restored database to
# a schema the backup had never seen. So the recorded identity is enforced.
WANT_IMAGE_ID="$(python3 -c "
import json
try: print(json.load(open('${PG_MANIFEST}')).get('server_image_id','unknown'))
except Exception: print('unknown')")"
if [[ -n "$WANT_IMAGE_ID" && "$WANT_IMAGE_ID" != unknown && "${ALLOW_IMAGE_CHANGE:-0}" != 1 ]]; then
  # Every identity the local image answers to: its repo digests and its own id.
  HAVE_IDS="$(docker image inspect "$HAVE_IMAGE" \
    -f '{{range .RepoDigests}}{{println .}}{{end}}{{.Id}}' 2>/dev/null | sed '/^$/d')"
  if [[ -z "$HAVE_IDS" ]]; then
    die "cannot resolve ${HAVE_IMAGE} to an image identity, and this backup records one.
     backup was taken under: ${WANT_IMAGE_ID}
   Pull or build that image so the identity can be checked, or set
   ALLOW_IMAGE_CHANGE=1 if you accept restoring under an unverified image."
  fi
  if ! printf '%s\n' "$HAVE_IDS" | grep -qxF "$WANT_IMAGE_ID"; then
    die "the selected image has the right NAME but is a different build.
     backup was taken under : ${WANT_IMAGE_ID}
     ${HAVE_IMAGE} resolves to : $(printf '%s' "$HAVE_IDS" | tr '\n' ' ')
   A tag is mutable; the same reference can be republished over different
   code. Select the recorded build, or set ALLOW_IMAGE_CHANGE=1."
  fi
fi

# --- refuse to restore under a live server ---------------------------------
cid="$("${DC[@]}" ps -aq server 2>/dev/null | head -1)"
if [[ -n "$cid" ]]; then
  state="$(docker inspect "$cid" -f '{{.State.Running}}' 2>/dev/null || echo unknown)"
  [[ "$state" == "false" ]] || die "the server is still running — stop it first:
     ${DC[*]} stop server"
fi
if [[ -n "${PUBLIC_BASE_URL:-}" ]] && curl -fsS --max-time 2 "${PUBLIC_BASE_URL}/healthz" >/dev/null 2>&1; then
  die "something is still serving at ${PUBLIC_BASE_URL} — stop it before restoring"
fi

echo "!! DESTRUCTIVE restore. Ctrl-C within 5s to abort."
sleep 5

echo "==> Restoring Postgres from ${PG_DUMP}"
# `pg_restore --clean` only drops the objects the DUMP mentions, so anything a
# NEWER schema added is invisible to it and survives. Measured 2026-09-06
# rolling a scale stack back from schema 12 to 7: the `crash_reports` table
# that migration 8 had created was still there afterwards, because the schema-7
# dump had never heard of it. The single profile has no such gap -- it replaces
# the whole volume -- so a rollback was exact on one backend and not the other.
#
# Dropping and recreating the schema first makes the restore mean what it says.
# It is safe here and nowhere else in this script: the dump's sha256 has
# already been verified against its manifest, so there IS a good copy to
# restore from before anything is dropped.
"${DC[@]}" exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 -c \
  "DROP SCHEMA public CASCADE; CREATE SCHEMA public; ALTER SCHEMA public OWNER TO \"${POSTGRES_USER}\";" \
  || die "could not reset the target schema"
"${DC[@]}" exec -T postgres \
  pg_restore --clean --if-exists --no-owner \
  -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
  < "${PG_DUMP}"

echo "==> Restoring MinIO bucket '${S3_BUCKET}' from ${MINIO_SNAPSHOT}"
# MANIFEST.json is backup metadata, not an artifact: excluded so it does not
# land in the bucket as an object the server knows nothing about.
"${DC[@]}" run --rm --no-deps \
  -v "${MINIO_SNAPSHOT}:/restore:ro" \
  --entrypoint /bin/sh \
  createbuckets -c "
    mc alias set local http://minio:9000 '${MINIO_ROOT_USER}' '${MINIO_ROOT_PASSWORD}' &&
    mc mb --ignore-existing local/'${S3_BUCKET}' &&
    mc mirror --overwrite --remove --exclude 'MANIFEST.json' /restore local/'${S3_BUCKET}'
  "

# --- reconcile against the manifest ----------------------------------------
echo "==> Reconciling the restored state against the manifest"
python3 - "${PG_MANIFEST}" <<'PY' > /tmp/cps_expect.txt
import json, sys
m = json.load(open(sys.argv[1]))
for t, n in sorted(m.get('row_counts', {}).items()):
    print(t, n)
PY
fail=0
# Read the whole expectation list BEFORE running anything: `docker compose exec`
# consumes stdin, which silently truncates a `while read` loop to its first
# iteration -- the same bug cost this lane an inventory that reported 1 object
# where there were 10.
tables=(); wants=()
while read -r t n; do tables+=("$t"); wants+=("$n"); done < /tmp/cps_expect.txt
rm -f /tmp/cps_expect.txt
for i in "${!tables[@]}"; do
  t="${tables[$i]}"; n="${wants[$i]}"
  got="$("${DC[@]}" exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -Atc "select count(*) from \"$t\"" 2>/dev/null | tr -d '[:space:]')"
  if [[ "$got" != "$n" ]]; then echo "    MISMATCH $t: expected $n, restored ${got:-<unreadable>}"; fail=1; fi
done
(( fail == 0 )) && echo "    every table matches its manifest row count." \
                || die "the restored database does not match the manifest — do NOT start the server against it"

echo "==> Done. Restart the server:"
echo "    ${DC[*]} up -d server"
