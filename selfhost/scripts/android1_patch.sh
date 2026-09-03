#!/usr/bin/env bash
# cspell:words getsockname screencap uiautomator dumpsys keyguard coheren hydrat reqs
# ANDROID-FINAL-STACK-1 stage B: an ordinary Android code patch, through the
# normal producer, against the self-hosted control plane.
set -uo pipefail
source /Volumes/build/route-b/android1_control.env
SB=/Volumes/build/route-b/shorebird-candidate/bin/shorebird
BASE="http://localhost:$PORT"
step(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

step "3. change the marker — one line, in the never-inline function"
python3 - "$APP/lib/main.dart" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
assert "'ANDROID-FINAL-V1-RELEASE'" in s, 'marker not found'
s = s.replace("'ANDROID-FINAL-V1-RELEASE'", "'ANDROID-FINAL-V2-PATCHED'")
s = s.replace("'ANDROID-FINAL-V1-RELEASE!'", "'ANDROID-FINAL-V2-PATCHED!'")
open(p, 'w').write(s)
print('  marker now ANDROID-FINAL-V2-PATCHED')
PY

step "4. shorebird patch android"
set +e
( cd "$APP" && SHOREBIRD_HOSTED_URL="$BASE" SHOREBIRD_TOKEN="$API_KEY" \
  "$SB" patch android --release-version 1.0.0+1 --no-confirm ) \
  > "$WORK/patch.log" 2>&1
RC=$?
set -e
echo "  exit=$RC"
tail -18 "$WORK/patch.log" | sed 's/^/    | /'

step "5. what the control plane holds"
curl -fsS "$BASE/api/v1/apps/$APP_ID/releases/1/patches" -H "Authorization: Bearer $API_KEY" \
  | python3 -c 'import json,sys
d=json.load(sys.stdin)
for p in d["patches"]:
    print(f"    patch id={p[\"id\"]} number={p[\"number\"]} status={p[\"status\"]} channel={p[\"channel\"]}")
    for a in p["artifacts"]:
        print(f"      artifact {a[\"arch\"]:10} {a[\"platform\"]:8} {a[\"size\"]:>9} bytes  hash={a[\"hash\"][:16]}…")'
step "6. the audit trail for this release"
curl -fsS "$BASE/admin/audit?release_id=1&limit=50" -H "Authorization: Bearer $API_KEY" > "$WORK/audit.json"
python3 - "$WORK/audit.json" <<'PY'
import json, sys
for e in json.load(open(sys.argv[1]))['events']:
    print('    %-26s %-8s %-5s patch=%-5s %s' % (
        e['operation'], e['result'], e['http_status'],
        e['patch_number'], str(e.get('detail') or '')[:44]))
PY
