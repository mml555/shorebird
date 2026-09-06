#!/usr/bin/env bash
# cspell:words objkey failmig setimg psql projfrom mcsh AFTERFAIL ENVF NEWSCHEMA OLDSCHEMA SCRSCHEMA reupgrade SAMETAG sametag
# UPGRADE-ROLLBACK-1 — certification pass, one backend per run.
#
#   old populated deployment
#     -> certified pre-upgrade backup      (the rollback boundary)
#     -> real forward migration
#     -> old state intact + new mutation works
#     -> a deliberately incompatible successor
#     -> the old binary must not silently serve that schema
#     -> old image + pre-upgrade backup
#     -> exact recovery, mutate, upgrade again
#
# Both backends are certified independently. The repository surface is shared
# but the engines are not, and this lane's questions -- what a failed migration
# leaves behind, what a restore actually removes -- are answered by the engine,
# not by the Dart code.
#
# PROFILE=single needs: DIR PORT KEY OLD_IMAGE NEW_IMAGE SCRATCH_IMAGE FAIL_IMAGE
# PROFILE=scale  needs: the same, plus the rig's compose/env under DIR.
set -uo pipefail
PROFILE=${PROFILE:?single|scale}
DIR=${DIR:?}; PORT=${PORT:?}; KEY=${KEY:?}
OLD_IMAGE=${OLD_IMAGE:?}; NEW_IMAGE=${NEW_IMAGE:?}
SCRATCH_IMAGE=${SCRATCH_IMAGE:?}; FAIL_IMAGE=${FAIL_IMAGE:?}
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
B="http://127.0.0.1:$PORT"
PASS=0; FAIL=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
chk(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (want '$3', got '$2')"; fi; }
step(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
health(){ curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$B/healthz" 2>/dev/null; }
wait_up(){ for _ in $(seq 1 120); do [[ "$(health)" == 200 ]] && return 0; sleep 1; done; return 1; }
cd "$DIR"

case "$PROFILE" in
single)
  DCP=(docker compose)
  set_image(){ sed -i '' "s|^    image: .*|    image: $1|" docker-compose.yaml; }
  stop_server(){ docker compose stop server >/dev/null 2>&1; }
  boot(){ docker compose up -d >/dev/null 2>&1; }
  VOL=$(docker compose ps -aq server | head -1 | xargs -I{} docker inspect {} -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}')
  _snap(){ stop_server; rm -rf /tmp/ur1snap; mkdir -p /tmp/ur1snap
           docker run --rm -v "$VOL":/data -v /tmp/ur1snap:/out busybox sh -c 'cp -a /data/. /out/'; }
  schema(){ _snap; sqlite3 /tmp/ur1snap/code_push.db 'select max(version) from schema_migrations'; boot; wait_up; }
  schema_down(){ rm -rf /tmp/ur1snap; mkdir -p /tmp/ur1snap
                 docker run --rm -v "$VOL":/data -v /tmp/ur1snap:/out busybox sh -c 'cp -a /data/. /out/'
                 sqlite3 /tmp/ur1snap/code_push.db 'select max(version) from schema_migrations'; }
  inventory(){ _snap; boot; wait_up
    PROJ_FROM=${2:-} PROFILE=single SQLITE_DB=/tmp/ur1snap/code_push.db STORE=files \
      FILES_DIR=/tmp/ur1snap/artifacts OUT="$1" bash "$SCRIPTS/br1_inventory.sh" >/dev/null 2>&1; }
  do_backup(){ bash setup.sh --backup 2>&1; }
  latest_backup(){ ls -t "$DIR"/backups/*.tgz | head -1; }
  do_restore(){ bash setup.sh --restore "$1" ${2:-} 2>&1; }
  ;;
scale)
  DCF="$DIR/docker-compose.prod.yaml"; ENVF="$DIR/.env"
  DCP=(docker compose -f "$DCF" --env-file "$ENVF")
  set_image(){ ./setimg.sh "$1" >/dev/null; }
  stop_server(){ "${DCP[@]}" stop server >/dev/null 2>&1; }
  # `up -d`, not `up -d server`: the reset in step 0 tears the whole stack
  # down, and starting the server alone would leave it with no database.
  boot(){ "${DCP[@]}" up -d >/dev/null 2>&1; }
  psql_(){ "${DCP[@]}" exec -T postgres psql -U cps -d code_push -Atc "$1" 2>/dev/null | tr -d '[:space:]'; }
  schema(){ psql_ 'select max(version) from schema_migrations'; }
  schema_down(){ schema; }
  inventory(){ PROJ_FROM=${2:-} MC_SH="$DIR/mcsh" MC_ALIAS=local S3_BUCKET=code-push-artifacts \
      STORE=minio PROFILE=scale COMPOSE="$DCF" OUT="$1" bash "$SCRIPTS/br1_inventory.sh" >/dev/null 2>&1; }
  do_backup(){ COMPOSE_FILE="$DCF" ENV_FILE="$ENVF" BACKUP_DIR="$DIR/bk" bash ops/backup.sh 2>&1; }
  latest_backup(){ ls -t "$DIR"/bk/postgres_*.dump | head -1; }
  # Pair the halves by their shared backup_id, not by "the newest directory".
  # Taking the latest mirror silently crossed a step-1 dump with a step-8b
  # mirror -- which ops/restore.sh correctly refused, and the harness then
  # reported as a rollback failure three steps later.
  mirror_for(){ local want d
    want=$(python3 -c "import json;print(json.load(open('$1.manifest.json'))['backup_id'])" 2>/dev/null) || return 1
    for d in "$DIR"/bk/minio/*; do
      [[ -f "$d/MANIFEST.json" ]] || continue
      [[ "$(python3 -c "import json;print(json.load(open('$d/MANIFEST.json'))['backup_id'])" 2>/dev/null)" == "$want" ]] && { echo "$d"; return 0; }
    done
    return 1
  }
  do_restore(){ local extra=${2:-} mir
    [[ "$extra" == "--allow-image-change" ]] && export ALLOW_IMAGE_CHANGE=1 || export ALLOW_IMAGE_CHANGE=0
    mir=$(mirror_for "$1") || { echo "no object half shares this dump's backup_id"; return 1; }
    COMPOSE_FILE="$DCF" ENV_FILE="$ENVF" bash ops/restore.sh "$1" "$mir" 2>&1; }
  ;;
*) echo "unknown PROFILE" >&2; exit 2;;
esac

api(){ curl -fsS -H "Authorization: Bearer $KEY" "$@"; }
# One mutation: create a patch, upload its bytes, promote it, and fetch it back
# the way a device would. A server that boots is not a server that works.
mutate(){ # label -> 0 on a byte-exact device download
  local label=$1 app rid pid f sz sha url cid dl got ver
  app=$(api "$B/api/v1/apps" | python3 -c 'import json,sys;print(json.load(sys.stdin)["apps"][0]["app_id"])') || return 1
  rid=$(api "$B/api/v1/apps/$app/releases" | python3 -c 'import json,sys;print(json.load(sys.stdin)["releases"][0]["id"])') || return 1
  ver=$(api "$B/api/v1/apps/$app/releases" | python3 -c 'import json,sys;print(json.load(sys.stdin)["releases"][0]["version"])')
  pid=$(api -X POST "$B/api/v1/apps/$app/patches" -H 'Content-Type: application/json' -d "{\"release_id\":$rid}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])') || return 1
  f=$(mktemp); printf 'UR1 %s\n' "$label" > "$f"; head -c 400 /dev/urandom >> "$f"
  sz=$(stat -f%z "$f"); sha=$(shasum -a 256 "$f"|cut -d' ' -f1)
  url=$(api -X POST "$B/api/v1/apps/$app/patches/$pid/artifacts" -F arch=aarch64 -F platform=android -F "hash=$sha" -F "size=$sz" | python3 -c 'import json,sys;print(json.load(sys.stdin)["url"])') || { rm -f "$f"; return 1; }
  api -X POST -F "file=@$f" "$url" >/dev/null || { rm -f "$f"; return 1; }; rm -f "$f"
  cid=$(api "$B/api/v1/apps/$app/channels" | python3 -c "import json,sys;print(next(x['id'] for x in json.load(sys.stdin) if x['name']=='stable'))")
  api -X POST "$B/api/v1/apps/$app/patches/promote" -H 'Content-Type: application/json' -d "{\"patch_id\":$pid,\"channel_id\":$cid,\"rollout\":100}" >/dev/null || return 1
  dl=$(api -X POST "$B/api/v1/patches/check" -H 'Content-Type: application/json' \
        -d "{\"app_id\":\"$app\",\"release_version\":\"$ver\",\"patch_number\":0,\"platform\":\"android\",\"arch\":\"aarch64\",\"channel\":\"stable\"}" \
        | python3 -c 'import json,sys;d=json.load(sys.stdin);print((d.get("patch") or {}).get("download_url",""))')
  [[ -z "$dl" ]] && return 1
  got=$(curl -sS "$dl" | shasum -a 256 | cut -d' ' -f1)
  [[ "$got" == "$sha" ]]
}

step "0. an old, populated deployment"
# Reset first. Started against a deployment the rig had already upgraded, this
# measured a 12 -> 12 "migration" and still reported the later steps as passes.
stop_server
"${DCP[@]}" down -v >/dev/null 2>&1
set_image "$OLD_IMAGE"; boot; wait_up
if [[ "$(health)" != 200 ]]; then no "the old deployment did not come up"; else
  BASE="$B" KEY="$KEY" OUT="$DIR/ur1seed" TAG=ur1 bash "$SCRIPTS/br1_seed.sh" >/dev/null 2>&1 \
    && ok "seeded representative state on the old deployment" \
    || no "seeding the old deployment failed"
fi
chk "the old deployment is serving" "$(health)" "200"
OLDSCHEMA=$(schema)
echo "  image $OLD_IMAGE  schema $OLDSCHEMA"
inventory "$DIR/ur1_base.txt"
[[ -s "$DIR/ur1_base.txt" ]] && ok "baseline inventory banked ($(grep -c '^row ' "$DIR/ur1_base.txt") rows, $(grep -c '^objkey ' "$DIR/ur1_base.txt") objects)" \
  || no "baseline inventory is empty"

step "1. the certified pre-upgrade backup is the rollback boundary"
out=$(do_backup); echo "$out" | grep -qE '✓|Done\.' && ok "backup taken" || { no "backup failed"; echo "$out" | tail -3; }
BK=$(latest_backup); echo "  $BK"
if [[ "$PROFILE" == single ]]; then
  IMG_IN_BK=$(tar xzOf "$BK" ./MANIFEST.json 2>/dev/null | sed -n 's/.*"server_image": "\([^"]*\)".*/\1/p' | head -1)
else
  IMG_IN_BK=$(python3 -c "import json;print(json.load(open('$BK.manifest.json')).get('server_image','unknown'))")
fi
chk "the backup records the image that produced it" "$IMG_IN_BK" "$OLD_IMAGE"

step "2. a real forward migration"
set_image "$NEW_IMAGE"; boot; wait_up
chk "the upgraded deployment is serving" "$(health)" "200"
NEWSCHEMA=$(schema)
[[ "$NEWSCHEMA" -gt "$OLDSCHEMA" ]] && ok "schema advanced $OLDSCHEMA -> $NEWSCHEMA (a real migration ran)" \
  || no "no migration ran ($OLDSCHEMA -> $NEWSCHEMA): this proves nothing about upgrades"

step "3. every pre-upgrade row and object survived, and new work succeeds"
inventory "$DIR/ur1_postup.txt" "$DIR/ur1_base.txt"
lost=0
while IFS= read -r l; do grep -qxF "$l" "$DIR/ur1_postup.txt" || lost=$((lost+1)); done < <(grep -E '^(row|objkey) ' "$DIR/ur1_base.txt")
chk "no baseline row or object was lost by the migration" "$lost" "0"
mutate post-upgrade && ok "a new patch is created, promoted and downloaded byte-exact" || no "post-upgrade mutation failed"

step "4. a deliberately incompatible successor"
set_image "$SCRATCH_IMAGE"; boot; wait_up
chk "the successor is serving" "$(health)" "200"
SCRSCHEMA=$(schema)
[[ "$SCRSCHEMA" -gt "$NEWSCHEMA" ]] && ok "it migrated the schema further ($NEWSCHEMA -> $SCRSCHEMA)" || no "the fixture did not change the schema"
# Without this the whole negative below is vacuous: a successor that cannot
# serve its own device path would make ANY binary look broken.
mutate successor && ok "and it serves its own device path" || no "the successor is itself broken — the negative below would prove nothing"

step "5. the previous binary must not silently serve that schema"
stop_server; set_image "$NEW_IMAGE"; boot; sleep 10
h=$(health)
chk "it does not serve" "$h" "000"
ec=$(docker inspect "$("${DCP[@]}" ps -aq server | head -1)" -f '{{.State.ExitCode}}' 2>/dev/null || echo '?')
chk "it exits with the schema-mismatch code" "$ec" "65"
fatal_line=$("${DCP[@]}" logs server 2>&1 | grep -o "database schema is at version [0-9]* but this server implements only up to [0-9]*" | tail -1)
if [[ "$fatal_line" == "database schema is at version $SCRSCHEMA but this server implements only up to $NEWSCHEMA" ]]; then
  ok "and says so, naming both versions and the remedy"
else
  no "no FATAL naming schema $SCRSCHEMA vs $NEWSCHEMA; the log said: ${fatal_line:-<nothing matching>}"
fi

step "6. the supported rollback: old image + the pre-upgrade backup"
stop_server
# Wrong image first: a rollback that silently re-upgrades is worse than one
# that fails, because nothing distinguishes it from success.
set_image "$NEW_IMAGE"
out=$(do_restore "$BK"); rc=$?
if (( rc == 0 )); then no "restoring the pre-upgrade backup under the NEW image was accepted"
elif printf '%s' "$out" | grep -qE "different server image|a different build"; then
  # Either refusal is correct. SERVER-IMAGE-PROVENANCE-1 made the DIGEST check
  # run first, so a backup that records one now refuses on the build rather
  # than on the name -- the stronger of the two, and the one that catches a
  # republished tag.
  ok "restoring it under the wrong image is refused, naming both"
else no "refused, but not for the image: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-100)"; fi
set_image "$OLD_IMAGE"
out=$(do_restore "$BK"); rc=$?
chk "restoring under the right image succeeds" "$rc" "0"
boot; wait_up
chk "the rolled-back deployment is serving" "$(health)" "200"
chk "its schema is the pre-upgrade one" "$(schema)" "$OLDSCHEMA"
inventory "$DIR/ur1_rolled.txt"
if diff -q "$DIR/ur1_base.txt" "$DIR/ur1_rolled.txt" >/dev/null; then ok "and its state is IDENTICAL to the pre-upgrade baseline"
else no "the rolled-back state differs from the baseline:"; diff "$DIR/ur1_base.txt" "$DIR/ur1_rolled.txt" | head -6; fi

step "7. the rolled-back deployment accepts new work"
mutate post-rollback && ok "new patch created, promoted, downloaded byte-exact after rollback" || no "post-rollback mutation failed"

step "8. upgrading again from the restored state"
set_image "$NEW_IMAGE"; boot; wait_up
chk "the re-upgrade serves" "$(health)" "200"
chk "and reaches the successor schema again" "$(schema)" "$NEWSCHEMA"
mutate post-reupgrade && ok "and still accepts new work" || no "mutation after the second upgrade failed"

step "8b. a tag is not an identity"
# The reference matching is not the check that matters. A tag is mutable, and
# this project has already published one image whose tag misdescribes its code
# (git tag code_push_server-v1.3.0 carries schema 8; the :1.3.0 image applies
# 12). So the decisive control is not another differently-NAMED image -- it is
# the SAME name over two different builds.
SAMETAG=ur1-sametag:under-test
docker tag "$NEW_IMAGE" "$SAMETAG" >/dev/null 2>&1
DIGEST_A=$(docker image inspect "$SAMETAG" -f '{{.Id}}')
stop_server; set_image "$SAMETAG"; boot; wait_up
if [[ "$(health)" == 200 ]]; then ok "a deployment running $SAMETAG (build A)"; else no "the same-tag deployment did not come up"; fi
out=$(do_backup); BK_A=$(latest_backup)
[[ -n "$BK_A" ]] && ok "backup taken under build A" || no "backup under build A failed"
STATE_BEFORE=$(schema); stop_server
# Repoint the SAME reference at a different build. Nothing about the name
# changes; only the bytes behind it do.
docker tag "$SCRATCH_IMAGE" "$SAMETAG" >/dev/null 2>&1
DIGEST_B=$(docker image inspect "$SAMETAG" -f '{{.Id}}')
if [[ "$DIGEST_A" != "$DIGEST_B" ]]; then ok "the reference now resolves to a different build"
else no "both tags resolve to the same image — this control cannot fail"; fi
stop_server
out=$(do_restore "$BK_A"); rc=$?
if (( rc == 0 )); then no "restoring under the same tag but a DIFFERENT build was accepted"
elif printf '%s' "$out" | grep -q "different build"; then
  ok "restoring under a republished tag is refused"
  printf '%s' "$out" | grep -q "${DIGEST_A#sha256:}" && ok "  and the refusal names the recorded build" || no "  but it does not name the recorded build"
  printf '%s' "$out" | grep -q "${DIGEST_B#sha256:}" && ok "  and the one actually selected" || no "  but it does not name the selected build"
else no "refused, but not on the build: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-110)"; fi
# Read the state WITHOUT booting: the reference still points at the other
# build, and starting it would migrate the database -- which the first version
# of this check did, then blamed the refusal for the change it had caused.
chk "nothing was mutated by the refusal" "$(schema_down)" "$STATE_BEFORE"
# The control that proves this did not simply break restore.
docker tag "$NEW_IMAGE" "$SAMETAG" >/dev/null 2>&1
out=$(do_restore "$BK_A"); rc=$?
chk "and with the recorded build selected again it succeeds" "$rc" "0"
boot; wait_up
stop_server; set_image "$NEW_IMAGE"; boot; wait_up
docker rmi "$SAMETAG" >/dev/null 2>&1

step "9. a migration that starts and then fails"
# Reset to the pre-upgrade schema so the failure happens with earlier
# migrations still pending -- the realistic failed upgrade.
stop_server; set_image "$OLD_IMAGE"
rst=$(do_restore "$BK"); rc=$?
(( rc == 0 )) || no "the reset restore failed: $(printf '%s' "$rst" | tr '\n' ' ' | cut -c1-120)"
boot; wait_up
chk "reset to the pre-upgrade schema" "$(schema)" "$OLDSCHEMA"
stop_server; set_image "$FAIL_IMAGE"; boot; sleep 12
chk "a failed migration leaves nothing serving" "$(health)" "000"
stop_server
AFTERFAIL=$(schema_down)
probe_present(){ if [[ "$PROFILE" == single ]]; then
    sqlite3 /tmp/ur1snap/code_push.db "select count(*) from pragma_table_info('channel_patches') where name='ur1_failed_migration_probe'"
  else psql_ "select count(*) from information_schema.columns where table_name='channel_patches' and column_name='ur1_failed_migration_probe'"; fi; }
chk "the failing migration left no partial DDL behind" "$(probe_present)" "0"
if [[ "$AFTERFAIL" -gt "$OLDSCHEMA" ]]; then
  ok "but the database is NOT where it started ($OLDSCHEMA -> $AFTERFAIL): earlier migrations committed"
else no "expected the earlier migrations to have committed; got $AFTERFAIL"; fi

step "10. recovering from the failed upgrade"
set_image "$OLD_IMAGE"
rst=$(do_restore "$BK"); rc=$?
(( rc == 0 )) || no "the recovery restore failed: $(printf '%s' "$rst" | tr '\n' ' ' | cut -c1-120)"
boot; wait_up
chk "old image + pre-upgrade backup restores service" "$(health)" "200"
chk "at the pre-upgrade schema" "$(schema)" "$OLDSCHEMA"
inventory "$DIR/ur1_recovered.txt"
diff -q "$DIR/ur1_base.txt" "$DIR/ur1_recovered.txt" >/dev/null \
  && ok "and the state is IDENTICAL to the pre-upgrade baseline" \
  || { no "recovery differs from the baseline:"; diff "$DIR/ur1_base.txt" "$DIR/ur1_recovered.txt" | head -6; }
mutate post-recovery && ok "and it accepts new work" || no "mutation after recovery failed"

step "RESULT"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ))
