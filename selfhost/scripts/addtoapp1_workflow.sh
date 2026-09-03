#!/usr/bin/env bash
# cspell:words getsockname addtoapp
# ADD-TO-APP-1 stage 1: walk the REAL developer workflow for an iOS Add-to-App
# module against a throwaway self-hosted control plane, and record where it
# first fails. Prediction from code reading is that `shorebird release
# ios-framework` registers only `xcframework`, which the control plane's iOS
# activation gate refuses.
#
# Throwaway control plane, temp dir, free port. Never touches cps-ios,
# cps-android, any cell, any device, or any existing release.
set -uo pipefail
REPO=/Users/mendell/shorebird
SB=/Volumes/build/route-b/shorebird-candidate/bin/shorebird
FLUTTER=/Volumes/build/route-b/shorebird-candidate/bin/cache/flutter/e64eb0af52e1c43c3b21a39556d789538d0df9b3/bin/flutter
API_KEY="sb_api_addtoapp_$(date +%s)"
WORK=$(mktemp -d /tmp/addtoapp1.XXXXXX)
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
BASE="http://127.0.0.1:$PORT"
LOG="$WORK/server.log"
SERVER_PID=""
cleanup(){ [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; echo; echo "workdir: $WORK"; }
trap cleanup EXIT
step(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

step "0. throwaway control plane on :$PORT"
mkdir -p "$WORK/data"
( cd "$REPO/packages/code_push_server" && PORT=$PORT API_KEY="$API_KEY" \
  DB_BACKEND=sqlite STORAGE_BACKEND=file DATA_DIR="$WORK/data" \
  PUBLIC_BASE_URL="$BASE" LOG_FORMAT=json \
  URL_SIGNING_SECRET="$(openssl rand -hex 32)" \
  LOGIN_EMAIL="addtoapp@self-host.local" dart run bin/server.dart ) >"$LOG" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 60); do curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fsS "$BASE/healthz" >/dev/null || { echo "server did not start"; exit 1; }
echo "  up"

step "1. create a real Flutter MODULE via the normal path"
( cd "$WORK" && "$FLUTTER" create -t module --org dev.selfhost addtoapp_module ) \
  > "$WORK/create.log" 2>&1
MOD="$WORK/addtoapp_module"
[ -d "$MOD" ] || { echo "  module creation FAILED"; tail -20 "$WORK/create.log"; exit 1; }
echo "  module at $MOD"
ls "$MOD" | tr '\n' ' '; echo
# The unmistakable Flutter-visible string the patch would later change.
python3 - "$MOD/lib/main.dart" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read()
s=s.replace('_counter', '_counter')  # no-op; keep the template intact
open(p,'w').write(s)
PY

step "2. register the app and point the module at the self-host"
APP_ID=$(curl -fsS -X POST "$BASE/api/v1/apps" -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' -d '{"display_name":"addtoapp"}' \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
cat > "$MOD/shorebird.yaml" <<YAML
app_id: $APP_ID
base_url: $BASE
YAML
# `shorebird init` also adds shorebird.yaml to the module's flutter assets, and
# a validator refuses the release without it. Hand-writing only the yaml made
# the first run fail on that validator -- a harness shortcut, not an
# Add-to-App finding, and exactly the "bespoke harness that bypasses the
# developer workflow" the ruling warns against. Done here the way init does it.
python3 "$REPO/selfhost/scripts/lib/add_shorebird_asset.py" "$MOD/pubspec.yaml"
echo "  app_id=$APP_ID"

step "3. shorebird release ios-framework — the real command"
# The frozen stack's coherence authority. SUPPORTED_STATE.yaml names it as an
# operational requirement for iOS; without it the build refuses with
# COHERENCE_UNDETERMINABLE, which is the intended behaviour. Pointed at the
# overlay for the CURRENT cell (cd848320...), not the older one the p6-signing
# note happens to quote.
export SHOREBIRD_PUBLISHED_IOS_ENGINE_DIR=\
"$REPO/selfhost/cdn/overlay/flutter_infra_release/flutter/cd848320d605ff8af5060cabf9a8d1b35853f752"
[ -d "$SHOREBIRD_PUBLISHED_IOS_ENGINE_DIR" ] || { echo "  no overlay for the frozen cell"; exit 1; }
echo "  coherence authority: $(basename "$SHOREBIRD_PUBLISHED_IOS_ENGINE_DIR")"
# `-- --no-codesign` is forwarded to `flutter build ios-framework`. Not a
# harness shortcut: an Add-to-App module's frameworks are signed by the HOST
# app at its own build time, so an unsigned module artifact is the normal
# product of this command. Without it this box fails on an ambiguous signing
# identity -- two identical "Apple Development: ..." certificates in the login
# keychain -- which is an environment fault and not an Add-to-App finding.
set +e
( cd "$MOD" && SHOREBIRD_HOSTED_URL="$BASE" SHOREBIRD_TOKEN="$API_KEY" \
  SHOREBIRD_PUBLISHED_IOS_ENGINE_DIR="$SHOREBIRD_PUBLISHED_IOS_ENGINE_DIR" \
  "$SB" release ios-framework --release-version 1.0.0+1 --no-confirm \
    -- --no-codesign ) \
  > "$WORK/release.log" 2>&1
RC=$?
set -e
echo "  exit=$RC"
echo "  --- last 30 lines ---"
tail -30 "$WORK/release.log" | sed 's/^/    | /'

step "4. what reached the control plane"
python3 - "$LOG" <<'PY'
import json,sys
for l in open(sys.argv[1]):
    try: d=json.loads(l)
    except Exception: continue
    if d.get('msg')=='request':
        print(f"    {d['method']:6} {d['path']:60} {d['status']}")
PY
step "5. the release's registered artifacts and lifecycle"
curl -fsS "$BASE/api/v1/apps/$APP_ID/releases" -H "Authorization: Bearer $API_KEY" \
  | python3 -m json.tool | sed 's/^/    /'
for R in $(curl -fsS "$BASE/api/v1/apps/$APP_ID/releases" -H "Authorization: Bearer $API_KEY" \
  | python3 -c 'import json,sys;print(" ".join(str(r["id"]) for r in json.load(sys.stdin)["releases"]))'); do
  echo "    release $R artifacts:"
  curl -fsS "$BASE/api/v1/apps/$APP_ID/releases/$R/artifacts" -H "Authorization: Bearer $API_KEY" \
    | python3 -c 'import json,sys
for a in json.load(sys.stdin)["artifacts"]: print("      ", a["arch"], a["platform"], a["size"])'
done
step "6. the audit trail says what was attempted and what happened"
curl -fsS "$BASE/admin/audit?limit=100" -H "Authorization: Bearer $API_KEY" > "$WORK/audit.json"
python3 - "$WORK/audit.json" <<'PY'
import json, sys
for e in json.load(open(sys.argv[1]))['events']:
    print('    %-28s %-8s %-5s %s' % (e['operation'], e['result'],
          e['http_status'], str(e.get('detail') or '')[:70]))
PY
