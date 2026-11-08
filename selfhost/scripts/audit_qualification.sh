#!/usr/bin/env bash
# cspell:words getsockname reqs keyhits equest hashlib hexdigest
# CONTROL-PLANE-AUDIT-1 — the LIVE ceiling control.
#
# The unit tests (packages/code_push_server/test/audit_test.dart) prove the
# audit trail's structural properties at the request level. This script proves
# the one property only the real product can show:
#
#   a REAL `shorebird patch` run that the PRODUCER refuses sends no
#   patch-create request, and the probe that says so is capable of failing.
#
# Shape, and why each step is here:
#
#   1. snapshot the audit ceiling               (MAX(id) before anything)
#   2. run a real `shorebird patch` the producer refuses locally
#   3. assert no `patch.create` event above the ceiling
#   4. ANTI-VACUITY: send one known-valid create and assert the SAME probe
#      reports it. Without step 4, step 3 passes identically against a logger
#      that records nothing at all — which is exactly how gate 6E's
#      "no patch-creation request in the log" check turned out to be vacuous.
#   5. assert a deliberately distinctive fake token occurs zero times in the
#      captured server output.
#
# Runs a THROWAWAY control plane in a temp dir on a free port. It never touches
# `cps-ios`, `cps-android`, any cell, any device, or any release.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SERVER_DIR="$REPO/packages/code_push_server"
SHOREBIRD="${SHOREBIRD_BIN:-$HOME/.shorebird/bin/shorebird}"
# A real Flutter project that SUPPORTS ANDROID. That matters: `PatchCommand`
# runs `assertPreconditions` before it talks to the server at all, so a fixture
# with no `android/app/src` refuses without ever reaching the control plane —
# and step 4 below would then be measuring an empty interval rather than a
# producer that got as far as the server and stopped.
FIXTURE_SRC="${FIXTURE_SRC:-$REPO/selfhost/fixtures/android_signing_app}"

API_KEY="sb_api_audit_qualification_$(date +%s)"
# Presented to the server on purpose, and must never come back out of it.
CANARY="sb_api_CANARY_DO_NOT_LOG_8f31c0aa4d5e"

WORK="$(mktemp -d /tmp/audit-qual.XXXXXX)"
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
BASE="http://127.0.0.1:$PORT"
LOG="$WORK/server.log"
SERVER_PID=""

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  echo
  echo "server log:  $LOG"
  echo "workdir:     $WORK   (keep it; nothing here is cleaned up automatically)"
}
trap cleanup EXIT

# --- one-call audit reads, exactly as an operator would make them -----------
audit() { curl -sS -H "Authorization: Bearer $API_KEY" "$BASE/admin/audit?$1"; }
jqf()   { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)"; }

step "0. boot a throwaway control plane on :$PORT (JSON logs)"
mkdir -p "$WORK/data"
(
  cd "$SERVER_DIR"
  PORT="$PORT" \
  API_KEY="$API_KEY" \
  DB_BACKEND=sqlite STORAGE_BACKEND=file \
  DATA_DIR="$WORK/data" \
  PUBLIC_BASE_URL="$BASE" \
  LOG_FORMAT=json \
  URL_SIGNING_SECRET="$(openssl rand -hex 32)" \
  LOGIN_EMAIL="audit@self-host.local" \
  dart run bin/server.dart
) >"$LOG" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 60); do
  curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS "$BASE/healthz" >/dev/null || { echo "server did not start; see $LOG"; exit 1; }
echo "  up (pid $SERVER_PID)"

step "1. create an app + release, then prepare the fixture"
APP_ID="$(curl -fsS -X POST "$BASE/api/v1/apps" \
  -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' \
  -d '{"display_name":"audit-qualification"}' | jqf "d['id']")"
# `flutter_revision` and `flutter_version` are not optional in practice: the
# CLI's `Release.fromJson` casts both to String, so a release created without
# them makes `shorebird patch` die with a FormatException while FETCHING
# releases. That is a refusal, and it even reaches the server — but it is a
# client parse bug against a release no real `shorebird release` would produce,
# not the release-resolution refusal this control means to exercise. Found by
# reading the producer log rather than trusting the exit code.
FLUTTER_REV="$(sed -n 1p "$REPO/bin/internal/flutter.version" 2>/dev/null || echo 0000000000000000000000000000000000000000)"
REL="$(curl -fsS -X POST "$BASE/api/v1/apps/$APP_ID/releases" \
  -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' \
  -d "{\"version\":\"1.0.0+1\",\"flutter_revision\":\"$FLUTTER_REV\",\"flutter_version\":\"3.35.0\"}" \
  | jqf "d['release']['id']")"
