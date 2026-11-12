#!/usr/bin/env bash
# cspell:words Dhttp Dhttps getprop getsockname nullglob
# Releases and patches an Android app with this checkout's CLI, against a
# throwaway self-hosted code_push_server, on a phone from ci-build's device pool
# (qa-pool), and checks that the phone runs the patch.
#
#   selfhost/ci/android_pool_e2e.sh
#
# The phone reaches the server through `adb reverse`, so the app's base_url is
# http://127.0.0.1:<port> and the app allows cleartext traffic. Engine
# artifacts come from the CDN mirror (SHOREBIRD_ARTIFACT_ORIGIN). The release is
# built before a phone is checked out, so the pool's phone is held only for
# the install, the patch and the launches.
#
# Settings (environment):
#   QA_POOL_URL                 the device pool, default http://127.0.0.1:5550
#   SHOREBIRD_ARTIFACT_ORIGIN   the CDN mirror, default http://127.0.0.1:8085
#   E2E_POOL_OWNER              the pool reservation's owner name; make it unique
#   E2E_WORK                    scratch directory, default a new one under
#                               $RUNNER_TEMP (or $TMPDIR)
#   E2E_FLUTTER_REVISION        run on this Shorebird Flutter commit instead of the
#                               pinned one (rewrites bin/internal/flutter.version in
#                               this checkout, so use a throwaway one)
#
# Needs adb, java, curl, python3, openssl and timeout on PATH. Exits non-zero,
# with the server log, the device log and the pool's lease, on any failure.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
POOL=${QA_POOL_URL:-http://127.0.0.1:5550}
export SHOREBIRD_ARTIFACT_ORIGIN=${SHOREBIRD_ARTIFACT_ORIGIN:-http://127.0.0.1:8085}
OWNER=${E2E_POOL_OWNER:-shorebird-e2e-$(hostname)-$$}
if [[ -n ${E2E_WORK:-} ]]; then
  WORK=$E2E_WORK
  rm -rf "$WORK"
  mkdir -p "$WORK"
else
  WORK=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sb-e2e.XXXXXX")
fi
# qa-pool's ttl and wait are minutes. The phone is needed for about ten. The
# checkout asks for a short lease, renewed as soon as the phone is in hand, so a
# checkout a cancelled job leaves behind holds a phone for minutes, not half an
# hour.
CHECKOUT_TTL=10
LEASE_TTL=30
PKG=dev.selfhost.e2e.app
API_KEY=sb_api_e2e_$(openssl rand -hex 16)
[[ -n ${GITHUB_ACTIONS:-} ]] && echo "::add-mask::$API_KEY"
SERIAL=
DEVICE=
SERVER_PID=
ADB_STARTED=

log() { printf '\n=== %s\n' "$*"; }

cleanup() {
  local status=$?
  set +e
  # On failure, read the phone and its lease before releasing it: the release
  # resets the phone to its snapshot. Bounded, as the phone may be wedged, and
  # skipped when the job got SIGINT or SIGTERM (cancelled or timed out): the runner
  # kills it seconds later, and the release must go out first.
  local diagnose=
  ((status != 0 && status != 130 && status != 143)) && diagnose=1
  if [[ -n $diagnose && -n $ADB_STARTED ]]; then
    timeout 10 adb -s "$SERIAL" logcat -d 2>/dev/null |
      grep -E 'flutter|shorebird|AndroidRuntime' | tail -60 >"$WORK/device.log"
  fi
  if [[ -n $diagnose && -n $DEVICE ]]; then
    curl -sS --max-time 5 "$POOL/lease?device=$DEVICE" >"$WORK/lease.json" 2>&1
  fi
  # The release resets the phone, so the app needs no uninstall.
  if ! curl -fsS --max-time 15 -X POST "$POOL/release?owner=$OWNER" >/dev/null 2>&1 && [[ -n $DEVICE ]]; then
    echo "::warning::could not release $DEVICE (owner $OWNER); the pool frees it when its lease runs out"
  fi
  if [[ $status -ne 0 ]]; then
    log "FAILED (exit $status); server log tail"
    tail -40 "$WORK/server.log" 2>/dev/null
    if [[ -n $diagnose && -n $ADB_STARTED ]]; then
      log "device log before release (flutter and updater lines)"
      cat "$WORK/device.log" 2>/dev/null
    fi
    if [[ -n $diagnose && -n $DEVICE ]]; then
      log "pool lease of $DEVICE before release"
      cat "$WORK/lease.json" 2>/dev/null
      echo
    fi
  fi
  [[ -n $SERVER_PID ]] && kill "$SERVER_PID" 2>/dev/null
  # Only the job's own adb server, never the default one on 5037.
  [[ -n $ADB_STARTED ]] && timeout 15 adb kill-server >/dev/null 2>&1
  exit "$status"
}
trap cleanup EXIT

# A free port from the kernel's ephemeral range, which ci-build's egress rules let
# a job use on loopback (selfhost/ci-host/bin/gha-egress-apply).
free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# Waits up to $3 seconds for the device log since $2 (device time, seconds)
# to show a line matching $1.
wait_log() {
  local pattern=$1 since=$2 limit=$3 start=$SECONDS out
  while :; do
    # Captured first: `logcat | grep -q` fails under pipefail once grep stops
    # reading a long log.
    out=$(timeout 30 adb -s "$SERIAL" logcat -d -T "$since.000" 2>/dev/null) || true
    if grep -qE "$pattern" <<<"$out"; then
      echo "seen: $pattern"
      return 0
    fi
    if ((SECONDS - start > limit)); then
      echo "no device log line matching '$pattern' within ${limit}s" >&2
      return 1
    fi
    sleep 3
  done
}

# Cold-starts the app and sets LAUNCHED_AT to the device time just before the
# launch. Called directly, not in $(...), so set -e covers each step.
LAUNCHED_AT=
launch() {
  timeout 30 adb -s "$SERIAL" shell am force-stop "$PKG"
  LAUNCHED_AT=$(timeout 30 adb -s "$SERIAL" shell date +%s)
  LAUNCHED_AT=${LAUNCHED_AT//$'\r'/}
  [[ $LAUNCHED_AT =~ ^[0-9]+$ ]] || { echo "bad device time '$LAUNCHED_AT'" >&2; return 1; }
  timeout 30 adb -s "$SERIAL" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null
}

# The Android build installs SDK packages it lacks (build-tools 36 for Flutter
# 3.47), and ci-build's shared SDK isn't writable by jobs. Give the job its own
# SDK: links to the shared one, with build-tools and platforms as directories
# of links it can add to.
if [[ ! -w ${ANDROID_HOME:?set ANDROID_HOME to the Android SDK} ]]; then
  sdk=$WORK/android-sdk
  mkdir -p "$sdk"
  shopt -s nullglob
  for d in "$ANDROID_HOME"/*; do
    n=${d##*/}
    if [[ $n == build-tools || $n == platforms ]]; then
      mkdir -p "$sdk/$n"
      for v in "$d"/*; do ln -s "$v" "$sdk/$n/${v##*/}"; done
    else
      ln -s "$d" "$sdk/$n"
    fi
  done
  shopt -u nullglob
  export ANDROID_HOME=$sdk ANDROID_SDK_ROOT=$sdk
  echo "the shared Android SDK isn't writable; using $sdk over it"
fi
# The runner sets ANDROID_HOME but doesn't put adb on PATH.
export PATH=$ANDROID_HOME/platform-tools:$PATH
command -v adb >/dev/null || { echo "no adb in $ANDROID_HOME/platform-tools" >&2; exit 1; }

log "CLI and its Flutter"
if [[ -n ${E2E_FLUTTER_REVISION:-} ]]; then
  [[ $E2E_FLUTTER_REVISION =~ ^[0-9a-f]{40}$ ]] || { echo "E2E_FLUTTER_REVISION must be a full commit hash" >&2; exit 2; }
  echo "$E2E_FLUTTER_REVISION" >"$ROOT/bin/internal/flutter.version"
  echo "Flutter overridden to $E2E_FLUTTER_REVISION"
fi
SB=$ROOT/bin/shorebird
# Not SHOREBIRD_DOWNLOAD_URL: the CLI reads it as upstream's layout
# (<url>/shorebird/<engine>/...), which the mirror doesn't serve. The launcher
# falls back to SHOREBIRD_ARTIFACT_ORIGIN by itself.
"$SB" --version
FLUTTER_DIR=$ROOT/bin/cache/flutter/$(cat "$ROOT/bin/internal/flutter.version")
DART=$FLUTTER_DIR/bin/cache/dart-sdk/bin/dart

log "throwaway code_push_server"
(cd "$ROOT/packages/code_push_server" && "$DART" pub get >/dev/null)
# A port picked here can be taken by another job before the server binds it,
# so a server that exits early is started again on a new port.
for attempt in 1 2 3; do
  PORT=$(free_port)
  BASE=http://127.0.0.1:$PORT
  (
    cd "$ROOT/packages/code_push_server"
    API_KEY=$API_KEY URL_SIGNING_SECRET=$(openssl rand -hex 32) PORT=$PORT PUBLIC_BASE_URL=$BASE \
      DATA_DIR=$WORK/server-data \
      exec "$DART" run bin/server.dart
  ) >"$WORK/server.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 60); do
    curl -fsS --max-time 5 "$BASE/readyz" >/dev/null 2>&1 && break 2
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 2
  done
  kill "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=
  echo "the server did not come up on $PORT (attempt $attempt):" >&2
  tail -5 "$WORK/server.log" >&2
done
[[ -n $SERVER_PID ]] || { echo "giving up on the server" >&2; exit 1; }
echo "listening on $BASE"

log "app"
cd "$WORK"
FLUTTER_STORAGE_BASE_URL=$SHOREBIRD_ARTIFACT_ORIGIN "$FLUTTER_DIR/bin/flutter" create \
  --org dev.selfhost.e2e --project-name app --platforms android --empty app >"$WORK/create.log"
APP=$WORK/app
# The template's version, which `shorebird release` releases.
VERSION=$(sed -n 's/^version: *//p' "$APP/pubspec.yaml")
[[ -n $VERSION ]] || { echo "no version in the app's pubspec.yaml" >&2; exit 1; }
echo "void main() { print('SB-E2E-V1'); }" >"$APP/lib/main.dart"
app_json=$(curl -fsS --max-time 30 -X POST "$BASE/api/v1/apps" -H @- \
  -H 'Content-Type: application/json' -d '{"display_name":"android-pool-e2e"}' \
  <<<"Authorization: Bearer $API_KEY")
app_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$app_json")
printf 'app_id: %s\nbase_url: %s\n' "$app_id" "$BASE" >"$APP/shorebird.yaml"
python3 -I "$ROOT/selfhost/scripts/lib/add_shorebird_asset.py" "$APP/pubspec.yaml"
# Gradle and Kotlin in the build's own process: no daemon outlives the job, and
# none left by an earlier build (with another SDK path) serves this one. Set in
# the job's own Gradle user home, so it also covers Flutter's Gradle plugin,
# an included build that ignores the app's gradle.properties. A Kotlin daemon
# listens on 17001-18000, which ci-build's runner rules don't let a job reach on
# loopback: the plugin's compile waited 22 minutes for it before falling back.
export GRADLE_USER_HOME=$WORK/gradle-home
mkdir -p "$GRADLE_USER_HOME"
printf '%s\n' org.gradle.daemon=false kotlin.compiler.execution.strategy=in-process \
  >"$GRADLE_USER_HOME/gradle.properties"
# The app talks to the server over http://127.0.0.1 (adb reverse).
perl -pi -e 's/<application/<application android:usesCleartextTraffic="true"/' \
  "$APP/android/app/src/main/AndroidManifest.xml"
grep -q 'usesCleartextTraffic="true"' "$APP/android/app/src/main/AndroidManifest.xml"

export SHOREBIRD_HOSTED_URL=$BASE SHOREBIRD_TOKEN=$API_KEY
# Gradle ignores HTTPS_PROXY; hand it the job's proxy as Java properties.
if [[ ${HTTPS_PROXY:-} =~ ^https?://([^:/@]+):([0-9]+)/?$ ]]; then
  export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} -Dhttps.proxyHost=${BASH_REMATCH[1]} -Dhttps.proxyPort=${BASH_REMATCH[2]} -Dhttp.proxyHost=${BASH_REMATCH[1]} -Dhttp.proxyPort=${BASH_REMATCH[2]} -Dhttp.nonProxyHosts=localhost|127.*|10.0.2.2"
fi
cd "$APP"

# A new app's release manifest lacks the INTERNET permission the updater needs.
"$SB" doctor --fix
grep -q 'android.permission.INTERNET' android/app/src/main/AndroidManifest.xml

log "release $VERSION"
"$SB" release android --artifact apk --no-confirm

log "phone from the pool (owner $OWNER)"
# Short server-side waits (2 minutes, plus up to 3 while a stopped phone boots)
# in a loop: a job cancelled mid-request then leaves at most one wait's worth of
# orphaned checkout, and the release in cleanup (by owner) frees any lease that
# did land.
# Gives up after 15 minutes (a try started then can run 5 more), inside the
# job's 45-minute timeout.
lease=
deadline=$((SECONDS + 15 * 60))
while ((SECONDS < deadline)); do
  rc=0
  lease=$(curl -fsS --max-time 330 -X POST \
    "$POOL/checkout?owner=$OWNER&ttl=$CHECKOUT_TTL&wait=2&why=shorebird+android+e2e" 2>&1) || rc=$?
  ((rc == 0)) && break
  # 7: nothing listens, so waiting won't help.
  ((rc == 7)) && { echo "the device pool at $POOL is unreachable: $lease" >&2; exit 1; }
  echo "no free phone yet (curl exit $rc: $lease)"
  lease=
  sleep 10
done
[[ -n $lease ]] || { echo "no phone within 15 minutes" >&2; exit 1; }
read -r DEVICE SERIAL < <(python3 -c 'import json,sys; d = json.load(sys.stdin); print(d["device"], d["serial"])' <<<"$lease")
[[ -n ${SERIAL:-} ]] || { echo "unexpected checkout answer: $lease" >&2; exit 1; }
echo "checked out $DEVICE ($SERIAL)"
curl -fsS --max-time 15 -X POST "$POOL/renew?owner=$OWNER&ttl=$LEASE_TTL" >/dev/null

# Not adb's default 5037: ci-build's own adb server holds it, and a job may not
# reach it. Started right away, so the port can't be taken in between.
export ANDROID_ADB_SERVER_PORT
ANDROID_ADB_SERVER_PORT=$(free_port)
ADB_STARTED=1
timeout 30 adb start-server
connected=$(timeout 30 adb connect "$SERIAL" 2>&1) || true
echo "$connected"
[[ $connected == *"connected to"* ]] || { echo "adb could not connect to $SERIAL" >&2; exit 1; }
timeout 60 adb -s "$SERIAL" wait-for-device
booted=
for _ in $(seq 60); do
  booted=$(timeout 10 adb -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null) || true
  [[ ${booted//$'\r'/} == 1 ]] && break
  sleep 2
done
[[ ${booted//$'\r'/} == 1 ]] || { echo "$SERIAL did not finish booting" >&2; exit 1; }
timeout 30 adb -s "$SERIAL" shell getprop ro.product.cpu.abi
timeout 30 adb -s "$SERIAL" reverse "tcp:$PORT" "tcp:$PORT"

timeout 300 adb -s "$SERIAL" install -r build/app/outputs/flutter-apk/app-release.apk
launch
wait_log 'I flutter : SB-E2E-V1' "$LAUNCHED_AT" 60

log "patch 1"
echo "void main() { print('SB-E2E-V2'); }" >lib/main.dart
"$SB" patch android --release-version "$VERSION" --no-confirm
curl -fsS --max-time 15 -X POST "$POOL/renew?owner=$OWNER&ttl=$LEASE_TTL" >/dev/null

# This launch still runs the release and downloads the patch; the next one
# boots it.
launch
wait_log 'I flutter : SB-E2E-V1' "$LAUNCHED_AT" 60
wait_log 'Patch 1 successfully' "$LAUNCHED_AT" 120
launch
wait_log 'I flutter : SB-E2E-V2' "$LAUNCHED_AT" 60

log "PASS: the phone ran the release, downloaded patch 1 and booted it"
