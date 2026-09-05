#!/usr/bin/env bash
# cspell:words getsockname minio rollout withdraw mkart collab CJSON flutterrev releas
# BACKUP-RESTORE-1: seed a control plane with representative state.
#
# Everything is created through the ordinary HTTP API, not by writing SQL, so
# the state is the shape a real deployment reaches. Artifact BYTES are uploaded
# too: an inventory that only proves rows exist would not notice a backup that
# lost objects.
#
# Routes here are the ones the server actually serves (lib/src/api.dart), not
# the plausible-looking ones -- an earlier draft guessed
# /releases/{id}/patches and /patches/{id}/promote and got 404s.
set -uo pipefail
BASE=${BASE:?set BASE}
KEY=${KEY:?set KEY}
OUT=${OUT:?set OUT}
TAG=${TAG:-br1}
mkdir -p "$OUT"
say(){ printf '  %s\n' "$1"; }
api(){ curl -fsS -H "Authorization: Bearer $KEY" "$@"; }
J(){ python3 -c "import json,sys;d=json.load(sys.stdin);$1"; }

APP=$(api -X POST "$BASE/api/v1/apps" -H 'Content-Type: application/json' \
        -d "{\"display_name\":\"$TAG-seed\"}" | J 'print(d["id"])')
say "app         $APP"

# --- identity / tenancy: a second account with its own credential, and a role
COLLAB_EMAIL="$TAG-dev@self-host.local"
CJSON=$(api -X POST "$BASE/admin/users?email=$COLLAB_EMAIL&name=$TAG+dev" 2>/dev/null || echo '')
if [[ -n "$CJSON" ]]; then
  COLLAB_KEY=$(printf '%s' "$CJSON" | J 'print(d["api_key"])')
  COLLAB_UID=$(printf '%s' "$CJSON" | J 'print(d["user_id"])')
  say "collaborator user_id=$COLLAB_UID credential minted"
  printf '%s\n' "$COLLAB_KEY" > "$OUT/collab_api_key.txt"
  api -X POST "$BASE/admin/apps/$APP/collaborators?email=$COLLAB_EMAIL&role=developer" \
    >"$OUT/collab_grant.json" 2>/dev/null && say "collaborator role=developer granted" \
    || say "collaborator grant FAILED"
else
  say "collaborator mint FAILED (not a server admin?)"
fi

# --- channels: promotion targets. stable exists by default on most paths, but
# create both explicitly so the inventory has known ids.
# bash 3.2 (the macOS default) has no associative arrays.
chan_id(){ # name -> id, creating it if absent
  local c=$1 id
  id=$(api -X POST "$BASE/api/v1/apps/$APP/channels" -H 'Content-Type: application/json' \
        -d "{\"channel\":\"$c\"}" 2>/dev/null | J 'print(d.get("id",""))' 2>/dev/null || echo '')
  if [[ -z "$id" ]]; then
    id=$(api "$BASE/api/v1/apps/$APP/channels" \
        | J "print(next((x['id'] for x in d if x.get('name')=='$c'),''))")
  fi
  printf '%s' "$id"
}
CH_stable=$(chan_id stable); say "channel     stable -> id $CH_stable"
CH_beta=$(chan_id beta);     say "channel     beta   -> id $CH_beta"

# An artifact is TWO writes: the row (status=pending) and then the bytes.
# The gap between them is exactly where a non-quiesced backup can tear.
mkart(){ # kind ownerId arch file -> sha256
  local kind=$1 oid=$2 arch=$3 f=$4 sz sha url
  sz=$(stat -f%z "$f"); sha=$(shasum -a 256 "$f" | cut -d' ' -f1)
  url=$(api -X POST "$BASE/api/v1/apps/$APP/${kind}es/$oid/artifacts" \
        -F "arch=$arch" -F platform=android -F "hash=$sha" -F "size=$sz" \
        | J 'print(d["url"])') || return 1
  api -X POST -F "file=@$f" "$url" >/dev/null || return 1
  printf '%s' "$sha"
}

# `releases` and `patches` both pluralize with -es under mkart's ${kind}es, so
# pass the singular stems that produce them.
RIDS=()
for v in 1.0.0+1 1.1.0+1; do
  RID=$(api -X POST "$BASE/api/v1/apps/$APP/releases" -H 'Content-Type: application/json' \
        -d "{\"version\":\"$v\",\"flutter_revision\":\"${TAG}flutterrev\",\"flutter_version\":\"3.99.0\",\"display_name\":\"$TAG $v\"}" \
        | J 'print(d["release"]["id"])')
  say "release     $v -> id $RID"
  for arch in aarch64 arm x86_64; do
    f="$OUT/r_${v}_${arch}.bin"
    { printf '%s release %s %s %s\n' "$TAG" "$v" "$arch" "$(date +%s%N)"; head -c 4096 /dev/urandom; } > "$f"
    h=$(mkart releas "$RID" "$arch" "$f") && say "  artifact  $arch $h" || say "  artifact  $arch FAILED"
  done
  api -X PATCH "$BASE/api/v1/apps/$APP/releases/$RID" -H 'Content-Type: application/json' \
    -d '{"status":"active"}' >/dev/null 2>&1 || true
  RIDS+=("$RID")
done

n=0
for RID in "${RIDS[@]}"; do
  n=$((n+1))
  PID=$(api -X POST "$BASE/api/v1/apps/$APP/patches" -H 'Content-Type: application/json' \
        -d "{\"release_id\":$RID,\"notes\":\"$TAG patch $n\"}" | J 'print(d["id"])')
  say "patch       id $PID (release $RID)"
  for arch in aarch64 arm; do
    f="$OUT/p_${n}_${arch}.bin"
    { printf '%s patch %s %s %s\n' "$TAG" "$n" "$arch" "$(date +%s%N)"; head -c 2048 /dev/urandom; } > "$f"
    h=$(mkart patch "$PID" "$arch" "$f") && say "  artifact  $arch $h" || say "  artifact  $arch FAILED"
  done
  if [[ $n == 1 ]]; then trk=stable; cid=$CH_stable; pct=100
  else trk=beta; cid=$CH_beta; pct=25; fi
  api -X POST "$BASE/api/v1/apps/$APP/patches/promote" -H 'Content-Type: application/json' \
    -d "{\"patch_id\":$PID,\"channel_id\":$cid,\"rollout\":$pct}" >/dev/null \
    && say "  promoted  $trk rollout=$pct" || say "  promote   FAILED"
done

printf '%s\n' "$APP" > "$OUT/app_id.txt"
say "seed complete"
