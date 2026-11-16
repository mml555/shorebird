set -uo pipefail
. "$(dirname "$0")/../env.sh"
die(){ echo "UP STOP: $*"; exit 1; }
cd $R
nohup python3 -I bin/origin.py 18185 http://10.0.0.41:8085 $R/logs/origin.jsonl > logs/origin.out 2>&1 & echo $! > origin.pid
nohup python3 -I bin/connproxy.py 18188 $R/logs/connproxy.jsonl > logs/connproxy.out 2>&1 & echo $! > connproxy.pid
nohup idevicesyslog -u $UDID > logs/syslog.txt 2>&1 & echo $! > syslog.pid
sleep 2
curl -fsS -o /dev/null -w 'descriptor %{http_code} %{size_download}\n' http://127.0.0.1:18185/download.shorebird.dev/shorebird/cell-manifests/2fc41d3fbd9966958ba3ccf2be9761e064e92bcc.v2 || die "descriptor not served"
$SB --version -v > logs/bootstrap.log 2>&1; echo "bootstrap exit=$?"
grep -E "Engine .*revision|Flutter .*revision|Flutter [0-9]" logs/bootstrap.log | head -4
grep -q "revision 2fc41d3fbd9966958ba3ccf2be9761e064e92bcc" logs/bootstrap.log || die "bootstrap did not resolve engine 2fc41d3f"
DART=$CLI/bin/cache/flutter/5c60356ca635c74696ab737e2d5e77f04d615057/bin/cache/dart-sdk/bin/dart
(cd $CLI/packages/code_push_server && $DART pub get > $R/logs/server_pubget.log 2>&1) || die "server pub get"
nohup env API_KEY="$API_KEY" URL_SIGNING_SECRET="$URL_SIGNING_SECRET" PORT=18290 PUBLIC_BASE_URL="$BASE" DATA_DIR="$R/data" \
  bash -c 'cd "$1" && exec "$2" run bin/server.dart' _ "$CLI/packages/code_push_server" "$DART" > logs/server.log 2>&1 &
echo $! > server.pid
for i in $(seq 1 90); do curl -fsS --max-time 2 "$BASE/readyz" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS --max-time 2 "$BASE/readyz" >/dev/null || { tail -20 logs/server.log; die "server not ready"; }
echo UP_DONE
