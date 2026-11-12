#!/usr/bin/env bash
# cspell:words Dhttp Dhttps getprop getsockname nullglob genrsa pubout pidof
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
#   E2E_SCENARIOS               quick (default): release, patch 1, patched boot.
#                               full: also consecutive patches, rollback, version
#                               targeting, signing, a refused native change and
#                               a server outage, each asserted from the device
#                               log, the server API or the CLI's exit code.
#
# Needs adb, java, curl, python3, openssl and timeout on PATH. Exits non-zero,
# with the server log, the device log and the pool's lease, on any failure.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
POOL=${QA_POOL_URL:-http://127.0.0.1:5550}
export SHOREBIRD_ARTIFACT_ORIGIN=${SHOREBIRD_ARTIFACT_ORIGIN:-http://127.0.0.1:8085}
SCENARIOS=${E2E_SCENARIOS:-quick}
[[ $SCENARIOS == quick || $SCENARIOS == full ]] || { echo "E2E_SCENARIOS must be quick or full" >&2; exit 2; }
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
ARCH=
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

renew() { curl -fsS --max-time 15 -X POST "$POOL/renew?owner=$OWNER&ttl=$LEASE_TTL" >/dev/null; }

# Cold-starts the app, waits for the Dart line $1 and for the updater's update
# thread to finish (so a download or a rollback has happened), and keeps the
# launch's device log in BOOT_LOG for has and lacks. The wait for the update
# thread also bounds a server that hangs.
BOOT_LOG=
boot() {
  renew
  launch
  wait_log "$1" "$LAUNCHED_AT" 60
  wait_log 'Update thread finished with status' "$LAUNCHED_AT" 120
  BOOT_LOG=$(timeout 30 adb -s "$SERIAL" logcat -d -T "$LAUNCHED_AT.000" 2>/dev/null) || true
}
# What the launch's log must, or must not, hold.
has() {
  grep -qE "$1" <<<"$BOOT_LOG" && { echo "ok: log has '$1'"; return 0; }
  echo "FAIL: no line matching '$1' in this launch's log" >&2
  grep -E 'flutter|shorebird' <<<"$BOOT_LOG" | tail -40 >&2
  return 1
}
lacks() {
  grep -qE "$1" <<<"$BOOT_LOG" || { echo "ok: log has no '$1'"; return 0; }
  echo "FAIL: found a line matching '$1' in this launch's log" >&2
  grep -E "$1" <<<"$BOOT_LOG" | tail -10 >&2
  return 1
}
# The next launch boots what the last one downloaded.
expect_equal() {
  [[ $1 == "$2" ]] && { echo "ok: $3: $1"; return 0; }
  echo "FAIL: $3: got '$1', want '$2'" >&2
  return 1
}

# The server's own answer to the device's patch check ($1 release version, $2
# the patch the device runs): "<patch number or none> <rolled back numbers>".
patch_check() {
  local out
  out=$(curl -fsS --max-time 15 -X POST "$BASE/api/v1/patches/check" -H 'Content-Type: application/json' \
    -d "{\"app_id\":\"$app_id\",\"release_version\":\"$1\",\"platform\":\"android\",\"arch\":\"$ARCH\",\"channel\":\"stable\",\"client_id\":\"e2e-probe\",\"current_patch_number\":$2}")
  python3 -c 'import json,sys; d = json.load(sys.stdin); p = d.get("patch"); print(p["number"] if p else "none", d.get("rolled_back_patch_numbers"))' <<<"$out"
}
api() { curl -fsS --max-time 30 -H "Authorization: Bearer $API_KEY" "$@"; }
# The patch numbers the server holds for release version $1, e.g. "1 2".
server_patches() {
  local rid
  rid=$(api "$BASE/api/v1/apps/$app_id/releases" |
    python3 -c 'import json,sys; v = sys.argv[1]; print(next(r["id"] for r in json.load(sys.stdin)["releases"] if r["version"] == v))' "$1")
  api "$BASE/api/v1/apps/$app_id/releases/$rid/patches" |
    python3 -c 'import json,sys; print(" ".join(str(p["number"]) for p in sorted(json.load(sys.stdin)["patches"], key=lambda p: p["number"])))'
}
# Runs a CLI command that must fail; its output goes to OUT, its exit code to RC.
OUT=
RC=0
must_fail() {
  RC=0
  OUT=$("$@" 2>&1) || RC=$?
  printf '%s\n' "$OUT" | tail -15
  ((RC != 0)) || { echo "FAIL: '$*' exited 0" >&2; return 1; }
  echo "ok: exit $RC"
}
# The app's Dart source: a line to print and, when $2 is given, a class and a
# function with real logic behind it.
write_main() {
  cat >"$APP/lib/main.dart" <<DART
class Greeter {
  const Greeter(this.tag);
  final String tag;
  String greet(int n) => '\$tag-\${_fib(n)}';
}

int _fib(int n) => n < 2 ? n : _fib(n - 1) + _fib(n - 2);

void main() {
  print('$1:\${const Greeter('g').greet($2)}');
}
DART
}
# Releases the app as version $1 with its main.dart as written, and keeps the APK.
release_apk() {
  perl -pi -e "s/^version: .*/version: $1/" "$APP/pubspec.yaml"
  "$SB" release android --artifact apk --no-confirm "${@:3}"
  cp "$APP/build/app/outputs/flutter-apk/app-release.apk" "$WORK/$2.apk"
}
# Installs a kept APK fresh (the old app's updater state goes with it).
install_apk() {
  timeout 60 adb -s "$SERIAL" uninstall "$PKG" >/dev/null 2>&1 || true
  timeout 300 adb -s "$SERIAL" install -r "$WORK/$1.apk"
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
URL_SECRET=$(openssl rand -hex 32)
PORT=
# Starts the server and waits for it. Without a port it picks one; a port picked
# here can be taken by another job before the server binds it, so a server that
# exits early is started again on a new port. With a port (a restart) it keeps
# it, because the app's base_url names it.
start_server() {
  local attempt keep=${PORT:-}
  for attempt in 1 2 3; do
    [[ -n $keep ]] || PORT=$(free_port)
    BASE=http://127.0.0.1:$PORT
    (
      cd "$ROOT/packages/code_push_server"
      API_KEY=$API_KEY URL_SIGNING_SECRET=$URL_SECRET PORT=$PORT PUBLIC_BASE_URL=$BASE \
        DATA_DIR=$WORK/server-data \
        exec "$DART" run bin/server.dart
    ) >>"$WORK/server.log" 2>&1 &
    SERVER_PID=$!
    for _ in $(seq 60); do
      curl -fsS --max-time 5 "$BASE/readyz" >/dev/null 2>&1 && return 0
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 2
    done
    kill "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=
    echo "the server did not come up on $PORT (attempt $attempt):" >&2
    tail -5 "$WORK/server.log" >&2
  done
  echo "giving up on the server" >&2
  return 1
}
start_server
echo "listening on $BASE"

log "app"
cd "$WORK"
FLUTTER_STORAGE_BASE_URL=$SHOREBIRD_ARTIFACT_ORIGIN "$FLUTTER_DIR/bin/flutter" create \
  --org dev.selfhost.e2e --project-name app --platforms android --empty app >"$WORK/create.log"
APP=$WORK/app
# The version `shorebird release` releases.
perl -pi -e 's/^version: .*/version: 0.1.0+1/' "$APP/pubspec.yaml"
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
# none left by an earlier build (with another SDK path) serves this one.
printf '%s\n' org.gradle.daemon=false kotlin.compiler.execution.strategy=in-process \
  >>"$APP/android/gradle.properties"
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

if [[ $SCENARIOS == full ]]; then
  cp build/app/outputs/flutter-apk/app-release.apk "$WORK/v1.apk"
  # Everything that needs only the CLI and the server runs before the phone is
  # checked out.
  log "scenario 7: a native change is refused, and nothing is published"
  KT=$(find android/app/src/main -name MainActivity.kt)
  [[ -n $KT ]] || { echo "no MainActivity.kt" >&2; exit 1; }
  cp "$KT" "$WORK/MainActivity.kt.orig"
  perl -0pi -e 's/class MainActivity *: *FlutterActivity\(\)/class MainActivity : FlutterActivity() {\n    override fun onCreate(savedInstanceState: android.os.Bundle?) {\n        android.util.Log.i("SB-E2E-NATIVE", "native change")\n        super.onCreate(savedInstanceState)\n    }\n}/' "$KT"
  grep -q SB-E2E-NATIVE "$KT"
  before=$(server_patches "$VERSION")
  must_fail "$SB" patch android --release-version "$VERSION" --no-confirm
  grep -q 'Not publishing' <<<"$OUT" || { echo "FAIL: no 'Not publishing' message" >&2; exit 1; }
  after=$(server_patches "$VERSION")
  expect_equal "$after" "$before" "the server's patches for $VERSION after the refused native patch"
  cp "$WORK/MainActivity.kt.orig" "$KT"

  log "release 0.2.0+2 (W1) and a signed release 0.3.0+3 (S1)"
  write_main SB-E2E-W1 10
  release_apk 0.2.0+2 v2
  mkdir "$WORK/keys"
  for k in good other; do
    openssl genrsa -out "$WORK/keys/$k.pem" 2048 2>/dev/null
    openssl rsa -in "$WORK/keys/$k.pem" -pubout -out "$WORK/keys/$k.pub.pem" 2>/dev/null
  done
  write_main SB-E2E-S1 10
  release_apk 0.3.0+3 v3 --public-key-path "$WORK/keys/good.pub.pem"
  grep -rq . "$WORK/keys/good.pub.pem"
fi

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
ABI=$(timeout 30 adb -s "$SERIAL" shell getprop ro.product.cpu.abi)
ABI=${ABI//$'\r'/}
echo "$ABI"
case $ABI in
  arm64-v8a) ARCH=aarch64 ;;
  armeabi-v7a) ARCH=arm ;;
  x86_64 | x86) ARCH=$ABI ;;
  *) echo "unknown ABI $ABI" >&2; exit 1 ;;
