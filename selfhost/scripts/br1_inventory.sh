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

# Column introspection, so one inventory can describe databases at different
# schema versions. UPGRADE-ROLLBACK-1 needs to diff a schema-7 baseline against
# a schema-12 database; projecting columns that do not exist yet would make the
# older side simply fail, and projecting only what happens to exist would make
# the two sides quietly incomparable.
cols_of(){ # table -> comma-separated column names
  if [[ "$PROFILE" == scale ]]; then
    q "select string_agg(column_name,',' order by ordinal_position) from information_schema.columns where table_name='$1'"
  else
    q "select group_concat(name,',') from pragma_table_info('$1')"
  fi
}
# PROJ_FROM pins the projection to the one a previous inventory recorded, so a
# later database is described with EXACTLY the earlier one's columns and any
# difference in the diff is a difference in the data. A column the pinned
# projection needs but the database lacks is a hard error: a column vanishing
# is a finding, not something to quietly drop.
PROJ_FROM=${PROJ_FROM:-}

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
dump_rows(){ # table  select-expression   (raw form, used by dump_cols)
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

# dump_cols <table> <col>=<sql-expression> ...
# Each piece names the single column it reads, so the tool can tell which
# pieces this database actually supports and record the projection it used.
dump_cols(){
  local t=$1; shift
  local have want_list=() expr="" names="" pinned=""
  have=",$(cols_of "$t"),"
  if [[ "$have" == ",," ]]; then
    echo "absent $t" >> "$OUT"; return 0
  fi
  if [[ -n "$PROJ_FROM" ]]; then
    pinned=$(sed -n "s/^proj $t //p" "$PROJ_FROM" | head -1)
    [[ -z "$pinned" ]] && { echo "absent $t" >> "$OUT"; return 0; }
  fi
  local pair name ex
  for pair in "$@"; do
    name=${pair%%=*}; ex=${pair#*=}
    if [[ -n "$pinned" ]]; then
      case ",$pinned," in *",$name,"*) ;; *) continue;; esac
      case "$have" in *",$name,"*) ;; *) fail "pinned projection needs $t.$name but the database has no such column"; return 1;; esac
    else
      case "$have" in *",$name,"*) ;; *) continue;; esac
    fi
    if [[ -z "$expr" ]]; then expr="$ex"; names="$name"
    else expr="$expr||'|'||$ex"; names="$names,$name"; fi
  done
  [[ -z "$expr" ]] && { fail "no usable columns for $t"; return 1; }
  echo "proj $t $names" >> "$OUT"
  dump_rows "$t" "$expr"
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
dump_cols apps                    app_id="app_id" display_name="coalesce(display_name,'')" org_id="coalesce(cast(org_id as text),'')"
dump_cols users                   id="cast(id as text)" email="email" display_name="coalesce(display_name,'')"
dump_cols api_keys                user_id="cast(user_id as text)" key="key"
dump_cols app_collaborators       app_id="app_id" user_id="cast(user_id as text)" role="role"
dump_cols organizations           id="cast(id as text)" name="name"
dump_cols org_members             org_id="cast(org_id as text)" user_id="cast(user_id as text)" role="role"
dump_cols releases                id="cast(id as text)" app_id="app_id" version="version" flutter_revision="coalesce(flutter_revision,'')" flutter_version="coalesce(flutter_version,'')" display_name="coalesce(display_name,'')" lifecycle="lifecycle" notes="coalesce(notes,'')"
dump_cols release_platform_status release_id="cast(release_id as text)" platform="platform" status="status"
dump_cols patches                 id="cast(id as text)" app_id="app_id" release_id="cast(release_id as text)" number="cast(number as text)" status="status" notes="coalesce(notes,'')"
dump_cols channels                id="cast(id as text)" app_id="app_id" name="name"
dump_cols channel_patches         channel_id="cast(channel_id as text)" patch_id="cast(patch_id as text)" status="status" rollout="coalesce(cast(rollout as text),'')" rolled_back="cast(rolled_back as text)"
dump_cols artifacts               id="cast(id as text)" owner_kind="owner_kind" owner_id="cast(owner_id as text)" arch="arch" platform="platform" hash="hash" size="cast(size as text)" storage_key="storage_key" status="status" can_sideload="cast(can_sideload as text)"
dump_cols audit_log               id="cast(id as text)" actor="actor" action="action" target="coalesce(target,'')" result="coalesce(result,'')" http_status="coalesce(cast(http_status as text),'')"
dump_cols settings                key="key" value="value"
dump_cols invitations             token="token" email="email" role="coalesce(role,'')"

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
