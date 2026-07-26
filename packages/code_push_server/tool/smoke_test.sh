#!/usr/bin/env bash
#
# Stage 1 smoke test: drives the full CLI + device wire sequence against a
# running code_push_server with curl, and exercises the Stage 1 additions —
# real sha256 verification, lifecycle gating, withdraw/rollback, and range.
#
# Usage:
#   dart run bin/server.dart &
#   tool/smoke_test.sh                # or: BASE=... KEY=... tool/smoke_test.sh
set -euo pipefail

B="${BASE:-http://localhost:8080}"
KEY="${KEY:-sb_api_selfhost_dev}"
# Extra curl flags — e.g. CURL_OPTS=-k to accept a self-signed cert when testing
# against a local TLS (Caddy `tls internal`) endpoint.
CURL_OPTS="${CURL_OPTS:-}"
H="Authorization: Bearer $KEY"
tmp="$(mktemp -d)"
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
sz()  { wc -c < "$1" | tr -d ' '; }
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; exit 1; }

for _ in $(seq 1 30); do curl $CURL_OPTS -s "$B/" >/dev/null 2>&1 && break; sleep 0.2; done

echo "== create app / release =="
APPID=$(curl $CURL_OPTS -s -H "$H" -X POST "$B/api/v1/apps" -d '{"organization_id":1,"display_name":"demo"}' | sed -E 's/.*"id":"([^"]+)".*/\1/')
RELID=$(curl $CURL_OPTS -s -H "$H" -X POST "$B/api/v1/apps/$APPID/releases" -d '{"version":"1.0.0+1","flutter_revision":"309dd657"}' | sed -E 's/.*"release":\{"id":([0-9]+).*/\1/')

echo "== finalize BEFORE artifacts verified must fail closed (409) =="
CODE=$(curl $CURL_OPTS -s -o /dev/null -w "%{http_code}" -H "$H" -X PATCH "$B/api/v1/apps/$APPID/releases/$RELID" -d '{"status":"active","platform":"android"}')
[ "$CODE" = "409" ] && pass "unverified release finalize rejected (409)" || fail "expected 409, got $CODE"

echo "== register + upload release artifact with REAL sha256 =="
echo "RELEASE_AARCH64_BYTES" > "$tmp/rel.bin"
REG=$(curl $CURL_OPTS -s -H "$H" -X POST "$B/api/v1/apps/$APPID/releases/$RELID/artifacts" -F arch=aarch64 -F platform=android -F "hash=$(sha "$tmp/rel.bin")" -F "size=$(sz "$tmp/rel.bin")" -F filename=libapp.so -F can_sideload=false)
UP=$(echo "$REG" | sed -E 's#.*"url":"([^"]+)".*#\1#')
CODE=$(curl $CURL_OPTS -s -o /dev/null -w "%{http_code}" -H "$H" -X POST "$UP" -F "file=@$tmp/rel.bin")
[ "$CODE" = "204" ] && pass "release artifact verified (204)" || fail "upload got $CODE"

echo "== verification failure: bogus hash must fail the artifact (400) =="
echo "OTHER" > "$tmp/bad.bin"
BADUP=$(curl $CURL_OPTS -s -H "$H" -X POST "$B/api/v1/apps/$APPID/releases/$RELID/artifacts" -F arch=x86_64 -F platform=android -F "hash=deadbeef" -F "size=6" -F filename=libapp.so -F can_sideload=false | sed -E 's#.*"url":"([^"]+)".*#\1#')
CODE=$(curl $CURL_OPTS -s -o /dev/null -w "%{http_code}" -H "$H" -X POST "$BADUP" -F "file=@$tmp/bad.bin")
[ "$CODE" = "400" ] && pass "hash mismatch rejected (400)" || fail "expected 400, got $CODE"