esac
timeout 30 adb -s "$SERIAL" reverse "tcp:$PORT" "tcp:$PORT"

# In full mode the build directory holds the last release built, not 0.1.0+1.
FIRST_APK=build/app/outputs/flutter-apk/app-release.apk
[[ $SCENARIOS == full ]] && FIRST_APK=$WORK/v1.apk
timeout 300 adb -s "$SERIAL" install -r "$FIRST_APK"
launch
wait_log 'I flutter : SB-E2E-V1' "$LAUNCHED_AT" 60

log "patch 1"
if [[ $SCENARIOS == full ]]; then
  # A new class and function and different logic, not just another string.
  write_main SB-E2E-V2 10
else
  echo "void main() { print('SB-E2E-V2'); }" >lib/main.dart
fi
"$SB" patch android --release-version "$VERSION" --no-confirm
curl -fsS --max-time 15 -X POST "$POOL/renew?owner=$OWNER&ttl=$LEASE_TTL" >/dev/null

# This launch still runs the release and downloads the patch; the next one
# boots it.
launch
wait_log 'I flutter : SB-E2E-V1' "$LAUNCHED_AT" 60
wait_log 'Patch 1 successfully' "$LAUNCHED_AT" 120
launch
wait_log 'I flutter : SB-E2E-V2' "$LAUNCHED_AT" 60

