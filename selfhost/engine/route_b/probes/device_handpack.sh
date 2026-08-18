#!/usr/bin/env bash
# cspell:words dartaotruntime SBRBPTCH sbrbptch
#
# device_handpack.sh -- publish a HAND-WRITTEN replacement body as a real patch.
#
# For probes whose replacement cannot be expressed in ordinary app source, and
# therefore cannot come from the automatic producer. Rung C is the case: the
# payload is
#
#     String value(RouteBThing self) => self.label;
#
# while the app source declares an instance method with no parameters. Turning
# one into the other is a kernel-lowering problem with its own design, and
# mixing it into the ABI experiment would add a second variable to the only
# question being asked.
#
# Everything downstream of the replacement source is the PRODUCT path: the same
# cell, the same container writer, the same one-byte-synthetic-base artifact,
# the same registration and promotion. Only the source is hand-written.
#
#   device_handpack.sh <replacement.dart> <library#selector> [notes]
set -euo pipefail

APP=${APP:-/Users/mendell/shorebird/selfhost/fixtures/airgap_app}
BASE=${SHOREBIRD_HOSTED_URL:-http://10.0.0.7:18080}
CHANNEL=${CHANNEL:-stable}
ROLLOUT=${ROLLOUT:-100}
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
RB="$(cd "$HERE/.." >/dev/null 2>&1 && pwd)"

REPL=${1:?usage: device_handpack.sh <replacement.dart> <library#selector> [notes]}
TARGET=${2:?need a library#selector}
NOTES=${3:-Route B probe: hand-packed replacement}

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }

TOKEN=${SHOREBIRD_TOKEN:-$(docker inspect cps-ios \
  --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
  | sed -n 's/^API_KEY=//p')}
[ -n "$TOKEN" ] || die "no SHOREBIRD_TOKEN and could not read API_KEY from cps-ios"

APP_ID=$(sed -nE 's/^app_id:[[:space:]]*([^[:space:]#]+).*/\1/p' "$APP/shorebird.yaml" | head -1)
RELEASE_VERSION=${RELEASE_VERSION:-$(sed -nE 's/^version:[[:space:]]*([^[:space:]#]+).*/\1/p' "$APP/pubspec.yaml" | head -1)}
SUP="$APP/build/ios/shorebird"
APPBIN="$APP/build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app/Frameworks/App.framework/App"
[ -f "$SUP/release_import.dill" ] || die "no release_import.dill — build the release first"
[ -f "$APPBIN" ] || die "no shipped App binary at $APPBIN"

# The cell for the engine THIS RELEASE recorded, never an ambient one.
ENGINE=$(python3 -c "
import json;print(json.load(open('$SUP/route_b.json'))['engineRevision'])")
CELL=${CELL:-$HOME/.shorebird/bin/cache/artifacts/route-b-compiler/$ENGINE}
[ -d "$CELL" ] || die "no resolved cell at $CELL (run a patch once so the CLI fetches it)"

BUILD_ID=$(dwarfdump --uuid "$APPBIN" \
  | sed -nE 's/^UUID: ([0-9A-Fa-f-]+).*/\1/p' | head -1 | tr -d '-' \
  | tr '[:upper:]' '[:lower:]')

W=$(mktemp -d)
echo "app        : $APP_ID"
echo "release    : $RELEASE_VERSION"
echo "engine     : $ENGINE"
echo "build id   : $BUILD_ID"
echo "target     : $TARGET"

note "compile the replacement with the RELEASE's cell"
"$CELL/dartaotruntime" "$CELL/dart2bytecode.aot" \
  --platform "$CELL/flutter_platform_strong.dill" --target flutter \
  --import-dill "$SUP/release_import.dill" \
  --packages "$APP/.dart_tool/package_config.json" \
  -o "$W/repl.bytecode" "$REPL" || die "dart2bytecode refused the replacement"
echo "  bytecode : $(wc -c < "$W/repl.bytecode" | tr -d ' ') bytes"

note "pack + artifact (the product's own writer and differ)"
"$CELL/../../../../bin/cache/flutter" >/dev/null 2>&1 || true
DART_TREE=${DART_TREE:-/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart}
HOSTDART=${HOSTDART:-/Volumes/build/route-b/flutter/engine/src/out/host_release_arm64/dart-sdk/bin/dart}
"$HOSTDART" --packages="$DART_TREE/.dart_tool/package_config.json" \
  "$RB/packaging/pack_patch.dart" --release-build-id "$BUILD_ID" \
  --out "$W/patch.sbrbptch" --target "$TARGET=$W/repl.bytecode" >/dev/null
printf '\0' > "$W/base"
PATCH_BIN=${PATCH_BIN:-$HOME/.shorebird/bin/cache/artifacts/patch/patch}
"$PATCH_BIN" "$W/base" "$W/patch.sbrbptch" "$W/patch.artifact" >/dev/null 2>&1

HASH=$(shasum -a 256 "$W/patch.sbrbptch" | cut -d' ' -f1)
SIZE=$(wc -c < "$W/patch.artifact" | tr -d ' ')
echo "  container: $(wc -c < "$W/patch.sbrbptch" | tr -d ' ') bytes, sha256 $HASH  (registered as HASH)"
echo "  artifact : $SIZE bytes  (registered as SIZE)"

api() { local m=$1 p=$2; shift 2; curl -sS -X "$m" "$BASE/api/v1$p" -H "Authorization: Bearer $TOKEN" "$@"; }

note "publish"
RELEASE_ID=$(api GET "/apps/$APP_ID/releases" | python3 -c "
import json,sys
want=sys.argv[1]; rs=json.load(sys.stdin)['releases']
m=[r for r in rs if r.get('version')==want]
if not m: sys.exit('no release %s' % want)
print(m[0]['id'])" "$RELEASE_VERSION")
PATCH_JSON=$(api POST "/apps/$APP_ID/patches" -H 'Content-Type: application/json' \
  -d "{\"release_id\":$RELEASE_ID,\"notes\":\"$NOTES\"}")
PATCH_ID=$(printf '%s' "$PATCH_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
PATCH_NUMBER=$(printf '%s' "$PATCH_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin).get('number','?'))")
UPLOAD_URL=$(api POST "/apps/$APP_ID/patches/$PATCH_ID/artifacts" \
  -F "arch=aarch64" -F "platform=ios" -F "hash=$HASH" -F "size=$SIZE" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['url'])")
curl -sS -X POST "$UPLOAD_URL" -H "Authorization: Bearer $TOKEN" \
  -F "file=@$W/patch.artifact" -w '%{http_code}' -o /dev/null | grep -q 204 \
  || die "upload did not return 204"
CHANNEL_ID=$(api POST "/apps/$APP_ID/channels" -H 'Content-Type: application/json' \
  -d "{\"channel\":\"$CHANNEL\"}" | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
api POST "/apps/$APP_ID/patches/promote" -H 'Content-Type: application/json' \
  -d "{\"patch_id\":$PATCH_ID,\"channel_id\":$CHANNEL_ID,\"rollout\":$ROLLOUT}" >/dev/null

echo "  published patch $PATCH_NUMBER (id $PATCH_ID) on $CHANNEL"
echo "PATCH_ID=$PATCH_ID"
echo "BUILD_ID=$BUILD_ID"
echo "WORK=$W"
