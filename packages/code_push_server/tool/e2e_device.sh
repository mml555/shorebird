#!/usr/bin/env bash
#
# End-to-end on-device smoke test against a running code_push_server.
# Drives the REAL Shorebird CLI + native updater through the full lifecycle:
#   init -> release -> install -> baseline -> patch -> promote -> apply -> verify
#
# Usage:
#   APP_DIR=/path/to/flutterapp tool/e2e_device.sh android <adb-serial> [base_url]
#   APP_DIR=/path/to/flutterapp tool/e2e_device.sh ios     <device-udid> [base_url]
#
# Env:
#   APP_DIR         Flutter app dir (has shorebird.yaml / lib/main.dart)   [required]
#   BASE_URL / $3   server base url, LAN-reachable from the device   [default http://10.0.0.7:8091]
#   SHOREBIRD_TOKEN API key (default sb_api_selfhost_dev); or rely on an OAuth session
#   SHOTS           screenshot output dir                            [default /tmp/cps_shots]
set -euo pipefail

PLATFORM="${1:?usage: e2e_device.sh <android|ios> <device> [base_url]}"
DEVICE="${2:?device id required}"
BASE="${3:-${BASE_URL:-http://10.0.0.7:8091}}"
APP_DIR="${APP_DIR:?set APP_DIR to the Flutter app dir}"
KEY="${SHOREBIRD_TOKEN:-sb_api_selfhost_dev}"
SHOTS="${SHOTS:-/tmp/cps_shots}"; mkdir -p "$SHOTS"
PKG=com.example.spikeapp
MAIN="$APP_DIR/lib/main.dart"
STAMP="$(date +%H%M%S)"
PATCHED="E2E ${PLATFORM} patch ${STAMP} - pushes:"
BASELINE="You have pushed the button this many times:"

export SHOREBIRD_HOSTED_URL="$BASE"
export SHOREBIRD_TOKEN="$KEY"

say(){ echo; echo "== $* =="; }
# Replace the first `const Text('...')` in main.dart with $1 (the body label).
set_label(){ python3 - "$MAIN" "$1" <<'PY'
import re,sys
path,new=sys.argv[1],sys.argv[2]
s=open(path).read()
esc=new.replace("\\","\\\\").replace("'","\\'")
s=re.sub(r"const Text\('(?:[^'\\]|\\.)*'\),", "const Text('%s'),"%esc, s, count=1)
open(path,'w').write(s)
PY
}

cd "$APP_DIR"

say "reset app to baseline + init a fresh app on $BASE"
set_label "$BASELINE"
shorebird init --display-name "e2e-$PLATFORM-$STAMP" --force >/dev/null 2>&1 || \
  shorebird init --display-name "e2e-$PLATFORM-$STAMP" --force
# ensure base_url points the on-device updater at our server
if grep -q '^base_url:' shorebird.yaml; then
  sed -i '' "s#^base_url:.*#base_url: $BASE#" shorebird.yaml
else
  printf '\nbase_url: %s\n' "$BASE" >> shorebird.yaml
fi
APPID=$(grep '^app_id:' shorebird.yaml | awk '{print $2}')
echo "app_id=$APPID  base_url=$BASE"

say "release ($PLATFORM)"
if [ "$PLATFORM" = android ]; then
  yes | shorebird release android --artifact apk --target-platform android-arm64 2>&1 | grep -E "Published Release|error|Error" | head -3 || true
  APK="$APP_DIR/build/app/outputs/flutter-apk/app-release.apk"
  adb -s "$DEVICE" uninstall "$PKG" >/dev/null 2>&1 || true
  adb -s "$DEVICE" install "$APK" | tail -1
  adb -s "$DEVICE" shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1
  sleep 5
  adb -s "$DEVICE" shell screencap -p /sdcard/e2e_base.png >/dev/null 2>&1
  adb -s "$DEVICE" pull /sdcard/e2e_base.png "$SHOTS/e2e_${PLATFORM}_base.png" >/dev/null 2>&1
else
  # No Apple ID in Xcode? Build unsigned, then resign with an existing dev cert
  # + provisioning profile (that already includes this device). See ios_resign.sh.
  # Only IOS_PROFILE is required now — team + bundle are read from the profile,
  # and the identity is auto-selected if there's exactly one (else set IOS_IDENTITY).
  : "${IOS_PROFILE:?set IOS_PROFILE to a .mobileprovision path that includes this device}"
  yes | shorebird release ios --no-codesign 2>&1 | grep -E "Published Release|error|Error|Reason" | head -5 || true
  APP_BUNDLE=$(find "$APP_DIR/build/ios/archive" -name "Runner.app" -path "*Products/Applications*" 2>/dev/null | head -1)
  echo "app bundle: $APP_BUNDLE"
  IOS_DEVICE_UDID="$DEVICE" "$(dirname "$0")/ios_resign.sh" "$APP_BUNDLE" "${IOS_IDENTITY:-}" "$IOS_PROFILE"
  xcrun devicectl device install app --device "$DEVICE" "$APP_BUNDLE" 2>&1 | grep -iE "installed|error|locked" | tail -3
  xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$PKG" 2>&1 | grep -iE "launched|error" | tail -1 || true
  sleep 6
  echo "(iOS: verify via server events below; network pairing blocks screenshots)"
fi
[ "$PLATFORM" = android ] && echo "baseline screenshot -> $SHOTS/e2e_${PLATFORM}_base.png"

say "patch: change the label + shorebird patch"
set_label "$PATCHED"
PATCH_FLAGS="--release-version=1.0.0+1"
[ "$PLATFORM" = ios ] && PATCH_FLAGS="$PATCH_FLAGS --no-codesign"  # patch only diffs; device already runs the signed app
yes | shorebird patch "$PLATFORM" $PATCH_FLAGS 2>&1 | grep -E "Published Patch|error|Error" | head -3 || true

say "device check returns the patch (signed URL)"
curl -s -X POST "$BASE/api/v1/patches/check" \
  -d "{\"app_id\":\"$APPID\",\"release_version\":\"1.0.0+1\",\"platform\":\"$PLATFORM\",\"arch\":\"aarch64\",\"channel\":\"stable\"}" | head -c 300; echo

say "apply on device (relaunch twice) + patched screenshot"
if [ "$PLATFORM" = android ]; then
  for _ in 1 2; do adb -s "$DEVICE" shell am force-stop "$PKG"; adb -s "$DEVICE" shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1; sleep 8; done
  adb -s "$DEVICE" shell screencap -p /sdcard/e2e_patched.png >/dev/null 2>&1
  adb -s "$DEVICE" pull /sdcard/e2e_patched.png "$SHOTS/e2e_${PLATFORM}_patched.png" >/dev/null 2>&1
  echo "updater log:"; adb -s "$DEVICE" logcat -d 2>/dev/null | grep -iE "updater::.*applied|active path" | tail -2 || true
else
  for _ in 1 2; do xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$PKG" >/dev/null 2>&1 || true; sleep 10; done
  echo "iOS verification is via server events (updater's own reports):"
  grep -E "download/|__patch_(download|install)__|\"platform\": \"ios\"" /tmp/cps_e2e.log 2>/dev/null | tail -6 || true
fi
say "E2E ($PLATFORM) flow complete"
if [ "$PLATFORM" = android ]; then
  echo "inspect $SHOTS/e2e_${PLATFORM}_{base,patched}.png to confirm the label changed"
else
  echo "confirm the server received the iPhone's __patch_download__/__patch_install__ (platform: ios) events above"
fi