log "PASS (quick): the phone ran the release, downloaded patch 1 and booted it"
[[ $SCENARIOS == full ]] || exit 0


# ---- E2E_SCENARIOS=full ----
sb_patch() { # $1 release version, then the patch command's own flags
  renew
  local v=$1
  shift
  "$SB" patch android --release-version "$v" --no-confirm "$@"
  renew
}
PASSED=()
pass() { PASSED+=("$1"); log "SCENARIO OK: $1"; }
V1_VERSION=$VERSION # 0.1.0+1

log "scenario 2: patch 1 is a real Dart change (a class, a function, other logic)"
boot 'I flutter : SB-E2E-V2:g-55'
has 'Prepared boot of patch 1'
expect_equal "$(server_patches "$V1_VERSION")" "1" "patches on $V1_VERSION"
pass "patch 1 runs: V2 with the new class and function"

log "scenario 3: patch 2, consecutive"
write_main SB-E2E-V3 12
sb_patch "$V1_VERSION"
boot 'I flutter : SB-E2E-V2:g-55'
has 'Patch 2 successfully downloaded'
boot 'I flutter : SB-E2E-V3:g-144'
has 'Prepared boot of patch 2'
expect_equal "$(server_patches "$V1_VERSION")" "1 2" "patches on $V1_VERSION"
pass "patch 2 runs: V3, after V2"

