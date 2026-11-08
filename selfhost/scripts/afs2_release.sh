#!/usr/bin/env bash
# cspell:words getsockname hydrat coheren armeabi embedding pristine reqs OPORT FSEL hashlib hexdigest namelist
# ANDROID-FINAL-STACK-2 stage A: an ordinary Android release against the NEW
# cell f85251f3…, with the shipped engine proven before anything is installed.
#
# Not the earlier stock-engine control. Everything here is bound to the new
# cell, and the binding is MECHANICAL: the Flutter checkout's engine.version is
# a committed blob naming the cell, the engine cache starts empty so every
# artifact must be fetched, and every fetch goes through a recording origin that
# logs the body digest.
set -uo pipefail
REPO=/Users/mendell/shorebird
CELL=${CELL:-f85251f344600ae08196925a174e9cff8f0ff18e}
PRODUCER_REV=${PRODUCER_REV:-f1a59b8a1609c51397601c36d586ad7763d57153}
FALLBACK_REV=${FALLBACK_REV:-69f9831c360d9152862ec3897c67fb09ae843f3b}
STAGE=${STAGE:-/Volumes/build/route-b/acs2/stage30}
QUALIFIED=/Volumes/build/route-b/shorebird-candidate
CLI=${CLI:-/Volumes/build/route-b/afs2/cli}
CDN=${CDN:-http://localhost:8085}
FLUTTER_VER=e64eb0af52e1c43c3b21a39556d789538d0df9b3
ADB=$HOME/Library/Android/sdk/platform-tools/adb
DEV=${DEV:-3f72a543}
SB="$CLI/bin/shorebird"
FLUTTER_BIN="$CLI/bin/cache/flutter/$FLUTTER_VER/bin/flutter"
WORK=${WORK:-$(mktemp -d /Volumes/build/route-b/afs2/work.XXXXXX)}
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
OPORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
ORIGIN="http://127.0.0.1:$OPORT"
BASE="http://localhost:$PORT"
REQ="$WORK/requests.jsonl"
API_KEY="sb_api_afs2_$(date +%s)"
step(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

step "0. a scratch CLI clone"
# A clone, because the QUALIFIED checkout is banked in SUPPORTED_STATE as clean
# and must only ever be read. cp -c is an APFS copy-on-write clone.
#
# THE CELL IS NOT SWITCHED HERE. It is switched in step 3, AFTER the app exists.
# `flutter create` is run bare, and a bare flutter does not get the artifact
# origin injected -- that injection is the CLI's. Switching engine.version first
# invalidates the Dart SDK stamp, so the bare bootstrap fetches
# dart-sdk-darwin-arm64.zip from REAL upstream under a hash upstream has never
# published and unzips a 404 body. Cost two runs to learn; written down here so
# it costs no more.
[[ -d "$CLI" ]] || { mkdir -p "$(dirname "$CLI")"; cp -Rc "$QUALIFIED" "$CLI"; }
FC="$CLI/bin/cache/flutter/$FLUTTER_VER"
[[ "$(cat "$QUALIFIED/bin/cache/flutter/$FLUTTER_VER/bin/internal/engine.version")" \
   == cd848320d605ff8af5060cabf9a8d1b35853f752 ]] \
  && ok "the qualified checkout is untouched (still cd848320)" || bad "the qualified checkout moved"
ok "scratch clone at $CLI"

step "1. control plane on :$PORT (reachable from the device), recording origin on :$OPORT"
mkdir -p "$WORK/data"
( cd "$REPO/packages/code_push_server" && PORT=$PORT API_KEY="$API_KEY" \
  DB_BACKEND=sqlite STORAGE_BACKEND=file DATA_DIR="$WORK/data" \
  PUBLIC_BASE_URL="$BASE" LOG_FORMAT=json \
  URL_SIGNING_SECRET="$(openssl rand -hex 32)" \
  LOGIN_EMAIL="afs2@self-host.local" dart run bin/server.dart ) > "$WORK/server.log" 2>&1 &
echo $! > "$WORK/server.pid"
python3 "$REPO/selfhost/scripts/lib/acs2_recording_origin.py" "$OPORT" "$CDN" "$REQ" \
  > "$WORK/origin.log" 2>&1 &
echo $! > "$WORK/origin.pid"
for _ in $(seq 1 60); do curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fsS "$BASE/healthz" >/dev/null || { echo "control plane did not start"; exit 1; }
"$ADB" -s "$DEV" reverse "tcp:$PORT" "tcp:$PORT" >/dev/null 2>&1 \
  && ok "adb reverse tcp:$PORT -> host" || bad "adb reverse failed"
c=$(curl -s -o /dev/null -w '%{http_code}' "$ORIGIN/flutter_infra_release/flutter/$CELL/engine_stamp.json")
[[ "$c" == 200 ]] && ok "the recording origin reaches the new cell" || bad "origin cannot reach the cell ($c)"

step "2. an ordinary app with an unmistakable, non-foldable marker"
# The marker sits in a never-inline function behind a DateTime guard so it
# cannot be constant-folded; a bare constant would make the patch invisible to
# the analyzer and the whole observation vacuous.
APP="$WORK/app"
# A LANE-SPECIFIC ORG, so the package name cannot collide with an earlier
# lane's app. `dev.selfhost.app` was reused across lanes and Android's backup
# auto-restore then repopulated this app's updater directory from a previous
# app built on a DIFFERENT engine -- our engine loaded that stale patch and
# aborted with `Wrong full snapshot version`. Distinct package, no shared
# backup, no collision.
( cd "$WORK" && "$FLUTTER_BIN" create --org dev.selfhost.afs2 --platforms=android app ) \
  > "$WORK/create.log" 2>&1
[[ -d "$APP/android/app/src" ]] && ok "flutter create succeeded" || bad "flutter create failed"
cat > "$APP/lib/main.dart" <<'DART'
import 'package:flutter/material.dart';

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String markerText() => DateTime.now().millisecondsSinceEpoch >= 0
    ? 'AFS2-V1-RELEASE'
    : 'AFS2-V1-RELEASE!';

void main() => runApp(const MarkerApp());

class MarkerApp extends StatelessWidget {
  const MarkerApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: Text(markerText(), style: const TextStyle(fontSize: 30)),
      ),
    ),
  );
}
DART
APP_ID=$(curl -fsS -X POST "$BASE/api/v1/apps" -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' -d '{"display_name":"android-final-stack-2"}' \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
cat > "$APP/shorebird.yaml" <<YAML
app_id: $APP_ID
base_url: $BASE
YAML
python3 "$REPO/selfhost/scripts/lib/add_shorebird_asset.py" "$APP/pubspec.yaml"
( cd "$APP" && SHOREBIRD_ARTIFACT_ORIGIN="$ORIGIN" "$SB" doctor --fix ) > "$WORK/doctor.log" 2>&1
grep -qE "INTERNET" "$APP/android/app/src/main/AndroidManifest.xml" \
  && ok "shorebird doctor --fix added the INTERNET permission" || bad "manifest not fixed"

step "3. NOW bind to the new cell, and empty the engine hydration surface"
printf '%s\n' "$CELL" > "$FC/bin/internal/engine.version"
git -C "$FC" -c user.email=afs2@self-host.local -c user.name=AFS2 \
  commit -q -am "afs2: select cell $CELL" 2>/dev/null
GOT=$(cat "$FC/bin/internal/engine.version")
[[ "$GOT" == "$CELL" ]] && ok "engine.version = $CELL" || bad "engine.version is $GOT"
[[ -z "$(git -C "$FC" status --porcelain)" ]] \
  && ok "and it is a COMMITTED blob, not an uncommitted edit" || bad "the flutter checkout is dirty"
# Scoped to the ENGINE. Deleting the whole cache also deletes the Dart SDK and
# the gradle wrapper, whose fetches are not what this lane measures.
rm -rf "$FC/bin/cache/artifacts/engine" "$FC/bin/cache/downloads"
rm -f "$FC/bin/cache/engine.stamp" "$FC/bin/cache/engine_stamp.json" "$FC/bin/cache/engine_stamp.stamp"
export GRADLE_USER_HOME="$WORK/gradle"; mkdir -p "$GRADLE_USER_HOME"
[[ ! -d "$FC/bin/cache/artifacts/engine" && ! -f "$FC/bin/cache/engine.stamp" ]] \
  && ok "no engine artifacts and no engine stamp — nothing can be skipped" \
  || bad "the cache was not emptied"
ok "GRADLE_USER_HOME is empty, so no cached io.flutter module can satisfy Maven"

step "4. shorebird release android --artifact apk"
set +e
( cd "$APP" && SHOREBIRD_ARTIFACT_ORIGIN="$ORIGIN" SHOREBIRD_HOSTED_URL="$BASE" \
  SHOREBIRD_TOKEN="$API_KEY" "$SB" release android --artifact apk --no-confirm ) \
  > "$WORK/release.log" 2>&1
RC=$?
set -e
echo "  exit=$RC"
tail -8 "$WORK/release.log" | sed 's/^/    | /'
[[ "$RC" == 0 ]] && ok "the release completed" || bad "the release exited $RC"
APK="$APP/build/app/outputs/flutter-apk/app-release.apk"
[[ -f "$APK" ]] && ok "APK produced ($(du -h "$APK" | cut -f1))" || bad "no APK"

step "5. RELEASE IDENTITY, as the control plane records it"
curl -fsS "$BASE/api/v1/apps/$APP_ID/releases" -H "Authorization: Bearer $API_KEY" > "$WORK/releases.json"
REL_ID=$(python3 -c 'import json;print(json.load(open("'"$WORK"'/releases.json"))["releases"][0]["id"])')
python3 - "$WORK/releases.json" "$CELL" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))['releases'][0]
print(f"    release id        {r['id']}")
print(f"    version           {r['version']}")
print(f"    flutter_revision  {r.get('flutter_revision')}")
PY
curl -fsS "$BASE/api/v1/apps/$APP_ID/releases/$REL_ID/artifacts" \
  -H "Authorization: Bearer $API_KEY" > "$WORK/release_artifacts.json"
