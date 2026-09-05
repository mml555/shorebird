#!/usr/bin/env bash
# cspell:words objkey unservable cpslib BKRC STOPFILE RUNTAG nodb nomanifest missingobj noserver wstop
# BACKUP-RESTORE-1 — certification pass for the DEFAULT (single) profile.
#
# Re-runnable end to end against a throwaway deployment. Every check states
# what would falsify it; the negative controls run against the FINAL form of
# the scripts, and each must refuse for its OWN reason (five identical
# refusals would mean the verifier is not discriminating -- which is exactly
# what a bug in this harness produced once).
#
# Requires: DIR (the deployment dir with setup.sh + ops/lib), PORT, KEY.
set -uo pipefail
DIR=${DIR:?}; PORT=${PORT:?}; KEY=${KEY:?}
SCRIPTS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE="http://127.0.0.1:$PORT"
PASS=0; FAIL=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
chk(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (want '$3', got '$2')"; fi; }
step(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
cd "$DIR"

VOL="$(docker compose ps -aq server | head -1 | xargs -I{} docker inspect {} -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}')"
snap(){ docker compose stop server >/dev/null 2>&1; rm -rf "$1"; mkdir -p "$1"
        docker run --rm -v "$VOL":/data -v "$1":/out busybox sh -c 'cp -a /data/. /out/'
        docker compose start server >/dev/null 2>&1
        for _ in $(seq 1 60); do curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break; sleep 1; done; }
inv(){ PROFILE=single SQLITE_DB="$1/code_push.db" STORE=files FILES_DIR="$1/artifacts" OUT="$2" \
         bash "$SCRIPTS/br1_inventory.sh" >/dev/null 2>&1; }
fp(){ docker run --rm -v "$VOL":/data busybox sh -c 'echo "$(find /data -type f | wc -l | tr -d " ")-$(sha256sum /data/code_push.db 2>/dev/null | cut -c1-16)"'; }

step "0. subject"
echo "  deployment $DIR  volume $VOL  port $PORT"
chk "the deployment is serving" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/healthz")" "200"

step "1. --backup quiesces, and that is measured rather than assumed"
rm -f /tmp/br1c.stop /tmp/br1c.probe
( while [[ ! -f /tmp/br1c.stop ]]; do
    # curl writes 000 on a refused connection AND exits non-zero, so a
    # `|| echo 000` appends a second copy. Match a prefix, not an exact 000.
    printf '%s\n' "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$BASE/healthz" 2>/dev/null)" >> /tmp/br1c.probe
  done ) & PP=$!
sleep 2
rm -rf "$DIR/backups"; bash setup.sh --backup > /tmp/br1c.bk 2>&1; BKRC=$?
sleep 1; touch /tmp/br1c.stop; wait $PP 2>/dev/null
DOWN=$(grep -c '^000' /tmp/br1c.probe); UP=$(grep -c '^200' /tmp/br1c.probe)
chk "backup exits 0" "$BKRC" "0"
[[ "$DOWN" -gt 0 ]] && ok "the server was unreachable for $DOWN probes during the snapshot" \
                    || no "the server never went down — the snapshot was taken live"
[[ "$UP" -gt 0 ]] && ok "and reachable for $UP probes outside it (the probe can see both states)" \
                  || no "the probe never saw a healthy server — it measures nothing"
chk "it is serving again by the time --backup returns" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/healthz")" "200"
BK="$(ls -t "$DIR"/backups/*.tgz | head -1)"
BID=$(python3 -c "import json,glob;print(json.load(open(sorted(glob.glob('$DIR/backups/*.manifest.json'))[-1]))['backup_id'])")
echo "  archive $(basename "$BK")  backup_id $BID"

step "2. a backup taken under load is internally consistent"
rm -f /tmp/br1c.wstop /tmp/br1c.wj; : > /tmp/br1c.wj
APP=$(curl -s -H "Authorization: Bearer $KEY" "$BASE/api/v1/apps" | python3 -c 'import json,sys;print(json.load(sys.stdin)["apps"][0]["app_id"])')
T="c$(date +%s)"
for sh in a b; do
  BASE=$BASE KEY=$KEY APP=$APP JOURNAL=/tmp/br1c.wj RUNTAG="$T$sh" SHAPE=fast STOPFILE=/tmp/br1c.wstop \
    bash "$SCRIPTS/br1_writer.sh" & done
sleep 2; rm -rf "$DIR/backups2"; BACKUP_DIR=x bash setup.sh --backup >/dev/null 2>&1
sleep 1; touch /tmp/br1c.wstop; wait 2>/dev/null
W=$(grep -c 'artifact.bytes ' /tmp/br1c.wj)
if (( W < 3 )); then no "the writer completed only $W writes — this check measures nothing"; else
  ok "the writer completed $W artifact writes during the snapshot"
  BK2="$(ls -t "$DIR"/backups/*.tgz | head -1)"
  rm -rf /tmp/br1c.ex && mkdir -p /tmp/br1c.ex && tar xzf "$BK2" -C /tmp/br1c.ex
  sqlite3 /tmp/br1c.ex/code_push.db "select storage_key||' '||status from artifacts order by 1" > /tmp/br1c.db
  ( cd /tmp/br1c.ex/artifacts && find . -type f | sed 's|^\./||' | sort ) > /tmp/br1c.obj
  TEARS=$(bash "$SCRIPTS/br1_tear_check.sh" /tmp/br1c.db /tmp/br1c.obj | sed -n 's/.*TEARS=\([0-9]*\).*/\1/p')
  chk "the archive holds no state the live system could not have been in" "$TEARS" "0"
  BK="$BK2"
fi

step "3. restore is exact, into a dirty volume"
# The expectation is what the ARCHIVE holds, not what the live volume holds
# now: step 2 kept writing after the snapshot was taken, so a live snapshot
# would legitimately differ and the comparison would be meaningless.
rm -rf /tmp/br1c.want && mkdir -p /tmp/br1c.want && tar xzf "$BK" -C /tmp/br1c.want
inv /tmp/br1c.want /tmp/br1c.inv_pre
SA=$(curl -fsS -X POST "$BASE/api/v1/apps" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
      -d '{"display_name":"CERT-STALE-MUST-VANISH"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
docker run --rm -v "$VOL":/data busybox sh -c 'echo S > /data/CERT-STRAY.txt; mkdir -p /data/artifacts/release/88888; echo S > /data/artifacts/release/88888/stray'
bash setup.sh --restore "$BK" > /tmp/br1c.rs 2>&1; RRC=$?
for _ in $(seq 1 60); do curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break; sleep 1; done
chk "restore exits 0" "$RRC" "0"
chk "it verified the archive before touching the volume" \
  "$(grep -c 'Validating' /tmp/br1c.rs)" "1"
snap /tmp/br1c.post; inv /tmp/br1c.post /tmp/br1c.inv_post
if diff -q /tmp/br1c.inv_pre /tmp/br1c.inv_post >/dev/null; then ok "the restored volume is identical to the archive's own contents"
else no "the restored state differs:"; diff /tmp/br1c.inv_pre /tmp/br1c.inv_post | head -5; fi
chk "the stale app is gone" \
  "$(sqlite3 /tmp/br1c.post/code_push.db "select count(*) from apps where app_id='$SA'")" "0"
chk "the stray file is gone" "$(ls /tmp/br1c.post/CERT-STRAY.txt 2>/dev/null | wc -l | tr -d ' ')" "0"
chk "the stray object is gone" "$(ls /tmp/br1c.post/artifacts/release/88888 2>/dev/null | wc -l | tr -d ' ')" "0"
chk "MANIFEST.json is not left in the live volume" \
  "$(ls /tmp/br1c.post/MANIFEST.json 2>/dev/null | wc -l | tr -d ' ')" "0"

step "4. the restored deployment still works: new patch, upload, promote, device fetch"
api(){ curl -fsS -H "Authorization: Bearer $KEY" "$@"; }
RID=$(api "$BASE/api/v1/apps/$APP/releases" | python3 -c 'import json,sys;print(json.load(sys.stdin)["releases"][0]["id"])')
VER=$(api "$BASE/api/v1/apps/$APP/releases" | python3 -c 'import json,sys;print(json.load(sys.stdin)["releases"][0]["version"])')
PID=$(api -X POST "$BASE/api/v1/apps/$APP/patches" -H 'Content-Type: application/json' -d "{\"release_id\":$RID}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
f=$(mktemp); printf 'CERT-POST-RESTORE\n' > "$f"; head -c 512 /dev/urandom >> "$f"
sz=$(stat -f%z "$f"); sha=$(shasum -a 256 "$f"|cut -d' ' -f1)
U=$(api -X POST "$BASE/api/v1/apps/$APP/patches/$PID/artifacts" -F arch=aarch64 -F platform=android -F "hash=$sha" -F "size=$sz" | python3 -c 'import json,sys;print(json.load(sys.stdin)["url"])')
api -X POST -F "file=@$f" "$U" >/dev/null; rm -f "$f"
CID=$(api "$BASE/api/v1/apps/$APP/channels" | python3 -c "import json,sys;print(next(x['id'] for x in json.load(sys.stdin) if x['name']=='stable'))")
api -X POST "$BASE/api/v1/apps/$APP/patches/promote" -H 'Content-Type: application/json' -d "{\"patch_id\":$PID,\"channel_id\":$CID,\"rollout\":100}" >/dev/null
DL=$(api -X POST "$BASE/api/v1/patches/check" -H 'Content-Type: application/json' \
      -d "{\"app_id\":\"$APP\",\"release_version\":\"$VER\",\"patch_number\":0,\"platform\":\"android\",\"arch\":\"aarch64\",\"channel\":\"stable\"}" \
      | python3 -c 'import json,sys;d=json.load(sys.stdin);print((d.get("patch") or {}).get("download_url",""))')
if [[ -z "$DL" ]]; then no "the device check offered no patch"; else
  curl -sS -o /tmp/br1c.dl "$DL"
  chk "a device downloads the new patch byte-for-byte" "$(shasum -a 256 /tmp/br1c.dl | cut -d' ' -f1)" "$sha"
fi

step "5. negative controls — each must refuse, for its own reason, changing nothing"
BN=$(basename "$BK"); BD=$(dirname "$BK")
mkdir -p /tmp/br1c.neg && rm -f /tmp/br1c.neg/*.tgz
head -c 300000 "$BK" > /tmp/br1c.neg/truncated.tgz
docker run --rm -v "$BD":/b:ro -v /tmp/br1c.neg:/o busybox sh -c "
  mkdir -p /w/a && tar xzf /b/$BN -C /w/a && rm -f /w/a/code_push.db* && (cd /w/a && tar czf /o/nodb.tgz .)
  mkdir -p /w/b && tar xzf /b/$BN -C /w/b && V=\$(cd /w/b/artifacts && find . -type f | sort | head -1) && rm -f /w/b/artifacts/\$V && (cd /w/b && tar czf /o/missingobj.tgz .)
  mkdir -p /w/c && tar xzf /b/$BN -C /w/c && V=\$(cd /w/c/artifacts && find . -type f | sort | head -1) && echo T > /w/c/artifacts/\$V && (cd /w/c && tar czf /o/tampered.tgz .)
  mkdir -p /w/d && tar xzf /b/$BN -C /w/d && rm -f /w/d/MANIFEST.json && (cd /w/d && tar czf /o/nomanifest.tgz .)" >/dev/null 2>&1
BEFORE=$(fp)
declare_reason(){ case "$1" in
  truncated)  echo "not a readable gzip tar";;
  nodb)       echo "contains no code_push.db";;
  missingobj) echo "MISSING";;
  tampered)   echo "DIGEST MISMATCH";;
  nomanifest) echo "no MANIFEST.json";;
esac; }
for n in truncated nodb missingobj tampered nomanifest; do
  out=$(bash setup.sh --restore "/tmp/br1c.neg/$n.tgz" 2>&1); rc=$?
  inner=$(docker run --rm -v /tmp/br1c.neg:/backup:ro -v "$DIR/ops/lib":/opt/cpslib:ro busybox sh -c \
    "mkdir -p /tmp/r && cd /tmp/r && tar xzf /backup/$n.tgz 2>/dev/null && sh /opt/cpslib/verify_manifest.sh" 2>&1)
  want=$(declare_reason "$n")
  if (( rc == 0 )); then no "$n was ACCEPTED"; continue; fi
  if printf '%s\n%s' "$out" "$inner" | grep -q "$want"; then ok "$n refused: $want"
  else no "$n refused, but not for '$want': $(printf '%s %s' "$out" "$inner" | tr '\n' ' ' | cut -c1-110)"; fi
  [[ "$(fp)" == "$BEFORE" ]] || no "  … and the volume CHANGED"
done
# An `&&` with no `else` printed nothing at all when the volume HAD changed,
# quietly dropping the check from the report instead of failing it.
if [[ "$(fp)" == "$BEFORE" ]]; then ok "the volume is byte-unchanged after all five refusals"
else no "the volume was modified by a rejected archive"; fi

step "6. the target of a destructive operation is never guessed"
TMPD=$(mktemp -d); cp setup.sh docker-compose.yaml "$TMPD/"; mkdir -p "$TMPD/ops/lib"; cp ops/lib/*.sh "$TMPD/ops/lib/"
sed 's/^PORT=.*/PORT=19998/' .env > "$TMPD/.env"
for act in --backup "--restore $BK"; do
  o=$( cd "$TMPD" && bash setup.sh $act 2>&1 )
  if printf '%s' "$o" | grep -q "ambiguous"; then ok "\`setup.sh $act\` from a directory with no deployment refuses"
  else no "\`setup.sh $act\` from a foreign directory did NOT refuse: $(printf '%s' "$o" | tr '\n' ' ' | cut -c1-100)"; fi
done
rm -rf "$TMPD"
[[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/healthz")" == 200 ]] && ok "the neighbouring deployment is still serving" || no "the neighbour was disturbed"

step "RESULT"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ))