log "scenario 4: roll back patch 2"
# From the updater: the patch check lists rolled_back_patch_numbers, the updater
# uninstalls those patches (roll_back_patches_if_needed) but the running process
# keeps its patch (running_patch), so the launch that learns of the rollback
# still prints V3 and the next boots without it. The server supersedes patch 1
# when patch 2 is promoted, and the device deleted patch 1 when patch 2 booted
# (cleanup_older_than), so with patch 2 gone nothing is left: the base release.
renew
"$SB" patches rollback --release-version "$V1_VERSION" --patch-number 2
expect_equal "$(patch_check "$V1_VERSION" 2)" "none [2]" "the server's patch check for a device on patch 2"
boot 'I flutter : SB-E2E-V3:g-144'
has 'rolled_back_patch_numbers: Some\(\[2'
boot 'I flutter : SB-E2E-V1'
has 'Prepared boot of the base release'
lacks 'SB-E2E-V[23]'
pass "patch 2 rolled back: the device is on the base release, V1"

log "scenario 4b: rolling back patch 1 (superseded by patch 2, so not live)"
must_fail "$SB" patches rollback --release-version "$V1_VERSION" --patch-number 1
expect_equal "$(server_patches "$V1_VERSION")" "1 2" "patches on $V1_VERSION"
boot 'I flutter : SB-E2E-V1'
has 'Prepared boot of the base release'
pass "patch 1 cannot be rolled back once superseded; the device stays on V1"

log "scenario 5: version targeting"
write_main SB-E2E-V4 14
sb_patch "$V1_VERSION"
expect_equal "$(server_patches "$V1_VERSION")" "1 2 3" "patches on $V1_VERSION"
expect_equal "$(patch_check "$V1_VERSION" 0)" "3 [2]" "the server offers patch 3 to $V1_VERSION"
install_apk v2
boot 'I flutter : SB-E2E-W1:g-55'
expect_equal "$(patch_check 0.2.0+2 0)" "none []" "the server's patch check for 0.2.0+2"
lacks 'Prepared boot of patch|successfully downloaded|SB-E2E-V'
boot 'I flutter : SB-E2E-W1:g-55'
lacks 'Prepared boot of patch|successfully downloaded|SB-E2E-V'
write_main SB-E2E-W2 11
sb_patch 0.2.0+2
expect_equal "$(patch_check 0.2.0+2 0)" "1 []" "the server offers patch 1 to 0.2.0+2"
boot 'I flutter : SB-E2E-W1:g-55'
has 'Patch 1 successfully downloaded'
boot 'I flutter : SB-E2E-W2:g-89'
has 'Prepared boot of patch 1'
pass "0.2.0+2 ignored the patch for $V1_VERSION and took its own: W2"