echo "== finalize now succeeds =="
curl $CURL_OPTS -s -o /dev/null -w "  finalize -> %{http_code}\n" -H "$H" -X PATCH "$B/api/v1/apps/$APPID/releases/$RELID" -d '{"status":"active","platform":"android"}'

echo "== promote BEFORE patch ready must fail closed (409) =="
PATCHID=$(curl $CURL_OPTS -s -H "$H" -X POST "$B/api/v1/apps/$APPID/patches" -d "{\"release_id\":$RELID,\"metadata\":{}}" | sed -E 's/.*"id":([0-9]+).*/\1/')
CHID=$(curl $CURL_OPTS -s -H "$H" -X POST "$B/api/v1/apps/$APPID/channels" -d '{"channel":"stable"}' | sed -E 's/.*"id":([0-9]+).*/\1/')
CODE=$(curl $CURL_OPTS -s -o /dev/null -w "%{http_code}" -H "$H" -X POST "$B/api/v1/apps/$APPID/patches/promote" -d "{\"patch_id\":$PATCHID,\"channel_id\":$CHID}")
[ "$CODE" = "409" ] && pass "promote of non-ready patch rejected (409)" || fail "expected 409, got $CODE"

echo "== upload patch artifact (real hash) -> patch ready -> promote =="
printf 'PATCH_DIFF_BYTES' > "$tmp/patch.bin"
PUP=$(curl $CURL_OPTS -s -H "$H" -X POST "$B/api/v1/apps/$APPID/patches/$PATCHID/artifacts" -F arch=aarch64 -F platform=android -F "hash=$(sha "$tmp/patch.bin")" -F "size=$(sz "$tmp/patch.bin")" | sed -E 's#.*"url":"([^"]+)".*#\1#')
curl $CURL_OPTS -s -o /dev/null -H "$H" -X POST "$PUP" -F "file=@$tmp/patch.bin"
CODE=$(curl $CURL_OPTS -s -o /dev/null -w "%{http_code}" -H "$H" -X POST "$B/api/v1/apps/$APPID/patches/promote" -d "{\"patch_id\":$PATCHID,\"channel_id\":$CHID}")
[ "$CODE" = "204" ] && pass "promote of ready patch (204)" || fail "expected 204, got $CODE"

echo "== device check -> patch_available true =="
CHECK=$(curl $CURL_OPTS -s -X POST "$B/api/v1/patches/check" -d "{\"app_id\":\"$APPID\",\"release_version\":\"1.0.0+1\",\"platform\":\"android\",\"arch\":\"aarch64\",\"channel\":\"stable\"}")
echo "$CHECK" | grep -q '"patch_available":true' && pass "patch offered" || fail "patch not offered: $CHECK"
DL=$(echo "$CHECK" | sed -E 's#.*"download_url":"([^"]+)".*#\1#')

echo "== range download -> 206 + Content-Range =="
RH=$(curl $CURL_OPTS -s -D - -o /dev/null -H "Range: bytes=0-3" "$DL")
echo "$RH" | grep -qi "206" && echo "$RH" | grep -qi "content-range" && pass "range honored (206)" || fail "range not honored"

echo "== rollback (withdraw + revert) -> check false + rolled_back=[1] =="
curl $CURL_OPTS -s -o /dev/null -H "$H" -X POST "$B/admin/apps/$APPID/patches/$PATCHID/withdraw?channel=stable&rollback=true"
CHECK2=$(curl $CURL_OPTS -s -X POST "$B/api/v1/patches/check" -d "{\"app_id\":\"$APPID\",\"release_version\":\"1.0.0+1\",\"platform\":\"android\",\"arch\":\"aarch64\",\"channel\":\"stable\"}")
echo "$CHECK2" | grep -q '"patch_available":false' && echo "$CHECK2" | grep -q '"rolled_back_patch_numbers":\[1\]' && pass "rollback reflected ($CHECK2)" || fail "rollback wrong: $CHECK2"

rm -rf "$tmp"
echo "== smoke test OK =="