echo "  app_id=$APP_ID  release_id=$REL"

APP_DIR="$WORK/app"
cp -R "$FIXTURE_SRC" "$APP_DIR"
rm -rf "$APP_DIR/.dart_tool" "$APP_DIR/build"
cat > "$APP_DIR/shorebird.yaml" <<YAML
app_id: $APP_ID
base_url: $BASE
YAML

step "2. SNAPSHOT the audit ceiling"
CEILING="$(audit 'limit=0' | jqf "d['ceiling']")"
echo "  ceiling = $CEILING"

step "3. run a real \`shorebird patch\` the producer refuses"
# The refusal is at RELEASE RESOLUTION: no release matches the version asked
# for, so the producer aborts. It authenticates and reads first, so the
# interval is NOT empty of traffic — only of patch-create requests.
#
# `publishPatch` (the only caller of POST /patches) is the LAST step of
# `PatchCommand.createPatch`, after `patcher.createPatchArtifacts` — which is
# where the private-construction admission gate that refused gate 6E lives. So
# every producer-side refusal precedes any patch-create request by
# construction, and this cheap refusal exercises the same ordering without a
# cell, a build, or a device.
#
# Requests logged BEFORE the producer starts, so the "reached the control
# plane" assertion below counts the PRODUCER'S own traffic and not this
# script's setup calls. Counting the running total was the first version of
# this check, and it passed while the producer had in fact refused locally
# without ever opening a socket — the same vacuity this whole lane is about.
REQS_BEFORE="$(grep -c '"msg":"request"' "$LOG" || true)"
set +e
( cd "$APP_DIR" && \
  SHOREBIRD_HOSTED_URL="$BASE" \
  SHOREBIRD_TOKEN="$API_KEY" \
  "$SHOREBIRD" patch android \
    --release-version 99.99.99+99 --no-confirm ) \
  >"$WORK/producer.log" 2>&1
PRODUCER_RC=$?
set -e
echo "  producer exit=$PRODUCER_RC"
tail -5 "$WORK/producer.log" | sed 's/^/    | /'
if [ "$PRODUCER_RC" -ne 0 ]; then
  ok "the producer refused (exit $PRODUCER_RC)"
else
  bad "the producer did NOT refuse — this control measures nothing as run"
fi
# It must have TALKED to the server, or the interval proves nothing about
# whether a request would have been recorded.
REQS_AFTER="$(grep -c '"msg":"request"' "$LOG" || true)"
PRODUCER_REQS=$((REQS_AFTER - REQS_BEFORE))
if [ "$PRODUCER_REQS" -gt 0 ]; then
  ok "the producer itself reached the control plane ($PRODUCER_REQS requests)"
else
  bad "the producer never reached the control plane; it refused locally before opening a socket, so step 4 would measure an empty interval. See \$WORK/producer.log — the usual cause is a missing platform directory, which assertPreconditions rejects first."
fi
# And what it asked for must be visible, so the refusal is placed in the flow.
if grep -q "/api/v1/apps/$APP_ID/releases" "$LOG"; then
  ok "the producer got as far as resolving the release"
else
  bad "the producer did not reach release resolution"
fi
# Assert the REASON, not just the exit code. Two earlier versions of this
# script "passed" on refusals that were not the one being claimed: a missing
# android/ directory (refused before any socket) and a FormatException parsing
# a hand-made release (refused for a client bug). An exit code alone does not
# distinguish them.
if grep -q 'Release not found: "99.99.99+99"' "$WORK/producer.log"; then
  ok "the refusal is release resolution, as claimed"
else
  bad "the producer refused for some OTHER reason; this control is only meaningful for a refusal that happens after the server is reached and before publish. See \$WORK/producer.log"
fi

step "4. NEGATIVE reading — no patch-create event above the ceiling"
N="$(audit "after=$CEILING&operation=patch.create" | jqf "d['count']")"
if [ "$N" -eq 0 ]; then
  ok "no patch.create event after id $CEILING"
else
  bad "expected 0 patch.create events after id $CEILING, got $N"
fi

