#!/usr/bin/env bash
# cspell:words Dhttp Dhttps getprop getsockname
# Releases and patches an Android app with this checkout's CLI, against a
# throwaway self-hosted code_push_server, on a phone from ci-build's device pool
# (qa-pool), and checks that the phone runs the patch.
#
#   selfhost/ci/android_pool_e2e.sh
#
# The phone reaches the server through `adb reverse`, so the app's base_url is
# http://127.0.0.1:<port> and the app allows cleartext traffic. Engine
# artifacts come from the CDN mirror (SHOREBIRD_ARTIFACT_ORIGIN).
#
# Settings (environment):
#   QA_POOL_URL                 the device pool, default http://127.0.0.1:5550
#   SHOREBIRD_ARTIFACT_ORIGIN   the CDN mirror, default http://127.0.0.1:8085
#   E2E_POOL_OWNER              the pool reservation's owner name; make it unique
#   E2E_WORK                    scratch directory, default $RUNNER_TEMP/sb-e2e
#   E2E_FLUTTER_REVISION        run on this Shorebird Flutter commit instead of the
#                               pinned one (rewrites bin/internal/flutter.version in
#                               this checkout, so use a throwaway one), cloned from
#                               SHOREBIRD_FLUTTER_GIT_URL
#
# Needs adb, java, curl, python3 and openssl on PATH. Exits non-zero, with the
# server log and the device log tail, on any failure.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
POOL=${QA_POOL_URL:-http://127.0.0.1:5550}
export SHOREBIRD_ARTIFACT_ORIGIN=${SHOREBIRD_ARTIFACT_ORIGIN:-http://127.0.0.1:8085}
OWNER=${E2E_POOL_OWNER:-shorebird-e2e-$(hostname)-$$}
WORK=${E2E_WORK:-${RUNNER_TEMP:-/tmp}/sb-e2e}
# A free port from the kernel's ephemeral range, which ci-build's egress rules let
# a job use on loopback (selfhost/ci-host/bin/gha-egress-apply).
free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}
PORT=$(free_port)
# Not adb's default 5037: ci-build's own adb server holds it, and a job may not
# reach it.
export ANDROID_ADB_SERVER_PORT
ANDROID_ADB_SERVER_PORT=$(free_port)
API_KEY=sb_api_e2e_$(openssl rand -hex 16)
BASE=http://127.0.0.1:$PORT
PKG=dev.selfhost.e2e.app
VERSION=1.0.0+1

rm -rf "$WORK"
mkdir -p "$WORK"
SERIAL=
SERVER_PID=

log() { printf '\n=== %s\n' "$*"; }

cleanup() {
  local status=$?
  if [[ $status -ne 0 ]]; then
    log "FAILED (exit $status); server log tail"
    tail -40 "$WORK/server.log" 2>/dev/null || true
    if [[ -n $SERIAL ]]; then
      log "device log tail"
      adb -s "$SERIAL" logcat -d -t 200 2>/dev/null | grep -E 'flutter|shorebird|AndroidRuntime' | tail -60 || true
    fi
  fi
  [[ -n $SERIAL ]] && adb -s "$SERIAL" uninstall "$PKG" >/dev/null 2>&1 || true
  curl -fsS -X POST "$POOL/release?owner=$OWNER" >/dev/null 2>&1 || true
  [[ -n $SERVER_PID ]] && kill "$SERVER_PID" 2>/dev/null || true
  adb kill-server >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

# Waits up to $3 seconds for the device log since $2 (device time, seconds)
# to show a line matching $1.
wait_log() {
  local pattern=$1 since=$2 limit=$3 waited=0
  until adb -s "$SERIAL" logcat -d -T "$since.000" 2>/dev/null | grep -qE "$pattern"; do
    ((waited += 3))
    if ((waited > limit)); then
      echo "no device log line matching '$pattern' within ${limit}s" >&2
      return 1
    fi
    sleep 3
  done
  echo "seen: $pattern"
}

# Cold-starts the app and prints the device time just before the launch.
launch() {
  adb -s "$SERIAL" shell am force-stop "$PKG"
  local now
  now=$(adb -s "$SERIAL" shell date +%s | tr -d '\r')
  adb -s "$SERIAL" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null
  echo "$now"
}

log "CLI and its Flutter"
if [[ -n ${E2E_FLUTTER_REVISION:-} ]]; then
  [[ $E2E_FLUTTER_REVISION =~ ^[0-9a-f]{40}$ ]] || { echo "E2E_FLUTTER_REVISION must be a full commit hash" >&2; exit 2; }
  echo "$E2E_FLUTTER_REVISION" >"$ROOT/bin/internal/flutter.version"
  echo "Flutter overridden to $E2E_FLUTTER_REVISION from ${SHOREBIRD_FLUTTER_GIT_URL:-the default remote}"
fi
SB=$ROOT/bin/shorebird
# The launcher's first run fetches Flutter's Dart SDK from SHOREBIRD_DOWNLOAD_URL
# only. Set it for that run alone: the CLI reads it too, as upstream's layout
# (<url>/shorebird/<engine>/...), which the mirror doesn't serve.
SHOREBIRD_DOWNLOAD_URL=${SHOREBIRD_DOWNLOAD_URL:-$SHOREBIRD_ARTIFACT_ORIGIN} "$SB" --version
FLUTTER_DIR=$ROOT/bin/cache/flutter/$(cat "$ROOT/bin/internal/flutter.version")
DART=$FLUTTER_DIR/bin/cache/dart-sdk/bin/dart

log "throwaway code_push_server on $BASE"
(cd "$ROOT/packages/code_push_server" && "$DART" pub get >/dev/null)
(
  cd "$ROOT/packages/code_push_server"
  API_KEY=$API_KEY URL_SIGNING_SECRET=$(openssl rand -hex 32) PORT=$PORT PUBLIC_BASE_URL=$BASE \
    DATA_DIR=$WORK/server-data \
    exec "$DART" run bin/server.dart
) >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 60); do
  curl -fsS "$BASE/readyz" >/dev/null 2>&1 && break
  kill -0 "$SERVER_PID" 2>/dev/null || { echo "the server exited" >&2; exit 1; }
  sleep 2
done
curl -fsS "$BASE/readyz" >/dev/null

log "phone from the pool (owner $OWNER)"
lease=$(curl -fsS -X POST "$POOL/checkout?owner=$OWNER&ttl=60&wait=20&why=shorebird+android+e2e")
SERIAL=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["serial"])' <<<"$lease")
echo "checked out $SERIAL"
adb connect "$SERIAL"
adb -s "$SERIAL" wait-for-device
for _ in $(seq 60); do
  [[ $(adb -s "$SERIAL" shell getprop sys.boot_completed | tr -d '\r') == 1 ]] && break
  sleep 2
