#!/usr/bin/env bash
# cspell:words getsockname screencap hydrat coheren
# ANDROID-FINAL-STACK-1 stage A: an ordinary Android release through today's
# frozen self-hosted stack, via the normal developer workflow.
#
# Throwaway control plane, temp fixture copy, free port reached from the device
# by `adb reverse` (the documented path for this rig; the fixture's base_url is
# `http://localhost:<port>` so one URL works for host and device alike).
# Never touches cps-ios, cps-android, any cell, or any existing release.
set -uo pipefail
REPO=/Users/mendell/shorebird
SB=/Volumes/build/route-b/shorebird-candidate/bin/shorebird
ADB=$HOME/Library/Android/sdk/platform-tools/adb
DEV=${DEV:-3f72a543}
API_KEY="sb_api_android1_$(date +%s)"
WORK=${WORK:-$(mktemp -d /tmp/android1.XXXXXX)}
PORT=${PORT:-$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')}
BASE="http://localhost:$PORT"
LOG="$WORK/server.log"
echo "WORK=$WORK" > /Volumes/build/route-b/android1.env
echo "PORT=$PORT" >> /Volumes/build/route-b/android1.env
echo "API_KEY=$API_KEY" >> /Volumes/build/route-b/android1.env
step(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

step "0. throwaway control plane on :$PORT, reachable from the device"
mkdir -p "$WORK/data"
( cd "$REPO/packages/code_push_server" && PORT=$PORT API_KEY="$API_KEY" \
  DB_BACKEND=sqlite STORAGE_BACKEND=file DATA_DIR="$WORK/data" \
  PUBLIC_BASE_URL="$BASE" LOG_FORMAT=json \
  URL_SIGNING_SECRET="$(openssl rand -hex 32)" \
  LOGIN_EMAIL="android1@self-host.local" dart run bin/server.dart ) >"$LOG" 2>&1 &
echo $! > "$WORK/server.pid"
for _ in $(seq 1 60); do curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fsS "$BASE/healthz" >/dev/null || { echo "server did not start"; exit 1; }
"$ADB" -s "$DEV" reverse "tcp:$PORT" "tcp:$PORT" >/dev/null
echo "  up; adb reverse tcp:$PORT -> host"
echo "  device sees it: $("$ADB" -s "$DEV" shell "curl -s -o /dev/null -w '%{http_code}' $BASE/healthz" 2>/dev/null || echo '(no curl on device; checked later by the app)')"

step "1. a fresh ordinary Flutter app with an unmistakable marker"
# NOT selfhost/fixtures/android_signing_app: that fixture exists to probe a
# NON-DEBUG release signing identity and its gradle refuses without a keystore
# at a path that is not committed. This lane is about the ORDINARY Android
# workflow, so the app is what `flutter create` gives a developer, signed the
# way `flutter build appbundle` signs by default.
APP="$WORK/app"
FLUTTER_BIN=/Volumes/build/route-b/shorebird-candidate/bin/cache/flutter/${FLUTTER_VER:-e64eb0af52e1c43c3b21a39556d789538d0df9b3}/bin/flutter
( cd "$WORK" && "$FLUTTER_BIN" create --org dev.selfhost --platforms=android app ) \
  > "$WORK/create.log" 2>&1
[ -d "$APP/android/app/src" ] || { echo "  create FAILED"; tail -15 "$WORK/create.log"; exit 1; }
# The marker discipline is copied from the signing fixture and is the point:
# a bare constant is folded and the patch becomes invisible to the analyzer, so
# it sits in a never-inline function behind a DateTime guard.
cat > "$APP/lib/main.dart" <<'DART'
import 'package:flutter/material.dart';

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String markerText() => DateTime.now().millisecondsSinceEpoch >= 0
    ? 'ANDROID-FINAL-V1-RELEASE'
    : 'ANDROID-FINAL-V1-RELEASE!';

void main() => runApp(const MarkerApp());

class MarkerApp extends StatelessWidget {
  const MarkerApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: Text(markerText(), style: const TextStyle(fontSize: 28)),
      ),
    ),
  );
}
DART
echo "  marker: ANDROID-FINAL-V1-RELEASE"
APP_ID=$(curl -fsS -X POST "$BASE/api/v1/apps" -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' -d '{"display_name":"android-final-stack-1"}' \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
cat > "$APP/shorebird.yaml" <<YAML
app_id: $APP_ID
base_url: $BASE
YAML
python3 "$REPO/selfhost/scripts/lib/add_shorebird_asset.py" "$APP/pubspec.yaml"
# `shorebird doctor --fix` is the real developer step, and it is what adds the
# INTERNET permission a fresh `flutter create` app lacks. Running the product's
# own fixer rather than hand-editing the manifest keeps this on the supported
# path -- a validator refused the first attempt here for exactly that.
( cd "$APP" && "$SB" doctor --fix ) > "$WORK/doctor.log" 2>&1
grep -cE "INTERNET" "$APP/android/app/src/main/AndroidManifest.xml" \
  | sed 's/^/  INTERNET permission entries: /'
echo "  app_id=$APP_ID  base_url=$BASE"
echo "APP_ID=$APP_ID" >> /Volumes/build/route-b/android1.env
echo "APP=$APP" >> /Volumes/build/route-b/android1.env

step "2. shorebird release android --artifact apk"
# NO --release-version: that flag is aar/ios-framework only, and a full
# Android release takes its version from pubspec.yaml. Passing it exits 64
# before any build, which is what the first attempt here did.
echo "  pubspec version: $(grep '^version:' "$APP/pubspec.yaml")"
echo "  FLUTTER_VER=${FLUTTER_VER:-<pinned selector>}"
set +e
( cd "$APP" && SHOREBIRD_HOSTED_URL="$BASE" SHOREBIRD_TOKEN="$API_KEY" \
  "$SB" release android --artifact apk --no-confirm ${FLUTTER_VER:+--flutter-version=$FLUTTER_VER} ) \
  > "$WORK/release.log" 2>&1
RC=$?
set -e
echo "  exit=$RC"
echo "  --- hydration / coherence / engine lines ---"
grep -niE "precache|hydrat|coheren|engine|route b|route_b|downloading" "$WORK/release.log" \
  | head -25 | sed 's/^/    | /'
echo "  --- tail ---"
tail -15 "$WORK/release.log" | sed 's/^/    | /'
