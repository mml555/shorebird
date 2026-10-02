#!/usr/bin/env bash
# cspell:words SBRBPTCH aarch64 jq
#
# publish_4b_patch.sh -- Route B 4b milestone 1, delivery half.
#
# Pushes the artifact built by build_4b_artifact.sh through the EXISTING control
# plane, by hand, using the same endpoints `shorebird patch` uses:
#
#   POST /patches                       create
#   POST /patches/{id}/artifacts        register  (arch, platform, hash, size)
#   POST /uploads/{token}               bytes
#   POST /patches/promote               make it live on a channel
#
# WHY BY HAND. `shorebird patch ios` cannot produce this: ios_patcher.dart gates
# non-assets-only patches on aot-tools.dill, Shorebird's AOT linker, which we
# cannot build. Milestone 1 deliberately keeps the producer out of the
# experiment so the thing under test is the RUNTIME half -- control plane ->
# updater -> lifecycle -> pre-main activation. Replacing that gate with a
# producer for exactly these bytes is the step after this one passes.
#
# HASH AND SIZE COME FROM DIFFERENT FILES, and that is not a mistake:
#
#   hash = sha256(CONTAINER)   -- check_hash() on device runs against the
#                                 INFLATED result, so the artifact's own digest
#                                 would install fine and then fail verification
#                                 with a message about release mismatches that
#                                 has nothing to do with the cause.
#   size = bytes(ARTIFACT)     -- the server verifies the number of bytes it
#                                 actually received.
#
# ios_patcher.dart does exactly this split (`hash` from patchBuildFile, `size`
# from patchFile). Getting it backwards costs a patch: the artifact fails
# verification, and the duplicate check means the same arch cannot be
# re-registered on that patch afterwards.
set -euo pipefail

APP=${APP:-/Users/mendell/shorebird/selfhost/fixtures/airgap_app}
OUTDIR=${OUTDIR:-$APP/build/route_b}
BASE=${SHOREBIRD_HOSTED_URL:-http://10.0.0.7:18080}
CHANNEL=${CHANNEL:-stable}
ROLLOUT=${ROLLOUT:-100}

die() { echo "ERROR: $*" >&2; exit 1; }

CONTAINER="$OUTDIR/patch.sbrbptch"
ARTIFACT="$OUTDIR/patch.artifact"
[ -f "$CONTAINER" ] || die "no container at $CONTAINER — run build_4b_artifact.sh"
[ -f "$ARTIFACT" ]  || die "no artifact at $ARTIFACT — run build_4b_artifact.sh"

# Self-hosted: the API key IS the credential. The stored credentials.json is an
# OAuth artifact whose refresh grant can and does expire; this cannot.
TOKEN=${SHOREBIRD_TOKEN:-$(docker inspect cps-ios \
  --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
  | sed -n 's/^API_KEY=//p')}
[ -n "$TOKEN" ] || die "no SHOREBIRD_TOKEN and could not read API_KEY from the cps-ios container"

APP_ID=$(sed -nE 's/^app_id:[[:space:]]*([^[:space:]#]+).*/\1/p' "$APP/shorebird.yaml" | head -1)
[ -n "$APP_ID" ] || die "no app_id in $APP/shorebird.yaml"
RELEASE_VERSION=${RELEASE_VERSION:-$(sed -nE 's/^version:[[:space:]]*([^[:space:]#]+).*/\1/p' "$APP/pubspec.yaml" | head -1)}

api() { # api <method> <path> [curl args...]
  local m=$1 p=$2; shift 2
  curl -sS -X "$m" "$BASE/api/v1$p" -H "Authorization: Bearer $TOKEN" "$@"
}

HASH=$(shasum -a 256 "$CONTAINER" | cut -d' ' -f1)
SIZE=$(wc -c < "$ARTIFACT" | tr -d ' ')

echo "app        : $APP_ID"
echo "release    : $RELEASE_VERSION"
echo "container  : $(wc -c < "$CONTAINER" | tr -d ' ') bytes, sha256 $HASH  (registered as hash)"
echo "artifact   : $SIZE bytes  (registered as size)"
echo

echo "== resolve release =="
RELEASE_ID=$(api GET "/apps/$APP_ID/releases" \
  | python3 -c "
import json,sys
want=sys.argv[1]
rs=json.load(sys.stdin)['releases']
m=[r for r in rs if r.get('version')==want]
if not m:
    sys.exit('no release %s (have: %s)' % (want, ', '.join(r.get('version','?') for r in rs)))
print(m[0]['id'])" "$RELEASE_VERSION")
echo "release id : $RELEASE_ID"

echo "== create patch =="
PATCH_JSON=$(api POST "/apps/$APP_ID/patches" -H 'Content-Type: application/json' \
  -d "{\"release_id\":$RELEASE_ID,\"notes\":\"Route B 4b milestone 1: SBRBPTCH through the real updater path\"}")
PATCH_ID=$(printf '%s' "$PATCH_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
PATCH_NUMBER=$(printf '%s' "$PATCH_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin).get('number','?'))")
echo "patch id   : $PATCH_ID (number $PATCH_NUMBER)"

echo "== register artifact =="
# aarch64/ios is what ios_patcher.dart registers, and what patches/check looks
# for. A Route B container is still "the code artifact for this arch" as far as
# the lifecycle is concerned -- only its CONTENT differs, which is the whole
# design: transport stays untouched.
REG=$(api POST "/apps/$APP_ID/patches/$PATCH_ID/artifacts" \
  -F "arch=aarch64" -F "platform=ios" -F "hash=$HASH" -F "size=$SIZE")
UPLOAD_URL=$(printf '%s' "$REG" | python3 -c "import json,sys;print(json.load(sys.stdin)['url'])")
echo "upload url : $UPLOAD_URL"

echo "== upload bytes =="
# MULTIPART, with a file part. The handler throws "Missing file part" on a raw
# body, and that 400 is silent about the cause unless you read the server.
UP=$(curl -sS -X POST "$UPLOAD_URL" -H "Authorization: Bearer $TOKEN" \
  -F "file=@$ARTIFACT" -w '\n  HTTP %{http_code}')
echo "$UP" | tail -2
echo "$UP" | grep -q 'HTTP 204' || die "upload did not return 204 — the patch will not reach ready"

echo "== resolve channel =="
CHANNEL_ID=$(api POST "/apps/$APP_ID/channels" -H 'Content-Type: application/json' \
  -d "{\"channel\":\"$CHANNEL\"}" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
echo "channel id : $CHANNEL_ID ($CHANNEL)"

echo "== promote =="
api POST "/apps/$APP_ID/patches/promote" -H 'Content-Type: application/json' \
  -d "{\"patch_id\":$PATCH_ID,\"channel_id\":$CHANNEL_ID,\"rollout\":$ROLLOUT}" \
  -o /dev/null -w '  HTTP %{http_code}\n'

echo
echo "published patch $PATCH_NUMBER for release $RELEASE_VERSION on $CHANNEL"
echo "device will fetch it from $BASE"