python3 - "$WORK/release_artifacts.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
arts = d.get('artifacts', d if isinstance(d, list) else [])
for a in arts:
    print("    %-14s %-9s %12s  %s" % (a.get('arch'), a.get('platform'),
                                       a.get('size'), str(a.get('hash'))[:32]))
print(f"    release artifacts recorded: {len(arts)}")
PY
# The selector chain must bind to the cell MECHANICALLY, not by our claim.
grep -q "$CELL" "$FC/bin/internal/engine.version" && ok "engine.version binds the release to $CELL" \
                                                  || bad "engine.version does not name the cell"
FSEL=$(cat "$CLI/bin/internal/flutter.version")
[[ "$FSEL" == "$FLUTTER_VER" ]] && ok "Flutter selector $FSEL" || bad "Flutter selector is $FSEL"

step "6. THE SHIPPED ENGINE, before anything is installed"
# Mandatory gate: all three packaged libflutter.so must carry the Android
# producer revision and NOT the fallback revision. AGP strips debug symbols, so
# byte-equality with the cell's jar is impossible; the revision string survives
# stripping and discriminates the two engines.
python3 - "$APK" "$STAGE" "$PRODUCER_REV" "$FALLBACK_REV" <<'PY'
import hashlib, sys, zipfile
apk, stage, prod, fb = sys.argv[1:5]
print(f"    APK sha256  {hashlib.sha256(open(apk,'rb').read()).hexdigest()}")
pairs = [('arm64-v8a','arm64_v8a_release'), ('armeabi-v7a','armeabi_v7a_release'),
         ('x86_64','x86_64_release')]
