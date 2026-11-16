#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2164,SC2034
set -uo pipefail
. "${DEVRUN_ENV:-$(dirname "$0")/../env.sh}" || exit 1
die(){ echo "UP STOP: $*"; exit 1; }
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$R" || die "no work dir $R"
nohup python3 -I "$HERE"/origin.py "$ORIGIN_PORT" "$ARTIFACT_UPSTREAM" "$R/logs/origin.jsonl" > logs/origin.out 2>&1 & echo $! > origin.pid
nohup python3 -I "$HERE"/connproxy.py "$PROXY_PORT" "$R/logs/connproxy.jsonl" > logs/connproxy.out 2>&1 & echo $! > connproxy.pid
nohup idevicesyslog -u $UDID > logs/syslog.txt 2>&1 & echo $! > syslog.pid
sleep 2
curl -fsS -o /dev/null -w 'descriptor %{http_code} %{size_download}\n' "$SHOREBIRD_ARTIFACT_ORIGIN/download.shorebird.dev/shorebird/cell-manifests/$ENGINE_REV.v2" || die "descriptor not served"
$SB --version -v > logs/bootstrap.log 2>&1; echo "bootstrap exit=$?"
grep -E "Engine .*revision|Flutter .*revision|Flutter [0-9]" logs/bootstrap.log | head -4
grep -q "revision $ENGINE_REV" logs/bootstrap.log || die "bootstrap did not resolve engine $ENGINE_REV"
DART=$FLUTTER_DIR/bin/cache/dart-sdk/bin/dart
(cd $CLI/packages/code_push_server && $DART pub get > $R/logs/server_pubget.log 2>&1) || die "server pub get"
nohup env API_KEY="$API_KEY" URL_SIGNING_SECRET="$URL_SIGNING_SECRET" PORT="$SERVER_PORT" PUBLIC_BASE_URL="$BASE" DATA_DIR="$R/data" \
  bash -c 'cd "$1" && exec "$2" run bin/server.dart' _ "$CLI/packages/code_push_server" "$DART" > logs/server.log 2>&1 &
echo $! > server.pid
for i in $(seq 1 90); do curl -fsS --max-time 2 "$BASE/readyz" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS --max-time 2 "$BASE/readyz" >/dev/null || { tail -20 logs/server.log; die "server not ready"; }
echo UP_DONE
