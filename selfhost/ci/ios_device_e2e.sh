#!/usr/bin/env bash
# cspell:words Podfile Pods ipconfig idevicesyslog idevicedebug nehelper pbxproj nostart appexs execvp setsid APPV APPW CONNREC NLAUNCH SCEN connrec fetchone fibv yamlof
# The iOS counterpart of android_pool_e2e.sh E2E_SCENARIOS=full: releases and
# patches (Route B) two iOS apps with this checkout's CLI, against a throwaway
# self-hosted code_push_server on the LAN, on a physical iPhone, and asserts each
# scenario from the device's syslog, the server's API and the CLI's exit codes.
#
#   E2E_WORK=/tmp/ios-e2e selfhost/ci/ios_device_e2e.sh            # phase 1
#   (a person taps OK on the Local Network prompt of both apps)
#   E2E_WORK=/tmp/ios-e2e selfhost/ci/ios_device_e2e.sh --resume   # phase 2
#
# Why two phases. Every fresh install of an iOS app needs a human tap on the
# "Local Network" prompt before it can reach a server on the LAN, and any
# reinstall resets the grant. So phase 1 builds BOTH releases, runs the scenario
# that needs no phone (refused patches), installs both apps once, launches each
# so the prompt appears, leaves the server running and exits 3 with
# "ready for taps: ...". After the taps, --resume (or E2E_PHASE=after-install)
# runs every scenario with patches only; nothing is reinstalled again.
#
# The two releases (same Shorebird app_id, one bundle id each, never one build
# re-signed under two ids: iOS keys the grant on the executable):
#   V  1.0.0+1  unsigned   dev.selfhost.e2ev   markers V*
#   W  2.0.0+2  signed     dev.selfhost.e2ew   markers W*   (--public-key-path)
#
# Route B patches change the BODIES of existing reachable functions and cannot
# add a member something references, so the app has three such functions
# (marker, arg, fib) and each patch changes real logic in them, never a new member.
#
# Settings (environment):
#   E2E_WORK              scratch directory, required (state lives there; the
#                         script wipes it in phase 1)
#   E2E_UDID              the iPhone's UDID, required
#   E2E_HOST_IP           the Mac's LAN address the phone reaches, default en0's
#   E2E_PORT              the server's port, default 18090
#   E2E_CLI               the CLI checkout (it also supplies the server, the
#                         resign script and its Flutter), default this checkout
#   E2E_IDENTITY          codesign identity (SHA-1), required
#   E2E_PROFILE           provisioning profile (.mobileprovision), required
#   E2E_TEAM              team id, required
#   E2E_ARTIFACT_ORIGIN   the CDN mirror (SHOREBIRD_ARTIFACT_ORIGIN), required
#                         unless E2E_ARTIFACT_UPSTREAM is set
#   E2E_ARTIFACT_UPSTREAM when set, a recording origin (:18085) is started in
#                         front of it, and a CONNECT recorder (:18088) for the
#                         toolchain's outbound hosts; their jsonl go to the evidence
#   E2E_EVIDENCE          where launch logs and CLI outputs go, default
#                         $E2E_WORK/evidence
#   E2E_PHASE             after-install, the same as --resume
#   E2E_FROM              with --resume, skip scenarios before this number (a
#                         resume after a failure; the skipped ones are NOT
#                         re-checked and passed.txt says so)
#
# Needs python3, curl, openssl, ios-deploy, idevicesyslog and idevicedebug
# (libimobiledevice, /opt/homebrew/bin), and a mounted developer disk image.
# Exits 3 at the tap pause, non-zero with the tails of the logs on a failure.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export PATH=/opt/homebrew/bin:$PATH
PHASE=install
[[ ${1:-} == --resume ]] && PHASE=after-install
[[ ${E2E_PHASE:-} == after-install ]] && PHASE=after-install
[[ ${E2E_PHASE:-} == rebuild-w ]] && PHASE=rebuild-w
WORK=${E2E_WORK:?set E2E_WORK}
# Phase 1 wipes it: refuse anything that isn't plainly a scratch directory.
case $WORK in
  /* ) ;;
  * ) echo "E2E_WORK must be an absolute path: $WORK" >&2; exit 2 ;;
esac
case ${WORK%/} in
  "" | "$HOME" | /Users | /home | /tmp | /private/tmp | /var | /private/var) echo "refusing E2E_WORK=$WORK: phase 1 deletes it" >&2; exit 2 ;;
esac
UDID=${E2E_UDID:?set E2E_UDID}
CLI=${E2E_CLI:-$ROOT}
IDENTITY=${E2E_IDENTITY:?set E2E_IDENTITY}
PROFILE=${E2E_PROFILE:?set E2E_PROFILE}
TEAM=${E2E_TEAM:?set E2E_TEAM}
HOST_IP=${E2E_HOST_IP:-$(ipconfig getifaddr en0)}
PORT=${E2E_PORT:-18090}
EVID=${E2E_EVIDENCE:-$WORK/evidence}
SYSLOG=$WORK/syslog.txt
STATE=$WORK/state.env
BUNDLE_V=dev.selfhost.e2ev
BUNDLE_W=dev.selfhost.e2ew
VER_V=1.0.0+1
VER_W=${E2E_VER_W:-2.0.0+2}
ARCH=aarch64
APPV=$WORK/e2ev
APPW=$WORK/e2ew
KEEP_RUNNING=
SERVER_PID=
SYSLOG_PID=
ORIGIN_PID=
CONNREC_PID=
DBG_PID=
SCEN=setup
NLAUNCH=0

log() { printf '\n=== %s\n' "$*"; SCEN=$(tr -c 'A-Za-z0-9' '_' <<<"$1" | cut -c1-40); }
die() { echo "FAIL: $*" >&2; exit 1; }

# Starts "$@" detached in its own process group, output to $1; sets SPAWNED.
# (macOS has no setsid(1).) Called directly, not in $(...).
SPAWNED=
spawn() {
  local out=$1
  shift
  python3 -I -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@" >>"$out" 2>&1 </dev/null &
  SPAWNED=$!
}
stop_group() { # pid
  local pid=${1:-} i
  [[ -n $pid ]] || return 0
  kill -TERM -- "-$pid" 2>/dev/null || true
  for i in $(seq 20); do
    kill -0 -- "-$pid" 2>/dev/null || break
    sleep 0.5
    if ((i == 20)); then kill -KILL -- "-$pid" 2>/dev/null || true; fi
  done
  wait "$pid" 2>/dev/null || true
}
stop_server() { stop_group "$SERVER_PID"; SERVER_PID=; save_state; }
stop_app() {
  pkill -f "idevicedebug -u $UDID run dev.selfhost.e2e" 2>/dev/null || true
  idevicedebug -u "$UDID" kill "${BUNDLE:-$BUNDLE_V}" >/dev/null 2>&1 || true
  DBG_PID=
  sleep 3
}

save_state() {
  [[ -d $WORK ]] || return 0
  {
    printf 'export API_KEY=%q URL_SECRET=%q app_id=%q\n' "${API_KEY:-}" "${URL_SECRET:-}" "${app_id:-}"
    printf 'SERVER_PID=%q SYSLOG_PID=%q ORIGIN_PID=%q CONNREC_PID=%q\n' "$SERVER_PID" "$SYSLOG_PID" "$ORIGIN_PID" "$CONNREC_PID"
    printf 'PRIVATE_ENV_SAVED=1\n'
  } >"$STATE"
  chmod 600 "$STATE"
}

cleanup() {
  local status=$?
  set +e
  if [[ -n $KEEP_RUNNING ]]; then exit "$status"; fi
  if ((status != 0)); then
    log "FAILED (exit $status); server log tail"
    tail -30 "$WORK/server.log" 2>/dev/null
    echo "--- last device lines"
    grep -a 'Runner(Flutter)' "$SYSLOG" 2>/dev/null | tail -25
  fi
  pkill -f "idevicedebug -u $UDID run dev.selfhost.e2e" 2>/dev/null
  stop_group "$SERVER_PID"
  stop_group "$ORIGIN_PID"
  stop_group "$CONNREC_PID"
  stop_group "$SYSLOG_PID"
  ((status == 0)) && rm -rf "$WORK/keys"
  exit "$status"
}
trap cleanup EXIT

# ---- the app's Dart source ----
# $1 dir, $2 tag, $3 fib argument, $4 rec|iter (the body of fib), $5 "extra" to
# add a referenced member (which Route B refuses).
write_main() {
  local dir=$1 tag=$2 arg=$3 fibv=$4 extra=${5:-} fib marker_expr
  if [[ $fibv == rec ]]; then
    fib='int fib(int n) => n < 2 ? n : fib(n - 1) + fib(n - 2);'
  else
    fib='int fib(int n) {
  var a = 0, b = 1;
  for (var i = 0; i < n; i++) {
    final t = a + b;
    a = b;
    b = t;
  }
  return a;
}'
  fi
  marker_expr="'$tag'"
  [[ -n $extra ]] && marker_expr="'$tag' + extra()"
  {
    echo "import 'package:flutter/material.dart';"
    echo
    cat <<DART
@pragma('vm:never-inline')
@pragma('vm:entry-point')
String marker() => DateTime.now().millisecondsSinceEpoch >= 0 ? $marker_expr : '$tag!';

@pragma('vm:never-inline')
@pragma('vm:entry-point')
int arg() => DateTime.now().millisecondsSinceEpoch >= 0 ? $arg : 0;

@pragma('vm:never-inline')
@pragma('vm:entry-point')
$fib

DART
    if [[ -n $extra ]]; then
      printf "@pragma('vm:never-inline')\n@pragma('vm:entry-point')\nString extra() => 'added';\n\n"
    fi
    cat <<'DART'
void main() {
  debugPrint('E2E-MARKER ' + marker() + ':g-' + fib(arg()).toString());
  runApp(const MarkerApp());
}

class MarkerApp extends StatelessWidget {
  const MarkerApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: Text(marker(), style: const TextStyle(fontSize: 30)),
      ),
    ),
  );
}
DART
  } >"$dir/lib/main.dart"
}

# ---- CLI wrappers; every output is kept as evidence ----
CLI_OUT=
cli() { # name, then the command
  local name=$1 rc=0
  shift
  mkdir -p "$EVID/cli"
  set +e
  "$@" 2>&1 | tee "$EVID/cli/$name.txt"
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}
OUT=
RC=0
must_fail() { # name, rc, text, command
  local name=$1 want_rc=$2 want_text=$3
  shift 3
  RC=0
  mkdir -p "$EVID/cli"
  OUT=$("$@" 2>&1) || RC=$?
  printf '%s\n' "$OUT" >"$EVID/cli/$name.txt"
  printf '%s\n' "$OUT" | tail -15
  [[ $RC == "$want_rc" ]] || { echo "FAIL: '$*' exited $RC, want $want_rc" >&2; return 1; }
  grep -qF -- "$want_text" <<<"$OUT" || { echo "FAIL: no '$want_text' in the output of '$*'" >&2; return 1; }
  echo "ok: exit $RC with '$want_text'"
}
expect_equal() {
  [[ $1 == "$2" ]] && { echo "ok: $3: $1"; return 0; }
  echo "FAIL: $3: got '$1', want '$2'" >&2
  return 1
}

# ---- server state (the same helpers as the Android script) ----
api() { curl -fsS --max-time 30 -H "Authorization: Bearer $API_KEY" "$@"; }
patch_body() { # release version, current patch, client id
  printf '{"app_id":"%s","release_version":"%s","platform":"ios","arch":"%s","channel":"stable","client_id":"%s","current_patch_number":%s}' \
    "$app_id" "$1" "$ARCH" "${3:-e2e-probe}" "$2"
}
patch_check() { # "<patch number or none> <rolled back numbers>"
  local out
  out=$(curl -fsS --max-time 15 -X POST "$BASE/api/v1/patches/check" -H 'Content-Type: application/json' -d "$(patch_body "$1" "$2" "${3:-}")")
  python3 -c 'import json,sys; d = json.load(sys.stdin); p = d.get("patch"); print(p["number"] if p else "none", d.get("rolled_back_patch_numbers"))' <<<"$out"
}
patch_artifact_sha() {
  local url
  url=$(curl -fsS --max-time 15 -X POST "$BASE/api/v1/patches/check" -H 'Content-Type: application/json' -d "$(patch_body "$1" "$2")" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["patch"]["download_url"])')
  curl -fsS --max-time 60 "$url" | shasum -a 256 | cut -d' ' -f1
}
release_id_of() {
  api "$BASE/api/v1/apps/$app_id/releases" |
    python3 -c 'import json,sys; v = sys.argv[1]; print(next(r["id"] for r in json.load(sys.stdin)["releases"] if r["version"] == v))' "$1"
}
server_patches() {
  api "$BASE/api/v1/apps/$app_id/releases/$(release_id_of "$1")/patches" |
    python3 -c 'import json,sys; print(" ".join(str(p["number"]) for p in sorted(json.load(sys.stdin)["patches"], key=lambda p: p["number"])))'
}
server_releases() {
  api "$BASE/api/v1/apps/$app_id/releases" |
    python3 -c 'import json,sys; print(" ".join(sorted(r["version"] for r in json.load(sys.stdin)["releases"])))'
}
patch_id_of() {
  api "$BASE/api/v1/apps/$app_id/releases/$(release_id_of "$1")/patches" |
    python3 -c 'import json,sys; n = int(sys.argv[1]); print(next(p["id"] for p in json.load(sys.stdin)["patches"] if p["number"] == n))' "$2"
}
bucket_of() { # app channel patch client
  python3 -I -c 'import hashlib,sys; d = hashlib.sha256(":".join(sys.argv[1:5]).encode()).digest(); print((int.from_bytes(d[:4], "big") & 0x7fffffff) % 10000)' "$@"
}
device_client_id() { # release version
  local cid='' i
  for i in $(seq 30); do
    cid=$(python3 -I - "$WORK/server-data/code_push.db" "$app_id" "$1" <<'PY' || true
import sqlite3, sys
db = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True, timeout=10)
row = db.execute("SELECT client_id FROM events WHERE app_id = ? AND release_version = ? "
                 "AND client_id IS NOT NULL AND client_id != '' ORDER BY id DESC LIMIT 1",
                 (sys.argv[2], sys.argv[3])).fetchone()
print(row[0] if row else "")
PY
)
    [[ -n $cid ]] && break
    sleep 2
  done
  [[ -n $cid ]] || { echo "no event from the phone with a client_id for $1" >&2; return 1; }
  printf '%s\n' "$cid"
}

start_server() {
  local i
  BASE=http://$HOST_IP:$PORT
  spawn "$WORK/server.log" env API_KEY="$API_KEY" URL_SIGNING_SECRET="$URL_SECRET" PORT="$PORT" \
    PUBLIC_BASE_URL="$BASE" DATA_DIR="$WORK/server-data" \
    bash -c 'cd "$1" && exec "$2" run bin/server.dart' _ "$CLI/packages/code_push_server" "$DART"
  SERVER_PID=$SPAWNED
  save_state
  for i in $(seq 60); do
    curl -fsS --max-time 5 "$BASE/readyz" >/dev/null 2>&1 && return 0
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 2
  done
  tail -5 "$WORK/server.log" >&2
  die "the server did not come up on $PORT"
}

# ---- the device ----
BUNDLE=$BUNDLE_V
APP=$APPV
VERSION=$VER_V
use() { # V | W
  if [[ $1 == V ]]; then BUNDLE=$BUNDLE_V APP=$APPV VERSION=$VER_V; else BUNDLE=$BUNDLE_W APP=$APPW VERSION=$VER_W; fi
}
slice() { tail -c +$((SYS_OFF + 1)) "$SYSLOG" | grep -a 'Runner(Flutter)' || true; }
SYS_OFF=0
KEEP_OTHERS=
launch() {
  [[ -n $KEEP_OTHERS ]] || stop_app
  SYS_OFF=$(stat -f %z "$SYSLOG")
  spawn "$WORK/dbg.txt" idevicedebug -u "$UDID" run "$BUNDLE"
  DBG_PID=$SPAWNED
}
# Waits up to $2 seconds for the launch's log to show $1. Returns 3 when the
# launch's process ended first (the app disappeared) and the line is not there.
wait_log() {
  local pattern=$1 limit=$2 start=$SECONDS out
  while :; do
    out=$(slice)
    if grep -qE -- "$pattern" <<<"$out"; then echo "seen: $pattern"; return 0; fi
    if ! kill -0 "$DBG_PID" 2>/dev/null; then
      out=$(slice)
      grep -qE -- "$pattern" <<<"$out" && { echo "seen: $pattern"; return 0; }
      echo "the app's process ended before '$pattern' appeared" >&2
      return 3
    fi
    if ((SECONDS - start > limit)); then echo "no device log line matching '$pattern' within ${limit}s" >&2; return 1; fi
    sleep 3
  done
}
BOOT_LOG=
DISAPPEARANCES=0
# Cold-starts the app, waits for the Dart marker line $1 and for the update
# thread to finish (a download or a rollback has happened), and keeps the
# launch's log in BOOT_LOG. A launch whose process vanished before that is
# recorded and tried once more (the known "launch disappearance on first
# activation of a newly installed patch"); a second one fails the run.
boot() {
  local try rc
  for try in 1 2; do
    launch
    rc=0
    wait_log "$1" 60 && wait_log 'Update thread finished with status' 120 || rc=$?
    if ((rc == 0)); then break; fi
    if ((rc == 3 && try == 1)); then
      DISAPPEARANCES=$((DISAPPEARANCES + 1))
      echo "LAUNCH DISAPPEARANCE #$DISAPPEARANCES in $SCEN (waiting for '$1'); relaunching" | tee -a "$EVID/disappearances.txt"
      slice | sed -E 's/^.*Runner\(Flutter\)\[[0-9]+\] <[A-Za-z]+>: //' >>"$EVID/disappearances.txt"
      continue
    fi
    die "boot of $BUNDLE: '$1' not seen (rc $rc)"
  done
  BOOT_LOG=$(slice)
  NLAUNCH=$((NLAUNCH + 1))
  mkdir -p "$EVID/launches"
  printf '%s\n' "$BOOT_LOG" | sed -E 's/^.*Runner\(Flutter\)\[[0-9]+\] <[A-Za-z]+>: //' \
    >"$EVID/launches/$(printf %02d "$NLAUNCH")_${BUNDLE##*.}_${SCEN}.txt"
}
has() { wait_log "$1" 30; }
lacks() {
  BOOT_LOG=$(slice)
  grep -qE -- "$1" <<<"$BOOT_LOG" || { echo "ok: log has no '$1'"; return 0; }
  echo "FAIL: found a line matching '$1' in this launch's log" >&2
  grep -E -- "$1" <<<"$BOOT_LOG" | tail -10 >&2
  return 1
}
PASSED=()
pass() { PASSED+=("$1"); echo "$1" >>"$EVID/passed.txt"; echo "=== SCENARIO OK: $1"; }

# Publishes a patch of the app in $APP for release version $1 (flags after).
sb_patch() {
  local v=$1
  shift
  perl -pi -e "s/^version: .*/version: $v/" "$APP/pubspec.yaml"
  (cd "$APP" && cli "patch_${BUNDLE##*.}_$(date +%H%M%S)" "$SB" patch ios --release-version "$v" --no-codesign --no-confirm "$@")
}

