#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2164,SC2034
set -uo pipefail
# DEVRUN_BOOTSTRAP=1: the Flutter cache may not exist yet; the bootstrap below fills it.
DEVRUN_BOOTSTRAP=1 . "${DEVRUN_ENV:-$(dirname "$0")/../env.sh}" || exit 1
die(){ echo "UP STOP: $*"; exit 1; }
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$R" || die "no work dir $R"
# A server already on SERVER_PORT answers readyz, so this script would report UP_DONE while its own
# server died on "Address already in use", and the run's releases and patches would go to the other
# server's data. That happened once (2026-11-17), so refuse a busy port up front.
command -v lsof >/dev/null || die "lsof is needed to check the ports"
for p in "$ORIGIN_PORT" "$PROXY_PORT" "$SERVER_PORT"; do
  holder=$(lsof -nP -iTCP:"$p" -sTCP:LISTEN 2>/dev/null | awk 'NR==2{print $1" (pid "$2")"}')
  [[ -z "$holder" ]] || die "port $p is already in use by $holder; stop it first (another device run's server?)"
done
nohup python3 -I "$HERE"/origin.py "$ORIGIN_PORT" "$ARTIFACT_UPSTREAM" "$R/logs/origin.jsonl" > logs/origin.out 2>&1 & echo $! > origin.pid
nohup python3 -I "$HERE"/connproxy.py "$PROXY_PORT" "$R/logs/connproxy.jsonl" > logs/connproxy.out 2>&1 & echo $! > connproxy.pid
nohup idevicesyslog -u "$UDID" > logs/syslog.txt 2>&1 & echo $! > syslog.pid
sleep 2
curl -fsS -o /dev/null -w 'descriptor %{http_code} %{size_download}\n' "$SHOREBIRD_ARTIFACT_ORIGIN/download.shorebird.dev/shorebird/cell-manifests/$ENGINE_REV.v2" || die "descriptor not served"
"$SB" --version -v > logs/bootstrap.log 2>&1; echo "bootstrap exit=$?"
grep -E "Engine .*revision|Flutter .*revision|Flutter [0-9]" logs/bootstrap.log | head -4
grep -q "revision $ENGINE_REV" logs/bootstrap.log || die "bootstrap did not resolve engine $ENGINE_REV"
[ -x "$FLUTTER_DIR/bin/cache/dart-sdk/bin/dart" ] || die "bootstrap did not fill $FLUTTER_DIR (no dart-sdk); FLUTTER_REV must equal $CLI/bin/internal/flutter.version"
DART="$FLUTTER_DIR/bin/cache/dart-sdk/bin/dart"
(cd "$CLI/packages/code_push_server" && "$DART" pub get > "$R/logs/server_pubget.log" 2>&1) || die "server pub get"
nohup env API_KEY="$API_KEY" URL_SIGNING_SECRET="$URL_SIGNING_SECRET" PORT="$SERVER_PORT" PUBLIC_BASE_URL="$BASE" DATA_DIR="$R/data" \
  bash -c 'cd "$1" && exec "$2" run bin/server.dart' _ "$CLI/packages/code_push_server" "$DART" > logs/server.log 2>&1 &
echo $! > server.pid
# readyz alone does not say WHICH server answered: also require ours to be alive.
for i in $(seq 1 90); do
  kill -0 "$(cat server.pid)" 2>/dev/null || { tail -20 logs/server.log; die "server exited during startup"; }
  curl -fsS --max-time 2 "$BASE/readyz" >/dev/null 2>&1 && break; sleep 1
done
if ! kill -0 "$(cat server.pid)" 2>/dev/null || ! curl -fsS --max-time 2 "$BASE/readyz" >/dev/null; then
  tail -20 logs/server.log; die "server not ready"
fi
# The port was free minutes ago (bootstrap and pub get ran since), so check who holds it now.
holder=$(lsof -nP -t -iTCP:"$SERVER_PORT" -sTCP:LISTEN 2>/dev/null | head -1)
[[ "$holder" == "$(cat server.pid)" ]] || die "port $SERVER_PORT is held by pid ${holder:-none}, not this run's server ($(cat server.pid))"
echo UP_DONE