step "5. ANTI-VACUITY — the same probe must report a real create"
CREATE="$(curl -fsS -X POST "$BASE/api/v1/apps/$APP_ID/patches" \
  -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' \
  -D "$WORK/create.headers" \
  -d "{\"release_id\":$REL}")"
RID="$(sed -n 's/^[Xx]-[Rr]equest-[Ii]d: *//p' "$WORK/create.headers" | tr -d '\r')"
echo "  created: $CREATE"
echo "  X-Request-Id: $RID"
AFTER="$(audit "after=$CEILING&operation=patch.create")"
N2="$(echo "$AFTER" | jqf "d['count']")"
if [ "$N2" -eq 1 ]; then
  ok "the probe reports exactly 1 patch.create after id $CEILING"
else
  bad "expected exactly 1 patch.create after the ceiling, got $N2"
fi
for field in "d['events'][0]['result']=='success'" \
             "d['events'][0]['release_id']==$REL" \
             "d['events'][0]['app_id']=='$APP_ID'" \
             "d['events'][0]['patch_number'] is not None" \
             "d['events'][0]['actor_credential'].startswith('bootstrap:')" \
             "d['events'][0]['request_id']=='$RID'"; do
  if [ "$(echo "$AFTER" | jqf "$field")" = "True" ]; then
    ok "event $field"
  else
    bad "event $field  (got: $(echo "$AFTER" | jqf "d['events'][0]"))"
  fi
done

step "6. a REFUSED create is recorded as refused, not absent"
C2="$(audit 'limit=0' | jqf "d['ceiling']")"
curl -sS -o /dev/null -X POST "$BASE/api/v1/apps/$APP_ID/patches" \
  -H "Authorization: Bearer $CANARY" -H 'Content-Type: application/json' \
  -d "{\"release_id\":$REL}"
REF="$(audit "after=$C2&operation=patch.create")"
if [ "$(echo "$REF" | jqf "d['count']==1 and d['events'][0]['result']=='refused'")" = "True" ]; then
  ok "the create refused for a bad credential is recorded as refused"
else
  bad "a refused create was not recorded as refused: $REF"
fi

step "7. secret redaction — the canary must occur zero times"
# Everything an operator would actually read: the shipped log sink and the
# durable trail.
ALL="$WORK/captured.txt"
{ cat "$LOG"; audit 'limit=1000'; } > "$ALL"
HITS="$(grep -c "$CANARY" "$ALL" || true)"
KEYHITS="$(grep -c "$API_KEY" "$ALL" || true)"
if [ "$HITS" -eq 0 ]; then ok "canary occurs 0 times in captured output"
else bad "canary occurs $HITS times in captured output"; fi
if [ "$KEYHITS" -eq 0 ]; then ok "the real API key occurs 0 times in captured output"
else bad "the real API key occurs $KEYHITS times in captured output"; fi
# Not vacuous: the same capture DOES contain the audit events.
if grep -q '"msg":"audit"' "$ALL" && grep -q 'patch.create' "$ALL"; then
  ok "the searched capture really does contain the audit events"
else
  bad "the capture held no audit events — the redaction check was vacuous"
fi

step "8. the acceptance question, answered from the trail alone"
# Two readings, and an operator needs both.
#
# RELEASE-SCOPED is the precise one: it sees every attempt that got far enough
# to name a release.
Q="$(audit "release_id=$REL&operation=patch.create,patch.promote,patch.withdraw")"
echo "$Q" | python3 -m json.tool | sed 's/^/    /'
if [ "$(echo "$Q" | jqf "d['count']==1 and d['events'][0]['result']=='success'")" = "True" ]; then
  ok "release-scoped: the successful create for release $REL is there"
else
  bad "release-scoped query: $(echo "$Q" | jqf "d")"
fi
# APP-SCOPED is the COMPLETE one. `release_id` arrives in the request BODY on
# `patch.create`, and a request refused by authentication is never parsed --
# deliberately: buffering an unauthenticated body to decorate an audit event
# would be a denial-of-service surface on the one route that can reject at the
# header. Such an attempt still carries its operation and its app, both from
# the path, so the app-scoped query is the one that sees everything.
QA="$(audit "app_id=$APP_ID&operation=patch.create,patch.promote,patch.withdraw")"
RESULTS="$(echo "$QA" | jqf "sorted(e['result'] for e in d['events'])")"
echo "  app-scoped results: $RESULTS"
if [ "$RESULTS" = "['refused', 'success']" ]; then
  ok "app-scoped: both the success and the pre-auth refusal are visible"