# ---- setup common to both phases ----
mkdir -p "$EVID"
export SHOREBIRD_ARTIFACT_ORIGIN=${E2E_ARTIFACT_ORIGIN:-${SHOREBIRD_ARTIFACT_ORIGIN:-}}
SB=$CLI/bin/shorebird
FLUTTER_DIR=$CLI/bin/cache/flutter/$(cat "$CLI/bin/internal/flutter.version")
DART=$FLUTTER_DIR/bin/cache/dart-sdk/bin/dart
export CI=true LANG=en_US.UTF-8 # CocoaPods wants UTF-8
if [[ $PHASE == install ]]; then
  [[ -n ${E2E_ARTIFACT_UPSTREAM:-} || -n $SHOREBIRD_ARTIFACT_ORIGIN ]] || die "set E2E_ARTIFACT_ORIGIN or E2E_ARTIFACT_UPSTREAM"
  rm -rf "$WORK"
  mkdir -p "$WORK" "$EVID"
  : >"$SYSLOG"
  API_KEY=sb_api_e2e_$(openssl rand -hex 16)
  URL_SECRET=$(openssl rand -hex 32)
  app_id=
else
  [[ -f $STATE ]] || die "no state in $WORK: run phase 1 first"
  # shellcheck disable=SC1090
  . "$STATE"
