#!/usr/bin/env bash
# cspell:words getsockname hydrat coheren armeabi embedding pristine CPPORT reqlog lstrip namelist
# ANDROID-CELL-SUPPLY-2 gate 6: does the ORDINARY Android developer workflow
# hydrate and release against the new macos-ios-android cell?
#
# The whole question is ATTRIBUTION, so every artifact request goes through a
# recording, forwarding origin that logs the body's sha256. A 200 proves only
# that something answered; the digest proves WHICH bytes answered. An
# identity-bearing object is from the new cell if and only if its bytes equal
# the staged member's.
#
# Isolated: a clone of the qualified CLI checkout with its own Flutter cache
# emptied to nothing (stamps included -- a stamp asserts what a cache is
# CLAIMED to hold, so leaving one makes the hydration test vacuous). The
# qualified checkout at /Volumes/build/route-b/shorebird-candidate is only ever
# read.
set -uo pipefail
REPO=/Users/mendell/shorebird
CELL=${CELL:-f85251f344600ae08196925a174e9cff8f0ff18e}
STAGE=${STAGE:-/Volumes/build/route-b/acs2/stage30}
CLI=${CLI:-/Volumes/build/route-b/acs2/cli}
CDN=${CDN:-http://localhost:8085}
FLUTTER_VER=e64eb0af52e1c43c3b21a39556d789538d0df9b3
PRODUCER_REV=${PRODUCER_REV:-f1a59b8a1609c51397601c36d586ad7763d57153}
FALLBACK_REV=${FALLBACK_REV:-69f9831c360d9152862ec3897c67fb09ae843f3b}
SB="$CLI/bin/shorebird"
FLUTTER_BIN="$CLI/bin/cache/flutter/$FLUTTER_VER/bin/flutter"
WORK=${WORK:-$(mktemp -d /Volumes/build/route-b/acs2/gate6.XXXXXX)}
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
CPPORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
ORIGIN="http://127.0.0.1:$PORT"
BASE="http://localhost:$CPPORT"
REQ="$WORK/requests.jsonl"
API_KEY="sb_api_acs2_$(date +%s)"
step(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
echo "WORK=$WORK" ; echo "WORK=$WORK" > /Volumes/build/route-b/acs2/gate6.env

step "0. recording origin -> the real CDN, and a throwaway control plane"
python3 "$REPO/selfhost/scripts/lib/acs2_recording_origin.py" "$PORT" "$CDN" "$REQ" \
  > "$WORK/origin.log" 2>&1 &
echo $! > "$WORK/origin.pid"
mkdir -p "$WORK/data"
( cd "$REPO/packages/code_push_server" && PORT=$CPPORT API_KEY="$API_KEY" \
  DB_BACKEND=sqlite STORAGE_BACKEND=file DATA_DIR="$WORK/data" \
  PUBLIC_BASE_URL="$BASE" LOG_FORMAT=json \
  URL_SIGNING_SECRET="$(openssl rand -hex 32)" \
  LOGIN_EMAIL="acs2@self-host.local" dart run bin/server.dart ) > "$WORK/server.log" 2>&1 &
echo $! > "$WORK/server.pid"
trap 'kill $(cat "$WORK/origin.pid" "$WORK/server.pid" 2>/dev/null) 2>/dev/null' EXIT
for _ in $(seq 1 60); do curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fsS "$BASE/healthz" >/dev/null || { echo "control plane did not start"; exit 1; }
code=$(curl -s -o /dev/null -w '%{http_code}' "$ORIGIN/flutter_infra_release/flutter/$CELL/engine_stamp.json")
[[ "$code" == 200 ]] && ok "the recording origin reaches the new cell through the CDN" \
                     || bad "recording origin cannot reach the cell (code $code)"

step "1. an ordinary flutter create, on the cache as it comes"
# BEFORE the cell is switched and the engine cache emptied, and deliberately so.
# `flutter create` is run BARE, and a bare flutter does not get the artifact
# origin injected -- that injection is the CLI's, in shorebird_process.dart. A
# first attempt wiped the whole cache first, so the bare bootstrap went to real
# upstream for `dart-sdk-darwin-arm64.zip` under a hash upstream has never
# published and unzipped a 404 body. That failure was my harness, not the cell.
#
# Creating the app first also keeps the fixture ordinary: it is exactly what
# `flutter create` gives a developer.
APP="$WORK/app"
( cd "$WORK" && "$FLUTTER_BIN" create --org dev.selfhost --platforms=android app ) \
  > "$WORK/create.log" 2>&1
[[ -d "$APP/android/app/src" ]] && ok "flutter create succeeded" \
  || { bad "flutter create failed"; tail -20 "$WORK/create.log"; }
APP_ID=$(curl -fsS -X POST "$BASE/api/v1/apps" -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' -d '{"display_name":"acs2-gate6"}' \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
cat > "$APP/shorebird.yaml" <<YAML
app_id: $APP_ID
base_url: $BASE
YAML
python3 "$REPO/selfhost/scripts/lib/add_shorebird_asset.py" "$APP/pubspec.yaml"
( cd "$APP" && SHOREBIRD_ARTIFACT_ORIGIN="$ORIGIN" "$SB" doctor --fix ) > "$WORK/doctor.log" 2>&1
grep -qE "INTERNET" "$APP/android/app/src/main/AndroidManifest.xml" \
  && ok "shorebird doctor --fix added the INTERNET permission" || bad "manifest not fixed"

step "2. NOW switch the cell and empty the engine hydration surface"
FC="$CLI/bin/cache/flutter/$FLUTTER_VER"
printf '%s\n' "$CELL" > "$FC/bin/internal/engine.version"
git -C "$FC" -c user.email=acs2@self-host.local -c user.name=ACS2 \
  commit -q -am "acs2 gate 6: select the macos-ios-android cell $CELL"
GOT=$(cat "$FC/bin/internal/engine.version")
[[ "$GOT" == "$CELL" ]] && ok "engine.version = $CELL" || bad "engine.version is $GOT"
[[ -z "$(git -C "$FC" status --porcelain)" ]] \
  && ok "and it is a COMMITTED blob, not an uncommitted edit" || bad "the flutter checkout is dirty"
# Scoped to the ENGINE. Deleting the whole cache would also delete the Dart SDK
# and the gradle wrapper, whose fetches are not what this gate measures and
# whose absence sends a bare bootstrap upstream. `artifacts/engine` plus the
# engine stamps IS the engine hydration surface -- and the stamps have to go,
# because a stamp asserts what a cache is CLAIMED to hold, so leaving one makes
# the test vacuous.
rm -rf "$FC/bin/cache/artifacts/engine" "$FC/bin/cache/downloads"
rm -f "$FC/bin/cache/engine.stamp" "$FC/bin/cache/engine_stamp.json" \
      "$FC/bin/cache/engine_stamp.stamp"
[[ ! -d "$FC/bin/cache/artifacts/engine" ]] && ok "no engine artifacts cached" \
                                            || bad "the engine artifact cache survived"
[[ ! -f "$FC/bin/cache/engine.stamp" ]] && ok "no engine stamp, so hydration cannot be skipped" \
                                        || bad "an engine stamp survived"
# A fresh Gradle home, so a cached io.flutter module cannot satisfy the Maven
# half and make the attribution test pass without a single request.
export GRADLE_USER_HOME="$WORK/gradle"
mkdir -p "$GRADLE_USER_HOME"
ok "GRADLE_USER_HOME is empty ($GRADLE_USER_HOME)"

step "3. shorebird release android --artifact apk, against the new cell"
BEFORE=$(wc -l < "$REQ")
set +e
( cd "$APP" && SHOREBIRD_ARTIFACT_ORIGIN="$ORIGIN" SHOREBIRD_HOSTED_URL="$BASE" \
  SHOREBIRD_TOKEN="$API_KEY" "$SB" release android --artifact apk --no-confirm ) \
  > "$WORK/release.log" 2>&1
RC=$?
set -e
echo "  exit=$RC"
echo "  --- hydration / engine / download lines ---"
grep -niE "precache|hydrat|coheren|engine|downloading|Failed to download" "$WORK/release.log" \
  | head -20 | sed 's/^/    | /'
echo "  --- tail ---"; tail -12 "$WORK/release.log" | sed 's/^/    | /'
[[ "$RC" == 0 ]] && ok "the release completed (exit 0)" || bad "the release exited $RC"
APK="$APP/build/app/outputs/flutter-apk/app-release.apk"
[[ -f "$APK" ]] && ok "an APK was produced ($(du -h "$APK" | cut -f1))" || bad "no APK"

step "4. ATTRIBUTION: every identity member came from the new cell"
# The decision is in selfhost/scripts/lib/acs2_attribute.py, not inline here, so
# it can be re-derived from the banked request log without re-running a
# six-minute Android build.
python3 "$REPO/selfhost/scripts/lib/acs2_attribute.py" "$REQ" "$STAGE" "$CELL" \
  "$REPO/selfhost/cdn/artifact_policy.conf" \
  "$REPO/selfhost/engine/route_b/lib/v2_canonicalize.py"
[[ $? -eq 0 ]] && ok "all 14 Android identity members served from the new cell, none via fallback" \
               || bad "an identity member was absent, wrong, or fallback-served"

step "4b. THE CLOSURE: 24 required objects, and the split is the measured one"
python3 - "$REQ" "$CELL" <<'PY2'
import json, re, sys
reqlog, cell = sys.argv[1], sys.argv[2]
rows = [json.loads(l) for l in open(reqlog) if l.strip()]
ident, transport = set(), set()
for r in rows:
    p = r['path'].lstrip('/')
    if not (cell in p or f'1.0.0-{cell}' in p):
        continue
    if re.search(r'android-(arm|arm64|x64)-release/', p) or 'download.flutter.io' in p:
        if r['status'] == 200:
            ident.add(p)
    elif re.search(r'android-(arm|arm64|x64|x86)(-profile)?/', p):
        transport.add(p)
print(f'    identity-bearing resolved : {len(ident)}')
print(f'    cache/transport resolved  : {len(transport)}')
print(f'    workflow closure resolved : {len(ident) + len(transport)}')
sys.exit(0 if (len(ident) == 14 and len(transport) == 10) else 1)
PY2
[[ $? -eq 0 ]] && ok "24 of 24 measured workflow objects resolved (14 identity + 10 transport)" \
               || bad "the workflow closure did not resolve as measured"

step "4c-pre. the discriminator is not vacuous"
# Before asserting "the APK contains zero occurrences of the fallback
# revision", establish that a fallback engine DOES name its own revision --
# otherwise the negative would hold for any bytes at all.
python3 - "$REPO/selfhost/cdn/overlay" "$FALLBACK_REV" <<'PY4'
import sys, zipfile
ov, fb = sys.argv[1], sys.argv[2]
jar = (f'{ov}/download.flutter.io/io/flutter/arm64_v8a_release/'
       f'1.0.0-{fb}/arm64_v8a_release-1.0.0-{fb}.jar')
with zipfile.ZipFile(jar) as z:
    n = [x for x in z.namelist() if x.endswith('libflutter.so')][0]
    b = z.read(n)
c = b.count(fb.encode())
print(f'    the fallback engine names its own revision {c} time(s) in libflutter.so')
sys.exit(0 if c == 1 else 1)
PY4
[[ $? -eq 0 ]] && ok "a fallback engine is identifiable by its revision string" \
               || bad "the fallback engine does not name its revision, so 4c would be vacuous"

step "4c. the engine INSIDE the APK is ours, not the fallback's"
# The strongest available statement about the shipped artifact. Everything above
# is about transport; this is about what a user installs.
#
# NOT byte-equality against the cell's jar. AGP strips debug symbols from native
# libraries in a release build, so the packaged libflutter.so is 6-9% of the
# jar's size and can never be byte-identical -- a first version of this control
# asserted equality and reported MISMATCH on three correct ABIs. The
# discriminator that survives stripping is the ENGINE REVISION STRING: a
# libflutter.so carries the revision it was built at, exactly once, and our
# producer revision and the fallback's are different 40-hex strings.
#
# Both directions are asserted, and the negative is not vacuous: the fallback's
# own jar was checked to contain ITS revision once, so "zero occurrences of the
# fallback revision" means the fallback engine is absent, not that the string
# never appears in any engine.
python3 - "$APK" "$STAGE" "$PRODUCER_REV" "$FALLBACK_REV" <<'PY3'
import sys, zipfile
apk, stage, prod, fb = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
pairs = [('arm64-v8a', 'arm64_v8a_release'),
         ('armeabi-v7a', 'armeabi_v7a_release'),
         ('x86_64', 'x86_64_release')]
bad = 0
with zipfile.ZipFile(apk) as az:
    names = set(az.namelist())
    for abi, art in pairs:
        entry = f'lib/{abi}/libflutter.so'
        if entry not in names:
            print(f'    ABSENT  {entry}')
            bad += 1
            continue
        b = az.read(entry)
        jar = f'{stage}/download.flutter.io/io/flutter/{art}/1.0.0-%H/{art}-1.0.0-%H.jar'
        with zipfile.ZipFile(jar) as jz:
            n = [x for x in jz.namelist() if x.endswith('libflutter.so')][0]
            j = jz.read(n)
        ours = b.count(prod.encode())
        theirs = b.count(fb.encode())
        note = f'{len(b):>10} bytes ({len(b) / len(j):.0%} of the unstripped jar)'
        if ours == 1 and theirs == 0:
            print(f'    {abi:12} OURS   {note}   producer x1, fallback x0')
        else:
            print(f'    {abi:12} WRONG  {note}   producer x{ours}, fallback x{theirs}')
            bad += 1
        # And libapp.so must be there at all: that is what gen_snapshot produced.
        if f'lib/{abi}/libapp.so' not in names:
            print(f'    {abi:12} has no libapp.so')
            bad += 1
sys.exit(1 if bad else 0)
PY3
[[ $? -eq 0 ]] && ok "all three ABIs ship OUR engine and a libapp.so" \
               || bad "the APK ships an engine that is not ours"

step "5. the cell still verifies after a real build hydrated from it"
out=$(bash "$REPO/selfhost/engine/route_b/verify_cell_members.sh" "$CELL" 2>&1)
echo "$out" | grep -q "CELL MEMBERS VERIFIED (30/30)" && ok "30/30" || bad "verifier not green"
out=$(bash "$REPO/selfhost/engine/route_b/verify_supported_state.sh" 2>&1 | tail -1)
[[ "$out" == "SUPPORTED STATE VERIFIED" ]] && ok "supported state still verified (the frozen stack is untouched)" \
                                           || bad "supported state broke: $out"

step "6. the qualified checkout was only ever read"
[[ "$(cat /Volumes/build/route-b/shorebird-candidate/bin/cache/flutter/$FLUTTER_VER/bin/internal/engine.version)" \
   == cd848320d605ff8af5060cabf9a8d1b35853f752 ]] \
  && ok "the qualified checkout still selects cd848320" || bad "the qualified checkout was modified"

step "RESULT"
echo "  requests: $REQ"
echo "  logs:     $WORK"
if [[ $fail -eq 0 ]]; then echo "  GATE 6 PASSED"; else echo "  GATE 6: $fail FAILURE(S)"; exit 1; fi
