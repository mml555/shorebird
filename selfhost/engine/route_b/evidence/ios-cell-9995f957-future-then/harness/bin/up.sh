# Origin proxy to ci-build's production mirror, outbound-connect logger, device syslog, CLI bootstrap, local server.
set -uo pipefail
. "$(dirname "$0")/../env.sh"
trap unlock EXIT
die(){ echo "UP STOP: $*"; exit 1; }
cd $R
for p in 18185 18188 18290; do
  holder=$(lsof -nP -iTCP:"$p" -sTCP:LISTEN 2>/dev/null | awk 'NR==2{print $1" (pid "$2")"}')
  [[ -z "$holder" ]] || die "port $p is already in use by $holder; stop it first"
done
nohup python3 -I bin/origin.py 18185 http://10.0.0.41:8085 $R/logs/origin.jsonl > logs/origin.out 2>&1 & echo $! > origin.pid
nohup python3 -I bin/connproxy.py 18188 $R/logs/connproxy.jsonl > logs/connproxy.out 2>&1 & echo $! > connproxy.pid
nohup idevicesyslog -u $UDID > logs/syslog.txt 2>&1 & echo $! > syslog.pid
# Wait for the two proxies to listen: under load Python takes seconds to start (5 s at load 21 on 2026-11-24).
for p in 18185 18188; do for i in $(seq 1 60); do nc -z -w 1 127.0.0.1 $p 2>/dev/null && break; sleep 1; done; nc -z -w 1 127.0.0.1 $p || die "nothing listens on $p after 60 s"; done
curl -fsS -o /dev/null -w 'descriptor %{http_code} %{size_download}\n' http://127.0.0.1:18185/download.shorebird.dev/shorebird/cell-manifests/$CELL.v2 || die "descriptor not served"
lock "bootstrap"
$SB --version -v > logs/bootstrap.log 2>&1; rc=$?; echo "bootstrap exit=$rc"
unlock
grep -E "Engine .*revision|Flutter .*revision|Flutter [0-9]" logs/bootstrap.log | head -4
grep -q "revision $CELL" logs/bootstrap.log || die "bootstrap did not resolve engine $CELL"
DART=$CLI/bin/cache/flutter/$FLUTTER_REV/bin/cache/dart-sdk/bin/dart
(cd $CLI/packages/code_push_server && $DART pub get > $R/logs/server_pubget.log 2>&1) || die "server pub get"
nohup env API_KEY="$API_KEY" URL_SIGNING_SECRET="$URL_SIGNING_SECRET" PORT=18290 PUBLIC_BASE_URL="$BASE" DATA_DIR="$R/data" \
  bash -c 'cd "$1" && exec "$2" run bin/server.dart' _ "$CLI/packages/code_push_server" "$DART" > logs/server.log 2>&1 &
echo $! > server.pid
for i in $(seq 1 90); do curl -fsS --max-time 2 "$BASE/readyz" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS --max-time 2 "$BASE/readyz" >/dev/null || { tail -20 logs/server.log; die "server not ready"; }
holder=$(lsof -nP -t -iTCP:18290 -sTCP:LISTEN 2>/dev/null | head -1)
[[ "$holder" == "$(cat server.pid)" ]] || die "port 18290 is held by pid ${holder:-none}, not this run's server"
echo UP_DONE
