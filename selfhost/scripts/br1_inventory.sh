#!/usr/bin/env bash
# cspell:words minio Atc tablename schemaname objkey OBJF PGDB PGUSER nobj
# BACKUP-RESTORE-1: bank a machine-readable inventory of a control plane's
# durable state, so "restored correctly" is a diff and not an impression.
#
# Two halves, because a backup can lose either independently:
#   DB      -- every row of every state-bearing table, canonically projected
#   OBJECTS -- every object key in the artifact store, with its sha256
#
# Secrets are FINGERPRINTED, never copied: an api_keys row contributes
# sha256(key) so a rotation is visible as a change while the inventory itself
# stays safe to keep next to a report.
#
# Two defects the first draft of this script had, both of which made it report
# a HEALTHY inventory over missing data. Neither is theoretical; both happened:
#   1. `select ... from apps` used guessed column names (`id`, not `app_id`).
#      psql errored, stderr was sent to /dev/null, and the table contributed
#      zero rows -- indistinguishable from an empty table. Every projection is
#      now reconciled against the table's own COUNT and a mismatch is fatal.
#   2. The object loop ran `docker compose exec` inside `while read`, and exec
#      consumed the loop's stdin, so 10 objects inventoried as 1. Object keys
#      are now read into an array before any subprocess runs.
set -uo pipefail
PROFILE=${PROFILE:?set PROFILE (scale|single)}
OUT=${OUT:?set OUT}
mkdir -p "$(dirname "$OUT")"
FAIL=0
fail(){ printf 'ERROR %s\n' "$1" >> "$OUT"; echo "  ERROR $1" >&2; FAIL=1; }

case "$PROFILE" in
scale)
  COMPOSE=${COMPOSE:?set COMPOSE}
  q(){ docker compose -f "$COMPOSE" exec -T postgres psql -U "${PGUSER:-cps}" -d "${PGDB:-code_push}" -Atc "$1"; }
  TABLES=$(q "select tablename from pg_tables where schemaname='public' order by 1") || { echo "cannot reach postgres" >&2; exit 3; }
  ;;
single)
  SQLITE_DB=${SQLITE_DB:?set SQLITE_DB}
  [[ -f "$SQLITE_DB" ]] || { echo "no sqlite db at $SQLITE_DB" >&2; exit 3; }
  q(){ sqlite3 "$SQLITE_DB" "$1"; }
  TABLES=$(q "select name from sqlite_master where type='table' and name not like 'sqlite_%' order by 1") || exit 3
  ;;
*) echo "unknown PROFILE $PROFILE" >&2; exit 2;;
esac

: > "$OUT"
printf '# br1-inventory v1\nprofile=%s\n' "$PROFILE" >> "$OUT"

# Volatile-by-design tables are counted but never diffed row-by-row: they are
# caches (rate_limits) or short-lived auth handshakes whose contents may
# legitimately differ across a backup boundary.
VOLATILE=" rate_limits auth_codes idp_states refresh_tokens "

declare_count(){ q "select count(*) from $1" 2>/dev/null | tr -d '[:space:]'; }
for t in $TABLES; do
  [[ "$t" == schema_migrations ]] && continue
  n=$(declare_count "$t")
  if [[ -z "$n" ]]; then fail "count $t unreadable"; else echo "count $t $n" >> "$OUT"; fi
done

# Row-level content. Each row becomes `row <table> <sha256>`, sorted, so a
# diff names the table and how many rows differ without putting the payload
# in the report.
dump_rows(){ # table  select-expression
  local t=$1 expr=$2 out err rc want got
  case "$VOLATILE" in *" $t "*) return 0;; esac
  out=$(q "select $expr from $t" 2>/tmp/br1q.$$); rc=$?
  err=$(cat /tmp/br1q.$$); rm -f /tmp/br1q.$$
  if (( rc != 0 )) || [[ -n "$err" ]]; then
    fail "projection $t failed: ${err:-exit $rc}"; return 1
  fi
  # `printf '%s'` drops the final line for `read`, which silently erased every
  # single-row table (apps, api_keys, app_collaborators) from the first run of
  # this inventory. The reconciliation below counts what actually LANDED in
  # $OUT rather than what the query returned, so a loss in the emitting loop
  # cannot pass either.
  printf '%s\n' "$out" | while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    printf 'row %s %s\n' "$t" "$(printf '%s' "$line" | shasum -a 256 | cut -d' ' -f1)"
  done | sort >> "$OUT"
  want=$(declare_count "$t")
  got=$(grep -c "^row $t " "$OUT")
  if [[ "$want" != "$got" ]]; then
    fail "table $t holds $want rows but $got reached the inventory"; return 1
  fi
}