fi
BASE=http://$HOST_IP:$PORT
export SHOREBIRD_HOSTED_URL=$BASE SHOREBIRD_TOKEN=$API_KEY
if [[ $PHASE == install && -n ${E2E_ARTIFACT_UPSTREAM:-} ]]; then
  spawn "$WORK/origin.out" python3 -I "$ROOT/selfhost/scripts/lib/acs2_recording_origin.py" 18085 "$E2E_ARTIFACT_UPSTREAM" "$EVID/artifact_origin.jsonl"
  ORIGIN_PID=$SPAWNED
  spawn "$WORK/connrec.out" python3 -I "$ROOT/selfhost/scripts/lib/connect_recorder.py" 18088 "$EVID/outbound_connect.jsonl"
  CONNREC_PID=$SPAWNED
  save_state
  sleep 2
fi
if [[ -n ${E2E_ARTIFACT_UPSTREAM:-} ]]; then
  export SHOREBIRD_ARTIFACT_ORIGIN=http://127.0.0.1:18085
  export HTTPS_PROXY=http://127.0.0.1:18088 HTTP_PROXY=http://127.0.0.1:18088
  upstream_host=${E2E_ARTIFACT_UPSTREAM#*//}
  export NO_PROXY=localhost,127.0.0.1,$HOST_IP,${upstream_host%%:*}
fi
export FLUTTER_STORAGE_BASE_URL=$SHOREBIRD_ARTIFACT_ORIGIN

make_release() { # V | W, extra release flags
  local which=$1 name dir ver tag bundle app_b
  shift
  use "$which"
  name=e2e$(tr 'VW' 'vw' <<<"$which")
  dir=$APP
  rm -rf "$dir"
  log "app $name: release $VERSION as $BUNDLE"
  (cd "$WORK" && "$FLUTTER_DIR/bin/flutter" create --org dev.selfhost --project-name "$name" --platforms ios "$dir" >"$WORK/create_$name.log" 2>&1) ||
    { tail -20 "$WORK/create_$name.log"; die "flutter create $name"; }
  rm -rf "$dir/test"
  perl -pi -e "s/^version: .*/version: $VERSION/" "$dir/pubspec.yaml"
  write_main "$dir" "${which}1" 10 rec
  printf 'app_id: %s\nbase_url: %s\n' "$app_id" "$BASE" >"$dir/shorebird.yaml"
  python3 -I "$CLI/selfhost/scripts/lib/add_shorebird_asset.py" "$dir/pubspec.yaml"
  # CocoaPods, not Swift Package Manager: the release then records a
  # Podfile.lock hash, which is what the CLI's iOS native-change check compares.
  perl -0pi -e 's/^flutter:\n/flutter:\n  config:\n    enable-swift-package-manager: false\n/m' "$dir/pubspec.yaml"
  # A local plugin with an iOS part, so the app has a pod and its release
  # records a Podfile.lock hash (a plugin-less app has no Podfile at all).
  perl -0pi -e 's/^dependencies:\n/dependencies:\n  e2e_plugin_a:\n    path: ..\/e2e_plugin_a\n/m' "$dir/pubspec.yaml"
  grep -q "PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE;" "$dir/ios/Runner.xcodeproj/project.pbxproj" || die "the project's bundle id is not $BUNDLE"
  (cd "$dir" && cli "release_$name" "$SB" release ios --no-codesign --no-confirm "$@")
  app_b=$(find "$dir/build/ios/archive" -name Runner.app -path '*Products/Applications*' | head -1)
  [[ -n $app_b ]] || die "no Runner.app in the $name archive"
  IOS_DEVICE_UDID=$UDID "$CLI/packages/code_push_server/tool/ios_resign.sh" "$app_b" "$IDENTITY" "$PROFILE" "$TEAM" "$BUNDLE" >"$WORK/resign_$name.log" 2>&1 ||
    { tail -20 "$WORK/resign_$name.log"; die "resign $name"; }
  codesign --verify --deep --strict "$app_b"
  mkdir -p "$WORK/signed/$which"
  cp -R "$app_b" "$WORK/signed/$which/"
  echo "ok: $name signed as $BUNDLE"
}

# ================= phase 3 (optional): rebuild W with a new signing key =================
# Needed only when the signing keys are gone (they live in $WORK/keys): the new W
# is a new release (E2E_VER_W) under the same bundle id, so it is installed
# fresh and the Local Network prompt for it needs a tap again.
if [[ $PHASE == rebuild-w ]]; then
  [[ -n ${E2E_VER_W:-} ]] || die "set E2E_VER_W to a new release version for W"
  if ! kill -0 "${SYSLOG_PID:-0}" 2>/dev/null; then spawn "$SYSLOG" idevicesyslog -u "$UDID"; SYSLOG_PID=$SPAWNED; fi
  if [[ -n ${E2E_ARTIFACT_UPSTREAM:-} ]]; then
    if ! kill -0 "${ORIGIN_PID:-0}" 2>/dev/null; then
      spawn "$WORK/origin.out" python3 -I "$ROOT/selfhost/scripts/lib/acs2_recording_origin.py" 18085 "$E2E_ARTIFACT_UPSTREAM" "$EVID/artifact_origin.jsonl"; ORIGIN_PID=$SPAWNED
    fi
    if ! kill -0 "${CONNREC_PID:-0}" 2>/dev/null; then
      spawn "$WORK/connrec.out" python3 -I "$ROOT/selfhost/scripts/lib/connect_recorder.py" 18088 "$EVID/outbound_connect.jsonl"; CONNREC_PID=$SPAWNED
    fi
    sleep 2
  fi
  if ! kill -0 "${SERVER_PID:-0}" 2>/dev/null; then SERVER_PID=; start_server; fi
  save_state
  keys=$WORK/keys
  rm -rf "$keys"
  mkdir -p "$keys"
  for k in good other; do
    openssl genrsa -out "$keys/$k.pem" 2048 2>/dev/null
    openssl rsa -in "$keys/$k.pem" -pubout -out "$keys/$k.pub.pem" 2>/dev/null
  done
  make_release W --public-key-path "$keys/good.pub.pem"
  yamlof() { cat "$WORK/signed/$1/Runner.app/Frameworks/App.framework/flutter_assets/shorebird.yaml"; }
  yamlof W | sed -E 's/^(patch_public_key:).*/\1 <key>/' >"$EVID/bundled_shorebird_W.yaml"
  grep -q '^patch_public_key:' <(yamlof W) || die "the new W release carries no patch_public_key"
  use W
  stop_app
  ios-deploy --id "$UDID" --uninstall_only --bundle_id "$BUNDLE_W" >/dev/null 2>&1 || true
  timeout 300 ios-deploy --id "$UDID" --bundle "$WORK/signed/W/Runner.app" --nostart >"$EVID/cli/install_W2.txt" 2>&1 || die "install W"
  launch
  sleep 15
  save_state
  KEEP_RUNNING=1
  echo "ready for taps: $BUNDLE_W"
  echo "then: E2E_VER_W=$VER_W E2E_WORK=$WORK E2E_FROM=<scenario> $0 --resume"
  exit 3
fi

if [[ $PHASE == install ]]; then
  # ================= phase 1: build, refuse, install, ask for the taps =================
  log "CLI and server"
  "$SB" --version
  (cd "$CLI/packages/code_push_server" && "$DART" pub get >/dev/null)
  spawn "$SYSLOG" idevicesyslog -u "$UDID"
  SYSLOG_PID=$SPAWNED
  save_state
  start_server
  echo "listening on $BASE"
  app_id=$(curl -fsS --max-time 30 -X POST "$BASE/api/v1/apps" -H "Authorization: Bearer $API_KEY" \
    -H 'Content-Type: application/json' -d '{"display_name":"ios-device-e2e"}' |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  save_state

  keys=$WORK/keys
  mkdir -p "$keys"
  for k in good other; do
    openssl genrsa -out "$keys/$k.pem" 2048 2>/dev/null
    openssl rsa -in "$keys/$k.pem" -pubout -out "$keys/$k.pub.pem" 2>/dev/null
  done

  for plugin in e2e_plugin_a e2e_plugin_b; do
    (cd "$WORK" && "$FLUTTER_DIR/bin/flutter" create --template=plugin --platforms=ios --org dev.selfhost --project-name "$plugin" "$WORK/$plugin" >"$WORK/create_$plugin.log" 2>&1) ||
      { tail -20 "$WORK/create_$plugin.log"; die "flutter create $plugin"; }
  done

  make_release V
  make_release W --public-key-path "$keys/good.pub.pem"
  expect_equal "$(server_releases)" "$VER_V $VER_W" "the releases on the server"

  log "scenario 6a: the bundled shorebird.yaml of each .app"
  yamlof() { cat "$WORK/signed/$1/Runner.app/Frameworks/App.framework/flutter_assets/shorebird.yaml"; }
  yamlof V >"$EVID/bundled_shorebird_V.yaml"
  yamlof W | sed -E 's/^(patch_public_key:).*/\1 <key>/' >"$EVID/bundled_shorebird_W.yaml"
  grep -q '^patch_public_key:' <(yamlof W) || die "the W release carries no patch_public_key"
  ! grep -q '^patch_public_key:' <(yamlof V) || die "the unsigned V release carries a patch_public_key"
  pass "the W release's bundled shorebird.yaml carries patch_public_key, V's does not"

  log "scenario 7: native changes and added members (no phone needed)"
  use V
  VER_T=9.0.0+9
  before=$(server_patches "$VER_V")
  # A throwaway release of the V project, so (i) publishes somewhere that is
  # neither V nor W and their patch numbering stays clean.
  perl -pi -e "s/^version: .*/version: $VER_T/" "$APPV/pubspec.yaml"
  (cd "$APPV" && cli release_throwaway "$SB" release ios --no-codesign --no-confirm)
  perl -pi -e "s/^version: .*/version: $VER_V/" "$APPV/pubspec.yaml"
  expect_equal "$(server_releases)" "$VER_V $VER_W $VER_T" "the releases on the server"
  delegate=$APPV/ios/Runner/AppDelegate.swift
  cp "$delegate" "$WORK/AppDelegate.swift.orig"
  # (i) A Swift-only change is NOT refused on iOS, as in upstream: Xcode builds
  # are not byte-reproducible, so the CLI does not treat a changed Runner
  # executable as a native change (apple_patcher_mixin.dart,
  # assertUnpatchableDiffs: confirmNativeChanges false). Observed, and asserted.
  perl -0pi -e 's/(return super\.application\(application, didFinishLaunchingWithOptions)/NSLog("SB-E2E-NATIVE")\n    $1/' "$delegate"
  grep -q SB-E2E-NATIVE "$delegate" || die "could not edit AppDelegate.swift"
  perl -pi -e "s/^version: .*/version: $VER_T/" "$APPV/pubspec.yaml"
  write_main "$APPV" T2 10 iter # a Dart change too: a patch identical to its release is refused
  rc=0
  (cd "$APPV" && cli observed_swift_change "$SB" patch ios --release-version "$VER_T" --no-codesign --no-confirm) || rc=$?
  expect_equal "$rc" "0" "the exit code of a Swift-only change (upstream publishes it)"
  grep -qF 'Published Patch 1!' "$EVID/cli/observed_swift_change.txt" || die "the Swift-only patch was not published"
  expect_equal "$(server_patches "$VER_T")" "1" "patches on the throwaway $VER_T"
  expect_equal "$(server_patches "$VER_V")" "$before" "patches on $VER_V are untouched"
  cp "$WORK/AppDelegate.swift.orig" "$delegate"
  write_main "$APPV" V1 10 rec
  # (ii) The iOS native-change refusal: a Podfile.lock that differs from the
  # release's. A second local path plugin with an iOS native part adds a pod, no network.
  for f in pubspec.yaml pubspec.lock ios/Podfile ios/Podfile.lock; do
    [[ -f $APPV/$f ]] && cp "$APPV/$f" "$WORK/orig_$(tr / _ <<<"$f")"
  done
  perl -0pi -e 's/^dependencies:\n/dependencies:\n  e2e_plugin_b:\n    path: ..\/e2e_plugin_b\n/m' "$APPV/pubspec.yaml"
  grep -q e2e_plugin_b "$APPV/pubspec.yaml" || die "could not add the plugin dependency"
  perl -pi -e "s/^version: .*/version: $VER_V/" "$APPV/pubspec.yaml"
  (cd "$APPV" && must_fail refused_podfile_lock 70 'Podfile.lock is different from the one used to build the release' \
    "$SB" patch ios --release-version "$VER_V" --no-codesign --no-confirm)
  expect_equal "$(server_patches "$VER_V")" "$before" "patches on $VER_V after the refused Podfile.lock change"
  # Restore the app, and keep the proof that it is back as it was.
  for f in pubspec.yaml pubspec.lock ios/Podfile ios/Podfile.lock; do
    [[ -f $WORK/orig_$(tr / _ <<<"$f") ]] && cp "$WORK/orig_$(tr / _ <<<"$f")" "$APPV/$f"
  done
  cmp "$APPV/ios/Podfile.lock" "$WORK/orig_ios_Podfile.lock"
  ! grep -q e2e_plugin_b "$APPV/pubspec.yaml" || die "the plugin dependency is still in pubspec.yaml"
  # (iii) a Dart patch that adds a member something references is refused
  write_main "$APPV" V2 10 iter extra
  (cd "$APPV" && must_fail refused_added_member 70 'cannot introduce members' "$SB" patch ios --release-version "$VER_V" --no-codesign --no-confirm)
  expect_equal "$(server_patches "$VER_V")" "$before" "patches on $VER_V after the refused added member"
  expect_equal "$(patch_check "$VER_V" 0)" "none []" "the server offers nothing for $VER_V"
  write_main "$APPV" V1 10 rec
  pass "a Podfile.lock change and an added referenced member are refused with nothing published; a Swift-only change is published (upstream parity, on a throwaway release)"

  log "install both apps fresh"
  for id in $(ios-deploy --id "$UDID" --list_bundle_id 2>/dev/null | tr -d '\r' | grep -E '^dev\.selfhost\.'); do
    echo "uninstalling $id"
    ios-deploy --id "$UDID" --uninstall_only --bundle_id "$id" >/dev/null 2>&1 || echo "  (could not remove $id)"
  done
  for w in V W; do
    echo "installing $w"
    timeout 300 ios-deploy --id "$UDID" --bundle "$WORK/signed/$w/Runner.app" --nostart >"$EVID/cli/install_$w.txt" 2>&1 || { tail -5 "$EVID/cli/install_$w.txt"; die "install $w"; }
  done
  ios-deploy --id "$UDID" --list_bundle_id 2>/dev/null | tr -d '\r' | grep -E "^($BUNDLE_V|$BUNDLE_W)$" | sort | tr '\n' ' '
  echo
  # Launch each once so the prompt appears; the sessions stay up for the person.
  KEEP_OTHERS=
  for w in V W; do
    use "$w"
    launch
    KEEP_OTHERS=1
    sleep 15
    echo "launched $BUNDLE (pid of the debug session $DBG_PID)"
  done
  save_state
  KEEP_RUNNING=1
  echo
  echo "ready for taps: $BUNDLE_V $BUNDLE_W"
  echo "then: E2E_WORK=$WORK $0 --resume"
  exit 3
fi

# ================= phase 2: every scenario, patches only =================
# What phase 1 left running is restarted if it died (a failed run stops it all;
# the server's data dir persists). E2E_FROM=<n> skips scenarios 1..n-1 when the
# device and server are already past them (after a failed run, never after a reinstall).
FROM=${E2E_FROM:-1}
if ! kill -0 "${SYSLOG_PID:-0}" 2>/dev/null; then spawn "$SYSLOG" idevicesyslog -u "$UDID"; SYSLOG_PID=$SPAWNED; fi
if [[ -n ${E2E_ARTIFACT_UPSTREAM:-} ]]; then
  if ! kill -0 "${ORIGIN_PID:-0}" 2>/dev/null; then
    spawn "$WORK/origin.out" python3 -I "$ROOT/selfhost/scripts/lib/acs2_recording_origin.py" 18085 "$E2E_ARTIFACT_UPSTREAM" "$EVID/artifact_origin.jsonl"; ORIGIN_PID=$SPAWNED
  fi
  if ! kill -0 "${CONNREC_PID:-0}" 2>/dev/null; then
    spawn "$WORK/connrec.out" python3 -I "$ROOT/selfhost/scripts/lib/connect_recorder.py" 18088 "$EVID/outbound_connect.jsonl"; CONNREC_PID=$SPAWNED
  fi
fi
if ! kill -0 "${SERVER_PID:-0}" 2>/dev/null; then SERVER_PID=; start_server; fi
save_state
V1_VERSION=$VER_V
NLAUNCH=$(find "$EVID/launches" -name "[0-9][0-9]_*" 2>/dev/null | wc -l | tr -d " ")

log "the Local Network decision"
mkdir -p "$EVID/launches"
stop_app
BUNDLE=$BUNDLE_W stop_app
for w in V W; do
  use "$w"
  for try in 1 2 3; do
    launch
    if wait_log 'Patch check response' 60; then break; fi
    echo "first request after the tap failed (try $try); launching again"
  done
  wait_log 'Update thread finished with status' 60
  slice | sed -E 's/^.*Runner\(Flutter\)\[[0-9]+\] <[A-Za-z]+>: //' >"$EVID/launches/warmup_${BUNDLE##*.}.txt" 2>/dev/null || true
done
mkdir -p "$EVID/launches"
grep -a 'nehelper' "$SYSLOG" | grep -a 'Local network decision' | sed -E 's/^.* nehelper\([^)]*\)\[[0-9]+\] <[A-Za-z]+>: //' | sort | uniq -c | tee "$EVID/local_network_decisions.txt"

# ----- V: scenarios 1-4b -----
use V
if ((FROM <= 2)); then
log "scenario 1: V1, the base release"
boot 'flutter: E2E-MARKER V1:g-55'
has 'Prepared boot of the base release'
has 'Shorebird updater: no active patch'
expect_equal "$(patch_check "$VER_V" 0)" "none []" "the server's patch check for $VER_V"
pass "the release runs: V1, no patch"

log "scenario 2: patch 1 is a real Dart change (fib rewritten, other marker)"
write_main "$APPV" V2 10 iter
sb_patch "$VER_V"
expect_equal "$(server_patches "$VER_V")" "1" "patches on $VER_V"
boot 'flutter: E2E-MARKER V1:g-55'
has 'Patch 1 successfully downloaded'
boot 'flutter: E2E-MARKER V2:g-55'
has 'Launch success for patch 1:'
has 'ROUTEB: applied 2/2 targets, entering main'
pass "patch 1 runs: V2 through Route B"

fi

((FROM <= 1)) || pass "NOT re-checked in this invocation: scenarios before E2E_FROM=$FROM (their result is whatever an earlier invocation recorded above)"
if ((FROM <= 3)); then
log "scenario 3: patch 2, consecutive"
write_main "$APPV" V3 12 iter
sb_patch "$VER_V"
boot 'flutter: E2E-MARKER V2:g-55'
has 'Patch 2 successfully downloaded'
boot 'flutter: E2E-MARKER V3:g-144'
has 'Launch success for patch 2:'
expect_equal "$(server_patches "$VER_V")" "1 2" "patches on $VER_V"
pass "patch 2 runs: V3, after V2"

fi

if ((FROM <= 4)); then
log "scenario 4: roll back patch 2 (the server restores patch 1)"
(cd "$APP" && "$SB" patches rollback --release-version "$VER_V" --patch-number 2) 2>&1 | tee "$EVID/cli/rollback_V_2.txt"
expect_equal "$(patch_check "$VER_V" 0)" "1 [2]" "the server offers patch 1 again to a device with no patch"
expect_equal "$(patch_check "$VER_V" 2)" "1 [2]" "the server offers patch 1 again to a device on patch 2"
boot 'flutter: E2E-MARKER V3:g-144'
has 'rolled_back_patch_numbers: Some\(\[2'
has 'Patch 1 successfully downloaded'
boot 'flutter: E2E-MARKER V2:g-55'
has 'Launch success for patch 1:'
lacks 'E2E-MARKER V3'
pass "patch 2 rolled back: the device is back on patch 1, V2"

log "scenario 4b: rolling back patch 1, which patch 2 superseded"
(cd "$APP" && "$SB" patches rollback --release-version "$VER_V" --patch-number 1) 2>&1 | tee "$EVID/cli/rollback_V_1.txt"
expect_equal "$(patch_check "$VER_V" 1)" "none [1, 2]" "the server's patch check for a device on patch 1"
boot 'flutter: E2E-MARKER V2:g-55'
has 'rolled_back_patch_numbers: Some\(\[1, 2'
boot 'flutter: E2E-MARKER V1:g-55'
has 'Shorebird updater: no active patch'
lacks 'E2E-MARKER V[23]'
pass "patch 1 rolled back: the device is on the base release, V1"

log "scenario 5a: patch 3 for V is published (it must not reach W)"
write_main "$APPV" V4 14 iter
sb_patch "$VER_V"
expect_equal "$(server_patches "$VER_V")" "1 2 3" "patches on $VER_V"
expect_equal "$(patch_check "$VER_V" 0)" "3 [1, 2]" "the server offers patch 3 to $VER_V"

fi

# ----- W -----
KEYS=$WORK/keys
SIGN=(--public-key-path "$KEYS/good.pub.pem" --private-key-path "$KEYS/good.pem")
if ((FROM <= 5)); then
use W
log "scenario 5b: version targeting on W ($VER_W ignores V's patch)"
boot 'flutter: E2E-MARKER W1:g-55'
expect_equal "$(patch_check "$VER_W" 0)" "none []" "the server's patch check for $VER_W"
lacks 'Launch success for patch|successfully downloaded|E2E-MARKER V'
boot 'flutter: E2E-MARKER W1:g-55'
lacks 'Launch success for patch|successfully downloaded|E2E-MARKER V'
write_main "$APPW" W2 11 iter
sb_patch "$VER_W" "${SIGN[@]}"
expect_equal "$(patch_check "$VER_W" 0)" "1 []" "the server offers patch 1 to $VER_W"
boot 'flutter: E2E-MARKER W1:g-55'
has 'Patch 1 successfully downloaded'
boot 'flutter: E2E-MARKER W2:g-89'
has 'Launch success for patch 1:'
pass "$VER_W ignored the patch for $VER_V and took its own: W2"
fi

use V
log "scenario 5c: V takes its patch 3"
if ((FROM <= 5)); then
  boot 'flutter: E2E-MARKER V1:g-55'
  has 'Patch 3 successfully downloaded'
  boot 'flutter: E2E-MARKER V4:g-377'
  has 'Launch success for patch 3:'
else
  # E2E_FROM=6: patch 3 was already downloaded and booted in an earlier invocation
  boot 'flutter: E2E-MARKER V4:g-377'
  has 'Launch success for patch 3:'
fi
pass "$VER_V took its patch 3 (V4) and is unaffected by W's patch"

use W
log "scenario 4c: rolling back the only patch restores the release"
(cd "$APP" && "$SB" patches rollback --release-version "$VER_W" --patch-number 1) 2>&1 | tee "$EVID/cli/rollback_W_1.txt"
expect_equal "$(patch_check "$VER_W" 1)" "none [1]" "the server's patch check for a device on patch 1"
boot 'flutter: E2E-MARKER W2:g-89'
has 'rolled_back_patch_numbers: Some\(\[1'
boot 'flutter: E2E-MARKER W1:g-55'
has 'Shorebird updater: no active patch'
lacks 'E2E-MARKER W2'
pass "the only patch rolled back: the device is back on W1"

log "scenario 6: signing (W is signed; its patches are signed with the good key)"
write_main "$APPW" W3 12 iter
sb_patch "$VER_W" "${SIGN[@]}"
sig=$(curl -fsS --max-time 15 -X POST "$BASE/api/v1/patches/check" -H 'Content-Type: application/json' -d "$(patch_body "$VER_W" 0)" |
  python3 -c 'import json,sys; print(len(json.load(sys.stdin)["patch"].get("hash_signature") or ""))')
((sig > 100)) || die "the server's patch carries no signature ($sig)"
echo "ok: the server serves the patch with a signature ($sig characters)"
boot 'flutter: E2E-MARKER W1:g-55'
has 'Patch 2 successfully downloaded'
# The updater logs this only when the release carries a key and the patch a
# signature, and it checked one against the other.
has 'Patch signature is valid'
boot 'flutter: E2E-MARKER W3:g-144'
has 'Launch success for patch 2:'
lacks 'No public key configured'
pass "a patch signed with the release's key boots with signature verification on"
write_main "$APPW" W9 13 iter
perl -pi -e "s/^version: .*/version: $VER_W/" "$APPW/pubspec.yaml"
(cd "$APPW" && must_fail signed_other_key 70 'Signature verification failed: the signature does not match the provided public key.' \
  "$SB" patch ios --release-version "$VER_W" --no-codesign --no-confirm --public-key-path "$KEYS/good.pub.pem" --private-key-path "$KEYS/other.pem")
expect_equal "$(server_patches "$VER_W")" "1 2" "patches on $VER_W after the refused patch"
boot 'flutter: E2E-MARKER W3:g-144'
pass "a patch signed with another key was refused by the CLI before publication (the device is never offered it, so the updater's own rejection is not exercised); the app runs W3"

log "scenario 8a: the server restarts on the same data dir after a patch is published and before the phone checks"
write_main "$APPW" W4 13 iter
sb_patch "$VER_W" "${SIGN[@]}"
releases_before=$(server_releases)
patches_before=$(server_patches "$VER_W")
check_before=$(patch_check "$VER_W" 0)
expect_equal "$check_before" "3 [1]" "the server offers patch 3 before the restart"
old_server=$SERVER_PID
stop_server
if curl -fsS --max-time 5 "$BASE/readyz" >/dev/null 2>&1; then die "the server still answers after the stop"; fi
start_server
[[ $SERVER_PID != "$old_server" ]] || die "no new server process"
expect_equal "$(server_releases)" "$releases_before" "the releases the restarted server lists"
expect_equal "$(server_patches "$VER_W")" "$patches_before" "the patches the restarted server lists for $VER_W"
expect_equal "$(patch_check "$VER_W" 0)" "$check_before" "the restarted server's patch check"
boot 'flutter: E2E-MARKER W3:g-144'
has 'Patch 3 successfully downloaded'
boot 'flutter: E2E-MARKER W4:g-233'
has 'Launch success for patch 3:'
pass "the server restarted on its data dir: state unchanged, and the phone took a patch published before the restart (W4)"

log "scenario 8: the server is unavailable"
stop_server
if curl -fsS --max-time 5 "$BASE/readyz" >/dev/null 2>&1; then die "the server still answers"; fi
launch
wait_log 'flutter: E2E-MARKER W4:g-233' 60
has 'Launch success for patch 3:'
has 'Update failed: Network request failed; the server could not be reached'
wait_log 'Update thread finished with status' 120
sleep 10
kill -0 "$DBG_PID" 2>/dev/null || die "the app is not running with the server down (its process ended)"
lacks 'crashed|fatal'
echo "ok: the patched app booted its patch with the server down and kept running"
slice | sed -E 's/^.*Runner\(Flutter\)\[[0-9]+\] <[A-Za-z]+>: //' >"$EVID/launches/server_down_W.txt"
start_server
curl -fsS --max-time 5 "$BASE/readyz" >/dev/null
expect_equal "$(patch_check "$VER_W" 3)" "none [1]" "the restarted server's patch check"
write_main "$APPW" W5 14 iter
sb_patch "$VER_W" "${SIGN[@]}"
boot 'flutter: E2E-MARKER W4:g-233'
has 'Patch 4 successfully downloaded'
boot 'flutter: E2E-MARKER W5:g-377'
pass "the patched app booted its patch with the server down and stayed alive; the restarted server serves again (W5)"

log "scenario 9: staged rollout"
CLIENT=$(device_client_id "$VER_W")
echo "the phone's client id: $CLIENT"
write_main "$APPW" W6 15 iter
sb_patch "$VER_W" "${SIGN[@]}"
expect_equal "$(server_patches "$VER_W")" "1 2 3 4 5" "patches on $VER_W"
PID5=$(patch_id_of "$VER_W" 5)
CHANNEL_ID=$(api "$BASE/api/v1/apps/$app_id/channels" |
  python3 -c 'import json,sys; print(next(c["id"] for c in json.load(sys.stdin) if c["name"] == "stable"))')
BUCKET=$(bucket_of "$app_id" "$CHANNEL_ID" "$PID5" "$CLIENT")
R_OUT=$((BUCKET / 100))
R_IN=$((R_OUT + 1))
echo "bucket of the phone for patch $PID5: $BUCKET (outside at ${R_OUT}%, inside from ${R_IN}%)"
set_rollout() { api -X POST "$BASE/admin/apps/$app_id/patches/$PID5/rollout?channel=stable&percent=$1" >/dev/null; }
set_rollout "$R_OUT"
expect_equal "$(patch_check "$VER_W" 4 "$CLIENT")" "none [1]" "the server's check for the phone at ${R_OUT}%, outside its bucket"
boot 'flutter: E2E-MARKER W5:g-377'
lacks 'Patch 5 successfully downloaded'
lacks 'E2E-MARKER W6'
pass "patch 5 at ${R_OUT}%: the phone (bucket $BUCKET) was not offered it and kept W5"
if ((R_IN <= 99)); then
  set_rollout "$R_IN"
  expect_equal "$(patch_check "$VER_W" 4 "$CLIENT")" "5 [1]" "the server's check for the phone at ${R_IN}%, inside its bucket"
  pass "patch 5 at ${R_IN}%: the server offers it to the phone"
fi
set_rollout 100
boot 'flutter: E2E-MARKER W5:g-377'
has 'Patch 5 successfully downloaded'
boot 'flutter: E2E-MARKER W6:g-610'
has 'Launch success for patch 5:'
pass "rollout raised to 100%: the phone took patch 5 (W6)"

log "scenario 10: backup and restore of the server's data"
LIB=$CLI/packages/code_push_server/ops/lib
BR=$WORK/backup-restore
[[ $WORK != *[\&#]* ]] || die "work dir $WORK has a character sed can't take"
mkdir -p "$BR/lib" "$BR/tmp"
for f in write_manifest.sh verify_manifest.sh; do
  sed -e 's#/data#@SB_DATA@#g' -e 's#/tmp/#@SB_TMP@/#g' \
    -e "s#@SB_DATA@#$WORK/server-data#g" -e "s#@SB_TMP@#$BR/tmp#g" "$LIB/$f" >"$BR/lib/$f"
done
check_pre=$(patch_check "$VER_W" 5)
expect_equal "$(patch_check "$VER_W" 4)" "5 [1]" "the server's check from patch 4 before the backup"
sha_pre=$(patch_artifact_sha "$VER_W" 4)
patches_pre=$(server_patches "$VER_W")
releases_pre=$(server_releases)
expect_equal "$patches_pre" "1 2 3 4 5" "patches on $VER_W before the backup"
stop_server
if curl -fsS --max-time 5 "$BASE/readyz" >/dev/null 2>&1; then die "the server still answers; refusing to snapshot a writable deployment"; fi
BID=$(openssl rand -hex 16) STAMP=$(date -u +%Y%m%dT%H%M%SZ) IMAGE=e2e IMAGE_ID=e2e sh "$BR/lib/write_manifest.sh"
tar czf "$BR/backup.tgz" -C "$WORK/server-data" --exclude='code_push.db-shm' .
rm -f "$WORK/server-data/MANIFEST.json"
[[ -s $BR/backup.tgz ]]
rm -rf "$WORK/server-data"
start_server
wiped=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -H "Authorization: Bearer $API_KEY" "$BASE/api/v1/apps/$app_id" || true)
expect_equal "$wiped" "404" "the wiped server's answer for the app"
stop_server
mkdir "$BR/extract"
(cd "$BR/extract" && tar xzf "$BR/backup.tgz" && sh "$BR/lib/verify_manifest.sh")
rm -rf "$BR/extract" "$WORK/server-data"
mkdir "$WORK/server-data"
tar xzf "$BR/backup.tgz" -C "$WORK/server-data"
rm -f "$WORK/server-data/MANIFEST.json"
start_server
expect_equal "$(server_releases)" "$releases_pre" "the releases after the restore"
expect_equal "$(server_patches "$VER_W")" "$patches_pre" "the patches on $VER_W after the restore"
expect_equal "$(patch_check "$VER_W" 5)" "$check_pre" "the patch check after the restore"
expect_equal "$(patch_check "$VER_W" 4)" "5 [1]" "the server's check from patch 4 after the restore"
expect_equal "$(patch_artifact_sha "$VER_W" 4)" "$sha_pre" "patch 5's artifact after the restore (sha256)"
boot 'flutter: E2E-MARKER W6:g-610'
has 'Launch success for patch 5:'
lacks 'E2E-MARKER W[1-5]'
pass "backup, wipe and restore: the data is back, and the phone keeps patch 5 (W6)"
write_main "$APPW" W7 16 iter
sb_patch "$VER_W" "${SIGN[@]}"
expect_equal "$(server_patches "$VER_W")" "1 2 3 4 5 6" "patches on $VER_W after publishing on the restored server"
expect_equal "$(patch_check "$VER_W" 5)" "6 [1]" "the restored server offers the new patch"
boot 'flutter: E2E-MARKER W6:g-610'
has 'Patch 6 successfully downloaded'
boot 'flutter: E2E-MARKER W7:g-987'
has 'Launch success for patch 6:'
pass "a patch published after the restore reached the phone (W7)"

stop_app
log "PASS (full, iOS): $(printf '%s; ' "${PASSED[@]}")"
echo "launch disappearances: $DISAPPEARANCES"
