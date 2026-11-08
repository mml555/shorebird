#!/usr/bin/env bash
# cspell:words uiautomator screencap dumpsys keyguard reqs
# ANDROID-FINAL-STACK-1 stage C: physical Android activation.
#
# The marker is read MECHANICALLY out of the accessibility tree
# (`uiautomator dump`), not by looking at a picture — a screenshot is kept
# alongside as visual evidence, but the assertion is on text the device
# reports. The marker lives in a never-inline function behind a DateTime guard
# so it cannot be constant-folded, which is what makes the change visible at
# all.
set -uo pipefail
source /Volumes/build/route-b/android1_control.env
ADB=$HOME/Library/Android/sdk/platform-tools/adb
DEV=${DEV:-3f72a543}
PKG=dev.selfhost.app
BASE="http://localhost:$PORT"
APK="$WORK/app/build/app/outputs/flutter-apk/app-release.apk"
SHOT="$WORK/shots"; mkdir -p "$SHOT"
step(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

# The on-screen marker, as the DEVICE reports it.
marker(){
  "$ADB" -s "$DEV" shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
  "$ADB" -s "$DEV" shell cat /sdcard/ui.xml 2>/dev/null \
    | tr '>' '\n' | grep -oE 'ANDROID-FINAL-V[0-9]-[A-Z]+' | head -1
}
# Screencap to a file on the device and PULL it. `exec-out screencap -p`
# streams through stdout, and on this device stdout carries a
# "[Warning] Multiple displays..." line first — so the captured .png was not a
# PNG at all, and two different screens produced byte-identical files because
# both were just the warning. Never read a screenshot through a channel that
# can also carry text.
shot(){
  "$ADB" -s "$DEV" shell screencap -p /sdcard/shot.png >/dev/null 2>&1
  "$ADB" -s "$DEV" pull /sdcard/shot.png "$SHOT/$1.png" >/dev/null 2>&1
  file "$SHOT/$1.png" | grep -q "PNG image" \
    || echo "    WARNING: $1.png is not a PNG"
}
reqs(){ grep -c "\"msg\":\"request\"" "$WORK/server.log" 2>/dev/null || echo 0; }
paths(){ python3 - "$WORK/server.log" <<'PY'
import json,sys
for l in open(sys.argv[1], errors='replace'):
    try: d=json.loads(l)
    except Exception: continue
    if d.get('msg')=='request': print('      %-6s %-42s %s' % (d['method'], d['path'], d['status']))
PY
}

step "7. re-arm the tunnel and install the RELEASE apk"
"$ADB" -s "$DEV" reverse "tcp:$PORT" "tcp:$PORT" >/dev/null
"$ADB" -s "$DEV" uninstall "$PKG" >/dev/null 2>&1 || true
"$ADB" -s "$DEV" install -r "$APK" 2>&1 | tail -2 | sed 's/^/    /'
BEFORE=$(reqs)
echo "  control-plane requests so far: $BEFORE"

step "8. human-equivalent launch, and the UNPATCHED marker"
"$ADB" -s "$DEV" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 8
shot 1_first_launch
M1=$(marker); echo "  marker on first launch: ${M1:-<none read>}"

step "9. normal discovery + download (no manual trigger)"
for i in $(seq 1 12); do
  if grep -q '"path":"/api/v1/patches/check"' "$WORK/server.log" 2>/dev/null; then break; fi
  sleep 5
done
sleep 6
echo "    requests the device made:"
paths
step "10. STAGED, not executed — the marker must still be V1 in this process"
shot 2_after_download
M2=$(marker); echo "  marker after download, before restart: ${M2:-<none read>}"

step "11. restart the app (the only lifecycle step) and read again"
"$ADB" -s "$DEV" shell am force-stop "$PKG" >/dev/null 2>&1
sleep 2
"$ADB" -s "$DEV" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 10
shot 3_after_restart
M3=$(marker); echo "  marker after restart: ${M3:-<none read>}"

step "12. what the device told the control plane"
paths
echo "    events recorded:"
curl -fsS "$BASE/api/v1/apps/$APP_ID/metrics" -H "Authorization: Bearer $API_KEY" \
  | python3 -m json.tool | sed 's/^/      /' | head -25

step "RESULT"
printf '  first launch : %s\n  after download: %s\n  after restart : %s\n' \
  "${M1:-?}" "${M2:-?}" "${M3:-?}"
if [ "$M1" = "ANDROID-FINAL-V1-RELEASE" ] && [ "$M3" = "ANDROID-FINAL-V2-PATCHED" ]; then
  echo "  PASS: release marker before, patched marker after restart"
else
  echo "  NOT PROVEN: see markers above"
fi
echo "  screenshots: $SHOT"