# Explicit projections against the REAL columns (information_schema, not
# memory). Timestamps a restore may legitimately rewrite are excluded; the
# state that must survive is not.
# `cast(x as text)` rather than Postgres' `x::text`, so one projection set
# serves both profiles.
#
# api_keys.key holds the PLAINTEXT credential (repository.dart:742 inserts the
# key itself, not a digest). It is emitted here only so the shell can hash the
# whole row line -- the inventory file receives sha256(row) and never the key.
dump_rows apps                    "app_id||'|'||coalesce(display_name,'')||'|'||coalesce(cast(org_id as text),'')"
dump_rows users                   "cast(id as text)||'|'||email||'|'||coalesce(display_name,'')"
dump_rows api_keys                "cast(user_id as text)||'|'||key"
dump_rows app_collaborators       "app_id||'|'||cast(user_id as text)||'|'||role"
dump_rows organizations           "cast(id as text)||'|'||name"
dump_rows org_members             "cast(org_id as text)||'|'||cast(user_id as text)||'|'||role"
dump_rows releases                "cast(id as text)||'|'||app_id||'|'||version||'|'||coalesce(flutter_revision,'')||'|'||coalesce(flutter_version,'')||'|'||coalesce(display_name,'')||'|'||lifecycle||'|'||coalesce(notes,'')"
dump_rows release_platform_status "cast(release_id as text)||'|'||platform||'|'||status"
dump_rows patches                 "cast(id as text)||'|'||app_id||'|'||cast(release_id as text)||'|'||cast(number as text)||'|'||status||'|'||coalesce(notes,'')"
dump_rows channels                "cast(id as text)||'|'||app_id||'|'||name"
dump_rows channel_patches         "cast(channel_id as text)||'|'||cast(patch_id as text)||'|'||status||'|'||coalesce(cast(rollout as text),'')||'|'||cast(rolled_back as text)"
dump_rows artifacts               "cast(id as text)||'|'||owner_kind||'|'||cast(owner_id as text)||'|'||arch||'|'||platform||'|'||hash||'|'||cast(size as text)||'|'||storage_key||'|'||status||'|'||cast(can_sideload as text)"
dump_rows audit_log               "cast(id as text)||'|'||actor||'|'||action||'|'||coalesce(target,'')||'|'||coalesce(result,'')||'|'||coalesce(cast(http_status as text),'')"
dump_rows settings                "key||'|'||value"
dump_rows invitations             "token||'|'||email||'|'||coalesce(role,'')"

# --- objects: the half a DB-only backup silently loses
case "${STORE:-}" in
minio)
  # `mc` is not on the host; it ships inside the MinIO image. MC_SH must be an
  # executable taking one argument: a shell command to run with `mc` on PATH
  # and the alias configured.
  MC_SH=${MC_SH:?set MC_SH}
  listing=$("$MC_SH" "mc ls --recursive --json ${MC_ALIAS:?}/${S3_BUCKET:?}" 2>/dev/null \
    | python3 -c '
import json,sys
for l in sys.stdin:
    l=l.strip()
    if not l: continue
    try: d=json.loads(l)
    except Exception: continue
    if d.get("key"): print(d["key"], d.get("size",""))
' | sort)
  if [[ -z "$listing" ]]; then
    echo "objkey NONE" >> "$OUT"
  else
    # Read fully BEFORE running any subprocess: `docker compose exec` eats
    # stdin, which truncated this loop to its first key.
    keys=(); sizes=()
    while IFS=' ' read -r k s; do keys+=("$k"); sizes+=("$s"); done <<< "$listing"
    for i in "${!keys[@]}"; do
      h=$("$MC_SH" "mc cat ${MC_ALIAS}/${S3_BUCKET}/${keys[$i]}" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
      printf 'objkey %s %s %s\n' "${keys[$i]}" "${sizes[$i]}" "$h" >> "$OUT"
    done
  fi
  ;;
files)
  FILES_DIR=${FILES_DIR:?set FILES_DIR}
  if [[ -d "$FILES_DIR" ]]; then
    ( cd "$FILES_DIR" && find . -type f | sort | while IFS= read -r f; do
        printf 'objkey %s %s %s\n' "${f#./}" "$(stat -f%z "$f")" "$(shasum -a 256 "$f" | cut -d' ' -f1)"
      done ) >> "$OUT"
  else
    fail "object dir $FILES_DIR is missing"
  fi
  ;;
"") echo "# no STORE requested" >> "$OUT";;
*) echo "unknown STORE ${STORE}" >&2; exit 2;;
esac

nobj=$(grep -c '^objkey ' "$OUT" || true)
echo "wrote $OUT ($(wc -l < "$OUT" | tr -d ' ') lines, $nobj objects)"
(( FAIL == 0 )) || { echo "INVENTORY INCOMPLETE -- see ERROR lines" >&2; exit 1; }