log "scenario 4c: rolling back the only patch restores the release"
renew
"$SB" patches rollback --release-version 0.2.0+2 --patch-number 1
expect_equal "$(patch_check 0.2.0+2 1)" "none [1]" "the server's patch check for a device on patch 1"
boot 'I flutter : SB-E2E-W2:g-89'
has 'rolled_back_patch_numbers: Some\(\[1'
boot 'I flutter : SB-E2E-W1:g-55'
has 'Prepared boot of the base release'
lacks 'SB-E2E-W2'
pass "the only patch rolled back: the device is back on W1"

log "scenario 6: signing"
install_apk v3
boot 'I flutter : SB-E2E-S1:g-55'
write_main SB-E2E-S2 11
sb_patch 0.3.0+3 --public-key-path "$WORK/keys/good.pub.pem" --private-key-path "$WORK/keys/good.pem"
boot 'I flutter : SB-E2E-S1:g-55'
has 'Patch 1 successfully downloaded'
boot 'I flutter : SB-E2E-S2:g-89'
has 'Prepared boot of patch 1'
lacks 'No public key configured'
pass "a patch signed with the release's key boots (verified, not skipped)"
write_main SB-E2E-S3 12
rc=0
sb_patch 0.3.0+3 --public-key-path "$WORK/keys/other.pub.pem" --private-key-path "$WORK/keys/other.pem" \
  >"$WORK/badsig-patch.log" 2>&1 || rc=$?
tail -15 "$WORK/badsig-patch.log"
if ((rc != 0)); then
  echo "the CLI refused the patch signed with another key (exit $rc), before publication"
  expect_equal "$(server_patches 0.3.0+3)" "1" "patches on 0.3.0+3"
  boot 'I flutter : SB-E2E-S2:g-89'
  pass "a patch signed with another key was refused before publication; the app runs S2"
else
  echo "the CLI and the server accepted the patch signed with another key; the device must refuse it"
  boot 'I flutter : SB-E2E-S2:g-89'
  first=$BOOT_LOG
  boot 'I flutter : SB-E2E-S2:g-89'
  BOOT_LOG=$first$'\n'$BOOT_LOG
  has 'Patch 2 failed validation'
  lacks 'SB-E2E-S3'
  boot 'I flutter : SB-E2E-S2:g-89'
  lacks 'SB-E2E-S3'
  pass "a patch signed with another key was rejected on the device; the app keeps running S2"
fi

log "scenario 8: the server is unavailable"
install_apk v2
boot 'I flutter : SB-E2E-W1:g-55'
kill "$SERVER_PID"
pkill -P "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=
if curl -fsS --max-time 5 "$BASE/readyz" >/dev/null 2>&1; then echo "FAIL: the server still answers" >&2; exit 1; fi
boot 'I flutter : SB-E2E-W1:g-55'
lacks 'FATAL EXCEPTION'
alive=$(timeout 30 adb -s "$SERIAL" shell pidof "$PKG") || true
[[ -n ${alive//$'\r'/} ]] || { echo "FAIL: the app is not running with the server down" >&2; exit 1; }
echo "ok: the app runs (pid ${alive//$'\r'/}) with the server down"
grep -E 'Update (failed|thread finished)' <<<"$BOOT_LOG" | tail -3
start_server
curl -fsS --max-time 5 "$BASE/readyz" >/dev/null
expect_equal "$(patch_check 0.2.0+2 0)" "none [1]" "the restarted server's patch check"
write_main SB-E2E-W3 12
sb_patch 0.2.0+2
boot 'I flutter : SB-E2E-W1:g-55'
has 'Patch 2 successfully downloaded'
boot 'I flutter : SB-E2E-W3:g-144'
pass "the app ran its code with the server down; the restarted server serves again (W3)"

log "PASS (full): $(printf '%s; ' "${PASSED[@]}")"
