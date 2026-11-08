#!/usr/bin/env bash
# cspell:words getsockname FLUT fsaq expanduser getmtime urllib urlparse uncontacted
# FLUTTER-STORAGE-AUTHORITY-1 qualification, against the REAL CLI.
#
# A logging origin records every request, so each control asserts on what the
# CLI actually asked rather than on what it was configured to ask.
set -uo pipefail
REPO=/Users/mendell/shorebird
SB=/Volumes/build/route-b/shorebird-candidate/bin/shorebird
PROBE=$REPO/selfhost/scripts/lib/origin_probe.py
WORK=$(mktemp -d /tmp/fsaq.XXXXXX)
KEY="sb_api_fsaq_$(date +%s)"
pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
step(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
free_port(){ python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

cleanup(){ pkill -f "origin_probe.py" 2>/dev/null; [ -f "$WORK/cp.pid" ] && kill "$(cat "$WORK/cp.pid")" 2>/dev/null; echo; echo "workdir: $WORK"; }
trap cleanup EXIT

step "0. throwaway control plane + a real Flutter app"
CP=$(free_port); mkdir -p "$WORK/data"
( cd "$REPO/packages/code_push_server" && PORT=$CP API_KEY="$KEY" \
  DB_BACKEND=sqlite STORAGE_BACKEND=file DATA_DIR="$WORK/data" \
  PUBLIC_BASE_URL="http://127.0.0.1:$CP" LOG_FORMAT=json \
  URL_SIGNING_SECRET="$(openssl rand -hex 32)" LOGIN_EMAIL="fsa@self-host.local" \
  dart run bin/server.dart ) > "$WORK/cp.log" 2>&1 &
echo $! > "$WORK/cp.pid"
for _ in $(seq 1 60); do curl -fsS "http://127.0.0.1:$CP/healthz" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fsS "http://127.0.0.1:$CP/healthz" >/dev/null || { echo "control plane failed"; exit 1; }
FL=/Volumes/build/route-b/shorebird-candidate/bin/cache/flutter/e64eb0af52e1c43c3b21a39556d789538d0df9b3/bin/flutter
( cd "$WORK" && "$FL" create --org dev.selfhost --platforms=android app ) >/dev/null 2>&1
APP="$WORK/app"
APP_ID=$(curl -fsS -X POST "http://127.0.0.1:$CP/api/v1/apps" -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' -d '{"display_name":"fsa"}' \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
printf 'app_id: %s\nbase_url: http://127.0.0.1:%s\n' "$APP_ID" "$CP" > "$APP/shorebird.yaml"
python3 "$REPO/selfhost/scripts/lib/add_shorebird_asset.py" "$APP/pubspec.yaml" >/dev/null
( cd "$APP" && "$SB" doctor --fix ) >/dev/null 2>&1
echo "  control plane :$CP  app $APP_ID"

# Runs `shorebird release android` with the given env, into $1.log, and reports
# the URLs the CLI's own verbose log shows it fetching.
run_release(){
  local name=$1; shift
  set +e
  ( cd "$APP" && env "$@" SHOREBIRD_TOKEN="$KEY" \
      "$SB" release android --artifact apk --no-confirm ) > "$WORK/$name.log" 2>&1
  echo $? > "$WORK/$name.rc"
  set -e
  # NOT `ls -t ... | head -1`: under `pipefail` the head closing early gives ls
  # a SIGPIPE and the pipeline returns 141, which aborted the first run of this
  # script after control 1 had already produced its data.
  local cli_log
  cli_log=$(python3 -c "import glob,os,sys; fs=glob.glob(os.path.expanduser('~/Library/Application Support/shorebird/logs/*.log')); print(max(fs, key=os.path.getmtime) if fs else '')")
  [ -n "$cli_log" ] || { echo "    no CLI log found"; : > "$WORK/$name.urls"; return 0; }
  grep -oE 'https?://[^ )"]*' "$cli_log" | grep -vE 'github\.com' | sort -u > "$WORK/$name.urls"
}

step "1. POSITIVE ROUTING — one variable, both halves"
P1=$(free_port); nohup python3 "$PROBE" "$P1" 404 "$WORK/p1.jsonl" >/dev/null 2>&1 &
sleep 1
run_release r1 "SHOREBIRD_ARTIFACT_ORIGIN=http://127.0.0.1:$P1"
echo "  exit=$(cat "$WORK/r1.rc")"
echo "  requests the probe received:"; sed 's/^/    /' "$WORK/p1.jsonl" | head -6
FLUT=$(grep -c 'flutter_infra_release' "$WORK/p1.jsonl" || true)
SHORE=$(grep -c '/shorebird/' "$WORK/p1.jsonl" || true)
[ "$FLUT" -gt 0 ] && ok "the FLUTTER half asked the configured origin ($FLUT req)" \
  || bad "the flutter half never asked the configured origin"
[ "$SHORE" -gt 0 ] && ok "the SHOREBIRD half asked it too ($SHORE req) — cell bytes included" \
  || bad "the shorebird/aot-tools half did NOT ask the configured origin"

step "2. POISON CONTROL — a refusal is not routed around"
if grep -q "127.0.0.1:$P1" "$WORK/r1.urls"; then
  ok "the CLI's own log records the configured origin"
else
  bad "the CLI's log does not mention the configured origin"
fi
if [ "$(cat "$WORK/r1.rc")" -ne 0 ]; then
  ok "the CLI FAILED on the origin's 404 (exit $(cat "$WORK/r1.rc"))"
else
  bad "the CLI succeeded despite the origin refusing everything"
fi
# Compare HOSTS, not substrings. A substring match called the very first run
# a leak: `http://127.0.0.1:PORT/download.shorebird.dev/shorebird/...` went to
# the configured origin and merely CARRIES `download.shorebird.dev` as its
# bucket PATH SEGMENT, which is deliberate — the self-host CDN mirrors that
# path shape. A URL is not a string for this purpose.
upstream_hosts(){
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlparse
bad = {'download.shorebird.dev', 'storage.googleapis.com'}
for line in open(sys.argv[1]):
    host = urlparse(line.strip()).hostname
    if host in bad:
        print(line.strip())
PY
}
upstream_hosts "$WORK/r1.urls" > "$WORK/r1.leaks"
LEAK=$(wc -l < "$WORK/r1.leaks" | tr -d ' ')
if [ "$LEAK" -eq 0 ]; then
  ok "ZERO requests whose HOST is upstream — no silent fallback"
else
  bad "$LEAK request(s) still went to an upstream host:"; sed 's/^/      /' "$WORK/r1.leaks"
fi

step "3. CHILD-PROCESS PROPAGATION"
# The flutter_infra_release path can only have been requested by the FLUTTER
# child process: the CLI itself never fetches that path shape. Its presence in
# the probe log is the propagation proof.
if grep -q 'flutter_infra_release/flutter/' "$WORK/p1.jsonl"; then
  ok "the flutter CHILD asked the configured origin ($(grep -o 'flutter_infra_release/flutter/[0-9a-f]\{8\}' "$WORK/p1.jsonl" | head -1)…)"
else
  bad "no flutter_infra_release request — the value did not reach the child"
fi

step "4. NO FAKE GREEN — an uncontacted origin must not pass"
# Same assertion as control 1, against a port where nothing listens. It MUST
# fail, or control 1 proves nothing.
P2=$(free_port)
run_release r2 "SHOREBIRD_ARTIFACT_ORIGIN=http://127.0.0.1:$P2"
: > "$WORK/p2.jsonl"
if [ "$(grep -c 'flutter_infra_release' "$WORK/p2.jsonl" || true)" -eq 0 ]; then
  ok "with nothing listening the probe log is empty, so control 1's assertion can fail"
else
  bad "the empty-origin control still recorded requests"
fi
if [ "$(cat "$WORK/r2.rc")" -ne 0 ]; then
  ok "the CLI also fails when the origin is unreachable (exit $(cat "$WORK/r2.rc"))"
else
  bad "the CLI succeeded against an unreachable origin"
fi

step "5. DEFAULT CONTROL — unset leaves upstream behaviour unchanged"
run_release r3 "SHOREBIRD_ARTIFACT_ORIGIN="
echo "  URLs fetched with nothing configured:"; sed 's/^/    /' "$WORK/r3.urls" | head -6
upstream_hosts "$WORK/r3.urls" > "$WORK/r3.upstream"
if [ "$(wc -l < "$WORK/r3.upstream" | tr -d ' ')" -gt 0 ]; then
  ok "upstream HOSTS are used when nothing is configured ($(wc -l < "$WORK/r3.upstream" | tr -d ' ') req)"
else
  bad "with nothing configured the CLI did not reach an upstream host at all"
fi
if grep -qE '127\.0\.0\.1:(6[0-9]{4}|[1-5][0-9]{4})/flutter_infra_release' "$WORK/r3.urls"; then
  bad "a local origin leaked into the default run"
else
  ok "no local origin leaked into the default run"
fi

step "RESULT"; printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