else
  bad "app-scoped query returned results $RESULTS (expected refused + success)"
fi

step "9. identity + tenancy (CONTROL-PLANE-AUDIT-2), over the real wire"
# The suite proves these properties at the request level; this is the
# end-to-end confirmation that the same rows come out of a real server, through
# the real endpoint, with the real JSON log sink.
C3="$(audit 'limit=0' | jqf "d['ceiling']")"
TEAM="$(curl -fsS -X POST "$BASE/admin/users?email=teammate@example.com" \
  -H "Authorization: Bearer $API_KEY")"
TEAM_ID="$(echo "$TEAM" | jqf "d['user_id']")"
TEAM_KEY="$(echo "$TEAM" | jqf "d['api_key']")"
echo "  issued a key for user $TEAM_ID"
# Grant app access, then remove it.
curl -fsS -o /dev/null -X POST \
  "$BASE/admin/apps/$APP_ID/collaborators?email=teammate@example.com&role=developer" \
  -H "Authorization: Bearer $API_KEY"
curl -fsS -o /dev/null -X DELETE \
  "$BASE/admin/apps/$APP_ID/collaborators/$TEAM_ID" \
  -H "Authorization: Bearer $API_KEY"
# And an attempt by someone with no business doing it.
curl -sS -o /dev/null -X POST \
  "$BASE/admin/apps/$APP_ID/collaborators?email=outsider@example.com&role=owner" \
  -H "Authorization: Bearer $TEAM_KEY"

# The credential issue is typed, and identifies the key WITHOUT storing it.
UC="$(audit "after=$C3&operation=user.create")"
if [ "$(echo "$UC" | jqf "d['count']==1 and d['events'][0]['result']=='success' and d['events'][0]['target']=='teammate@example.com' and d['events'][0]['target_kind']=='user'")" = "True" ]; then
  ok "user.create is a typed success naming the account"
else
  bad "user.create row: $(echo "$UC" | jqf "d")"
fi
FP="$(echo "$UC" | jqf "__import__('json').loads(d['events'][0]['detail'])['api_key_issued']")"
REAL_FP="$(python3 -c "import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:12])" "$TEAM_KEY")"
if [ "$FP" = "$REAL_FP" ]; then
  ok "the issued key is identified by fingerprint ($FP)"
else
  bad "api_key_issued=$FP does not fingerprint the key that was returned"
fi

# THE ACCEPTANCE QUESTION for AUDIT-2.
ACC="$(audit "app_id=$APP_ID&operation=app.collaborator.add,app.collaborator.remove")"
echo "$ACC" | python3 -m json.tool | sed 's/^/    /'
SHAPE="$(echo "$ACC" | jqf "[e['operation']+':'+e['result'] for e in d['events']]")"
if [ "$SHAPE" = "['app.collaborator.add:success', 'app.collaborator.remove:success', 'app.collaborator.add:refused']" ]; then
  ok "\"who changed access to app X, what did they attempt, did it succeed\" is answered"
else
  bad "access history shape was $SHAPE"
fi

# No new secret may have leaked, including the key just issued.
ALL2="$WORK/captured2.txt"
{ cat "$LOG"; audit 'limit=1000'; } > "$ALL2"
LEAKS=0
for secret in "$CANARY" "$API_KEY" "$TEAM_KEY"; do
  n="$(grep -c "$secret" "$ALL2" || true)"
  [ "$n" -eq 0 ] || { LEAKS=$((LEAKS+1)); echo "    leaked: $n occurrence(s)"; }
done
if [ "$LEAKS" -eq 0 ]; then
  ok "no credential (canary, operator key, or newly issued key) is in the output"
else
  bad "$LEAKS credential(s) appear in captured output"
fi
# Reads still write nothing.
C4="$(audit 'limit=0' | jqf "d['ceiling']")"
curl -fsS -o /dev/null "$BASE/admin/orgs/1/members" -H "Authorization: Bearer $API_KEY"
curl -fsS -o /dev/null "$BASE/admin/apps/$APP_ID/collaborators" -H "Authorization: Bearer $API_KEY"
if [ "$(audit 'limit=0' | jqf "d['ceiling']")" = "$C4" ]; then
  ok "admin reads wrote no audit rows"
else
  bad "an admin read wrote an audit row"
fi

step "RESULT"
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
