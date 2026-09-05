#!/usr/bin/env bash
# cspell:words objkey minio dapi dobj nodb nomanifest missingobj noserver RUNTAG
# BACKUP-RESTORE-1 — certification pass for the SCALE profile
# (Postgres + MinIO, ops/backup.sh + ops/restore.sh).
#
# Needs two independently-volumed stacks: SRC is backed up, DST is restored
# into. Restoring into the stack you backed up cannot distinguish "restore
# worked" from "nothing happened".
#
# Env: SRC_COMPOSE SRC_ENV SRC_PORT SRC_KEY  DST_COMPOSE DST_ENV DST_PORT
set -uo pipefail
: "${SRC_COMPOSE:?}" "${SRC_ENV:?}" "${SRC_PORT:?}" "${SRC_KEY:?}"
: "${DST_COMPOSE:?}" "${DST_ENV:?}" "${DST_PORT:?}"
OPS=${OPS:-/Users/mendell/shorebird/packages/code_push_server/ops}
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORK=${WORK:-$(mktemp -d /tmp/br1cs.XXXXXX)}
SRC="http://127.0.0.1:$SRC_PORT"; DST="http://127.0.0.1:$DST_PORT"
PASS=0; FAIL=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
chk(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (want '$3', got '$2')"; fi; }
step(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
SDC=(docker compose -f "$SRC_COMPOSE" --env-file "$SRC_ENV")
DDC=(docker compose -f "$DST_COMPOSE" --env-file "$DST_ENV")
bk(){ COMPOSE_FILE="$SRC_COMPOSE" ENV_FILE="$SRC_ENV" BACKUP_DIR="$1" bash "$OPS/backup.sh" 2>&1; }
rs(){ COMPOSE_FILE="$DST_COMPOSE" ENV_FILE="$DST_ENV" bash "$OPS/restore.sh" "$1" "$2" 2>&1; }
dsql(){ "${DDC[@]}" exec -T postgres psql -U cps -d code_push -Atc "$1" 2>/dev/null | tr -d '\r'; }
dobj(){ "${DDC[@]}" exec -T minio sh -c 'mc alias set local http://127.0.0.1:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD >/dev/null 2>&1; mc ls --recursive --json local/code-push-artifacts' \
        | python3 -c 'import json,sys
for l in sys.stdin:
    try: d=json.loads(l)
    except Exception: continue
    if d.get("key"): print(d["key"])' | sort; }

step "0. subject"
echo "  src $SRC   dst $DST   work $WORK"
# Abort rather than continue: a run that starts against a stack which is not
# serving produces a long list of meaningless passes around a few cascading
# failures, which reads like a partial result and is not one.
if [[ "$(curl -s -o /dev/null -w '%{http_code}' "$SRC/healthz")" != "200" ]]; then
  echo "  ABORT: the source stack is not serving at $SRC" >&2; exit 2
fi
ok "the source stack is serving"
if [[ "$(curl -s -o /dev/null -w '%{http_code}' "$DST/healthz")" != "200" ]]; then
  echo "  ABORT: the destination stack is not serving at $DST" >&2; exit 2
fi
ok "the destination stack is serving"

step "1. backup quiesces the source, and that is measured"
rm -f "$WORK/stop" "$WORK/probe"
( while [[ ! -f "$WORK/stop" ]]; do
    printf '%s\n' "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$SRC/healthz" 2>/dev/null)" >> "$WORK/probe"
  done ) & PP=$!
sleep 2; bk "$WORK/p1" > "$WORK/bk1.log" 2>&1; BR=$?
sleep 1; touch "$WORK/stop"; wait $PP 2>/dev/null
chk "backup exits 0" "$BR" "0"
D=$(grep -c '^000' "$WORK/probe"); U=$(grep -c '^200' "$WORK/probe")
[[ $D -gt 0 ]] && ok "the source was unreachable for $D probes during the snapshot" || no "the source stayed up — the snapshot was taken live"
[[ $U -gt 0 ]] && ok "and reachable for $U probes outside it" || no "the probe never saw a healthy server"
chk "the source is serving again when backup returns" "$(curl -s -o /dev/null -w '%{http_code}' "$SRC/healthz")" "200"

step "2. the two halves are stamped as one backup"
P1D=$(ls "$WORK"/p1/postgres_*.dump); P1M=$(ls -d "$WORK"/p1/minio/*)
# Tolerate absent manifests rather than dying on `set -u`: run against a
# version that writes none, this whole section must report FAIL, not abort and
# hide the twenty checks after it.
IDS=$(python3 -c "
import json
a=json.load(open('$P1D.manifest.json')); b=json.load(open('$P1M/MANIFEST.json'))
print(a['backup_id'], b['backup_id'], a['half'], b['half'], len(a['row_counts']), b['objects'])" 2>/dev/null)
if [[ -z "$IDS" ]]; then
  no "the postgres half has no readable manifest"
  no "the object half has no readable manifest"
  no "there is no backup_id linking the two halves"
else
  read -r I1 I2 H1 H2 NT NO <<< "$IDS"
  chk "both halves carry the same backup_id" "$I1" "$I2"
  chk "the postgres half says so" "$H1" "postgres"
  chk "the object half says so" "$H2" "objects"
  [[ "$NT" -gt 0 && "$NO" -gt 0 ]] && ok "the manifests carry $NT table counts and $NO object digests" || no "the manifests are empty"
fi

step "3. a completed write lands between two backups (so a cross is detectable)"
api(){ curl -fsS -H "Authorization: Bearer $SRC_KEY" "$@"; }
APP=$(curl -s -H "Authorization: Bearer $SRC_KEY" "$SRC/api/v1/apps" | python3 -c 'import json,sys;print(json.load(sys.stdin)["apps"][0]["app_id"])')
RID=$(api -X POST "$SRC/api/v1/apps/$APP/releases" -H 'Content-Type: application/json' \
      -d "{\"version\":\"99.$(date +%s).0+x\",\"display_name\":\"cert-between\"}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["release"]["id"])')
f=$(mktemp); printf 'CERT-BETWEEN-PAIRS\n' > "$f"; head -c 256 /dev/urandom >> "$f"
sz=$(stat -f%z "$f"); sha=$(shasum -a 256 "$f"|cut -d' ' -f1)
U=$(api -X POST "$SRC/api/v1/apps/$APP/releases/$RID/artifacts" -F arch=aarch64 -F platform=android -F "hash=$sha" -F "size=$sz" | python3 -c 'import json,sys;print(json.load(sys.stdin)["url"])')
api -X POST -F "file=@$f" "$U" >/dev/null; rm -f "$f"
bk "$WORK/p2" > "$WORK/bk2.log" 2>&1
P2D=$(ls "$WORK"/p2/postgres_*.dump); P2M=$(ls -d "$WORK"/p2/minio/*)
chk "release $RID is verified in the source" \
  "$("${SDC[@]}" exec -T postgres psql -U cps -d code_push -Atc "select status from artifacts where owner_kind='release' and owner_id=$RID" | tr -d '\r')" "verified"

step "4. the destination refuses everything that is not one verified backup"
"${DDC[@]}" up -d >/dev/null 2>&1
for _ in $(seq 1 90); do curl -fsS "$DST/healthz" >/dev/null 2>&1 && break; sleep 1; done
o=$(rs "$P2D" "$P2M"); printf '%s' "$o" | grep -q "still running" \
  && ok "refuses while the destination server is running" || no "did not refuse a live destination"
"${DDC[@]}" stop server >/dev/null 2>&1
BEFORE_ROWS=$(dsql "select count(*) from artifacts"); BEFORE_OBJ=$(dobj | grep -c .)
o=$(rs "$P2D" "$P1M"); printf '%s' "$o" | grep -q "CROSSED PAIR" \
  && ok "refuses a crossed pair, naming both backup_ids" || no "accepted a crossed pair"
rm -rf "$WORK/t1"; cp -a "$WORK/p2" "$WORK/t1"; printf 'X' >> "$WORK"/t1/postgres_*.dump
o=$(rs "$(ls "$WORK"/t1/postgres_*.dump)" "$(ls -d "$WORK"/t1/minio/*)")
printf '%s' "$o" | grep -q "dump digest mismatch" && ok "refuses a tampered postgres dump" || no "accepted a tampered dump"
rm -rf "$WORK/t2"; cp -a "$WORK/p2" "$WORK/t2"; rm -f "$(find "$WORK"/t2/minio -type f -path '*release*' | head -1)"
o=$(rs "$(ls "$WORK"/t2/postgres_*.dump)" "$(ls -d "$WORK"/t2/minio/*)")
printf '%s' "$o" | grep -q "MISSING" && ok "refuses an object snapshot missing a file" || no "accepted a short object snapshot"
rm -rf "$WORK/t3"; cp -a "$WORK/p2" "$WORK/t3"; echo T > "$(find "$WORK"/t3/minio -type f -path '*release*' | head -1)"
o=$(rs "$(ls "$WORK"/t3/postgres_*.dump)" "$(ls -d "$WORK"/t3/minio/*)")
printf '%s' "$o" | grep -q "DIGEST MISMATCH" && ok "refuses an altered object" || no "accepted an altered object"
rm -rf "$WORK/t4"; cp -a "$WORK/p2" "$WORK/t4"; rm -f "$WORK"/t4/*.manifest.json
o=$(rs "$(ls "$WORK"/t4/postgres_*.dump)" "$(ls -d "$WORK"/t4/minio/*)")
printf '%s' "$o" | grep -q "no manifest" && ok "refuses a half with no manifest" || no "accepted an unmanifested half"
chk "the destination database is unchanged by all six refusals" "$(dsql 'select count(*) from artifacts')" "$BEFORE_ROWS"
chk "the destination bucket is unchanged too" "$(dobj | grep -c .)" "$BEFORE_OBJ"

step "5. the matched pair restores into the dirty destination, exactly"
o=$(rs "$P2D" "$P2M"); echo "$o" | grep -q "every table matches its manifest row count" \
  && ok "restore reconciles every table against the manifest" || { no "reconciliation did not pass"; echo "$o" | tail -4 | sed 's/^/      /'; }
"${DDC[@]}" up -d server >/dev/null 2>&1
for _ in $(seq 1 90); do curl -fsS "$DST/healthz" >/dev/null 2>&1 && break; sleep 1; done
chk "the destination is serving" "$(curl -s -o /dev/null -w '%{http_code}' "$DST/healthz")" "200"
dsql "select storage_key||' '||status from artifacts order by 1" > "$WORK/d_db.txt"
dobj > "$WORK/d_obj.txt"
T=$(bash "$SCRIPTS/br1_tear_check.sh" "$WORK/d_db.txt" "$WORK/d_obj.txt" | sed -n 's/.*TEARS=\([0-9]*\).*/\1/p')
chk "the restored stack holds no state the live system could not have been in" "$T" "0"
chk "no MANIFEST.json leaked into the bucket as an artifact" "$(grep -c MANIFEST "$WORK/d_obj.txt")" "0"
DU=$(curl -sS -H "Authorization: Bearer $SRC_KEY" "$DST/api/v1/apps/$APP/releases/$RID/artifacts" | python3 -c 'import json,sys;a=json.load(sys.stdin)["artifacts"];print(a[0]["url"] if a else "")')
if [[ -z "$DU" ]]; then no "the between-pairs release is missing from the restore"; else
  chk "the between-pairs release downloads from the restored stack" "$(curl -sS -o /dev/null -w '%{http_code}' "$DU")" "200"; fi

step "6. the restored stack accepts new work"
dapi(){ curl -fsS -H "Authorization: Bearer $SRC_KEY" "$@"; }
PID=$(dapi -X POST "$DST/api/v1/apps/$APP/patches" -H 'Content-Type: application/json' -d "{\"release_id\":$RID}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
f=$(mktemp); printf 'CERT-SCALE-POST-RESTORE\n' > "$f"; head -c 512 /dev/urandom >> "$f"
sz=$(stat -f%z "$f"); sha=$(shasum -a 256 "$f"|cut -d' ' -f1)
U=$(dapi -X POST "$DST/api/v1/apps/$APP/patches/$PID/artifacts" -F arch=aarch64 -F platform=android -F "hash=$sha" -F "size=$sz" | python3 -c 'import json,sys;print(json.load(sys.stdin)["url"])')
dapi -X POST -F "file=@$f" "$U" >/dev/null; rm -f "$f"
CID=$(dapi "$DST/api/v1/apps/$APP/channels" | python3 -c "import json,sys;print(next(x['id'] for x in json.load(sys.stdin) if x['name']=='stable'))")
dapi -X POST "$DST/api/v1/apps/$APP/patches/promote" -H 'Content-Type: application/json' -d "{\"patch_id\":$PID,\"channel_id\":$CID,\"rollout\":100}" >/dev/null \
  && ok "a new patch is created, uploaded and promoted on the restored stack" || no "post-restore mutation failed"
VER=$(dapi "$DST/api/v1/apps/$APP/releases" | python3 -c "import json,sys;print(next(r['version'] for r in json.load(sys.stdin)['releases'] if r['id']==$RID))")
DLU=$(dapi -X POST "$DST/api/v1/patches/check" -H 'Content-Type: application/json' \
      -d "{\"app_id\":\"$APP\",\"release_version\":\"$VER\",\"patch_number\":0,\"platform\":\"android\",\"arch\":\"aarch64\",\"channel\":\"stable\"}" \
      | python3 -c 'import json,sys;d=json.load(sys.stdin);print((d.get("patch") or {}).get("download_url",""))')
if [[ -z "$DLU" ]]; then no "the device check offered no patch on the restored stack"; else
  chk "a device downloads it byte-for-byte" "$(curl -sS "$DLU" | shasum -a 256 | cut -d' ' -f1)" "$sha"; fi

step "7. backup refuses when it cannot quiesce"
NS="$WORK/noserver.yaml"
awk '/^  server:/{skip=1;next} /^  [a-z_]+:/{skip=0} !skip' "$SRC_COMPOSE" > "$NS"
o=$(COMPOSE_FILE="$NS" ENV_FILE="$SRC_ENV" BACKUP_DIR="$WORK/nb1" bash "$OPS/backup.sh" 2>&1)
printf '%s' "$o" | grep -q "refusing to snapshot" && ok "refuses when the server service cannot be stopped" || no "proceeded without stopping the server"
[[ -z "$(ls "$WORK"/nb1/*.dump 2>/dev/null)" ]] && ok "and wrote no dump" || no "it wrote a dump anyway"
sed "s|PUBLIC_BASE_URL=.*|PUBLIC_BASE_URL=$SRC|" "$DST_ENV" > "$WORK/guard.env"
o=$(COMPOSE_FILE="$DST_COMPOSE" ENV_FILE="$WORK/guard.env" BACKUP_DIR="$WORK/nb2" bash "$OPS/backup.sh" 2>&1)
printf '%s' "$o" | grep -q "still serving" && ok "refuses while anything still answers at PUBLIC_BASE_URL" || no "ignored a live endpoint"
[[ -z "$(ls "$WORK"/nb2/*.dump 2>/dev/null)" ]] && ok "and wrote no dump" || no "it wrote a dump anyway"

step "RESULT"
printf '  %d passed, %d failed\n  work: %s\n' "$PASS" "$FAIL" "$WORK"
exit $(( FAIL > 0 ))