done
adb -s "$SERIAL" shell getprop ro.product.cpu.abi
adb -s "$SERIAL" reverse "tcp:$PORT" "tcp:$PORT"

log "app"
cd "$WORK"
FLUTTER_STORAGE_BASE_URL=$SHOREBIRD_ARTIFACT_ORIGIN "$FLUTTER_DIR/bin/flutter" create \
  --org dev.selfhost.e2e --project-name app --platforms android --empty app >"$WORK/create.log"
APP=$WORK/app
echo "void main() { print('SB-E2E-V1'); }" >"$APP/lib/main.dart"
app_id=$(curl -fsS -X POST "$BASE/api/v1/apps" -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' -d '{"display_name":"android-pool-e2e"}' |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
printf 'app_id: %s\nbase_url: %s\n' "$app_id" "$BASE" >"$APP/shorebird.yaml"
python3 -I "$ROOT/selfhost/scripts/lib/add_shorebird_asset.py" "$APP/pubspec.yaml"
# The app talks to the server over http://127.0.0.1 (adb reverse).
perl -pi -e 's/<application/<application android:usesCleartextTraffic="true"/' \
  "$APP/android/app/src/main/AndroidManifest.xml"
grep -q 'usesCleartextTraffic="true"' "$APP/android/app/src/main/AndroidManifest.xml"

export SHOREBIRD_HOSTED_URL=$BASE SHOREBIRD_TOKEN=$API_KEY
# Gradle ignores HTTPS_PROXY; hand it the job's proxy as Java properties.
if [[ ${HTTPS_PROXY:-} =~ ^https?://([^:/]+):([0-9]+) ]]; then
  export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} -Dhttps.proxyHost=${BASH_REMATCH[1]} -Dhttps.proxyPort=${BASH_REMATCH[2]} -Dhttp.proxyHost=${BASH_REMATCH[1]} -Dhttp.proxyPort=${BASH_REMATCH[2]} -Dhttp.nonProxyHosts=localhost|127.*|10.0.2.2"
fi
cd "$APP"

# A new app's release manifest lacks the INTERNET permission the updater needs.
"$SB" doctor --fix
grep -q 'android.permission.INTERNET' android/app/src/main/AndroidManifest.xml

log "release $VERSION"
"$SB" release android --artifact apk --no-confirm
adb -s "$SERIAL" install -r build/app/outputs/flutter-apk/app-release.apk
since=$(launch)
wait_log 'I flutter : SB-E2E-V1' "$since" 60

log "patch 1"
echo "void main() { print('SB-E2E-V2'); }" >lib/main.dart
"$SB" patch android --release-version "$VERSION" --no-confirm

# This launch still runs the release and downloads the patch; the next one
# boots it.
since=$(launch)
wait_log 'I flutter : SB-E2E-V1' "$since" 60
wait_log 'Patch 1 successfully' "$since" 120
since=$(launch)
wait_log 'I flutter : SB-E2E-V2' "$since" 60

log "PASS: the phone ran the release, downloaded patch 1 and booted it"
