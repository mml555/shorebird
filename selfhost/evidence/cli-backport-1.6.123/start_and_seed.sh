#!/usr/bin/env bash
set -eu
S="$(cd "$(dirname "$0")" && pwd)"
rm -rf "$S/srv" && mkdir -p "$S/srv"
cd "$S/wt/packages/code_push_server"
nohup env PORT=18099 DATA_DIR="$S/srv" API_KEY=sb_api_backportcheck_0123456789abcdef \
  URL_SIGNING_SECRET=backport-check-signing-secret-0123456789 PUBLIC_BASE_URL=http://localhost:18099 \
  dart run bin/server.dart > "$S/srv/server.log" 2>&1 &
echo $! > "$S/srv/pid"
for i in $(seq 1 90); do curl -sf http://localhost:18099/readyz >/dev/null 2>&1 && break; sleep 1; done
curl -sf http://localhost:18099/readyz >/dev/null || { echo "server not ready"; tail -5 "$S/srv/server.log"; exit 1; }
B=http://localhost:18099; K=sb_api_backportcheck_0123456789abcdef; H=(-H "Authorization: Bearer $K" -H "content-type: application/json")
jq_() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }
APP=$(curl -sf "${H[@]}" -d '{"display_name":"backport-app"}' $B/api/v1/apps | jq_ 'd["id"]')
REL=$(curl -sf "${H[@]}" -d '{"version":"1.0.0","flutter_revision":"a4a3c0d1b1b0f9975a61f446f0bfa2bbe587ce61","flutter_version":"3.44.8"}' $B/api/v1/apps/$APP/releases | jq_ 'd["release"]["id"]')
CH=$(curl -sf "${H[@]}" -d '{"channel":"stable"}' $B/api/v1/apps/$APP/channels | jq_ 'd["id"]')
P=$(curl -sf "${H[@]}" -d "{\"release_id\":$REL}" $B/api/v1/apps/$APP/patches | jq_ 'd["id"]')
URL=$(curl -sf -H "Authorization: Bearer $K" -F arch=aarch64 -F platform=android -F hash=x -F size=3 $B/api/v1/apps/$APP/patches/$P/artifacts | jq_ 'd["url"]')
printf abc > "$S/p.bin"
curl -sf -o /dev/null -H "Authorization: Bearer $K" -F file=@"$S/p.bin" "$B/api/v1/uploads/${URL##*/}"
curl -sf -o /dev/null "${H[@]}" -d "{\"patch_id\":$P,\"channel_id\":$CH}" $B/api/v1/apps/$APP/patches/promote
printf 'APP=%s\nREL=%s\nCH=%s\n' "$APP" "$REL" "$CH" > "$S/seed.env"
echo "seeded APP=$APP REL=$REL CH=$CH patch=$P"