bad = 0
with zipfile.ZipFile(apk) as az:
    names = set(az.namelist())
    for abi, art in pairs:
        e = f'lib/{abi}/libflutter.so'
        if e not in names:
            print(f'    {abi:12} ABSENT'); bad += 1; continue
        b = az.read(e)
        jar = f'{stage}/download.flutter.io/io/flutter/{art}/1.0.0-%H/{art}-1.0.0-%H.jar'
        with zipfile.ZipFile(jar) as jz:
            j = jz.read([x for x in jz.namelist() if x.endswith('libflutter.so')][0])
        o, t = b.count(prod.encode()), b.count(fb.encode())
        app = f'lib/{abi}/libapp.so'
        st = 'OURS' if (o == 1 and t == 0) else 'WRONG'
        if st == 'WRONG':
            bad += 1
        print(f'    {abi:12} {st:5} libflutter.so {len(b):>10} ({len(b)/len(j):.0%} of jar) '
              f'producer x{o} fallback x{t}   libapp.so '
              f'{hashlib.sha256(az.read(app)).hexdigest()[:16] if app in names else "ABSENT"}')
        if app not in names:
            bad += 1
sys.exit(1 if bad else 0)
PY
[[ $? -eq 0 ]] && ok "all three ABIs carry the producer revision and not the fallback" \
               || bad "a shipped ABI does not carry our engine — STOP CONDITION"

step "7. NETWORK ATTRIBUTION for the release build"
python3 "$REPO/selfhost/scripts/lib/acs2_attribute.py" "$REQ" "$STAGE" "$CELL" \
  "$REPO/selfhost/cdn/artifact_policy.conf" \
  "$REPO/selfhost/engine/route_b/lib/v2_canonicalize.py"
[[ $? -eq 0 ]] && ok "14/14 Android identity members from $CELL, none via fallback" \
               || bad "an identity member was absent, wrong, or fallback-served"

cat > /Volumes/build/route-b/afs2/control.env <<ENV
WORK=$WORK
PORT=$PORT
OPORT=$OPORT
API_KEY=$API_KEY
APP_ID=$APP_ID
REL_ID=$REL_ID
APP=$APP
CLI=$CLI
CELL=$CELL
APK=$APK
ENV

step "RESULT"
echo "  app_id=$APP_ID  release_id=$REL_ID  cell=$CELL"
echo "  work=$WORK"
if [[ $fail -eq 0 ]]; then echo "  STAGE A PASSED"; else echo "  STAGE A: $fail FAILURE(S)"; exit 1; fi
