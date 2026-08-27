#!/usr/bin/env bash
# cspell:words xcarchive aab apksigner
#
# armb_measure.sh -- fetch a release artifact from the control plane and measure
# its platform-signing state.
#
# BEFORE and AFTER must be the SAME procedure, or a difference in how they were
# taken could masquerade as a difference in the artifact. So both phases call
# this, and the only thing that varies is the output label.
#
# The artifact always comes from the SERVER, never from a local build directory:
# the question is whether publishing a patch mutated what the control plane
# holds, and a local copy cannot answer that.
#
#   armb_measure.sh <ios|android> <arch> <label>
#
# Env: APP, REL, BASE, SHOREBIRD_TOKEN, OUT (defaults below).
set -uo pipefail

MODE=${1:?usage: armb_measure.sh <ios|android> <arch> <label>}
ARCH=${2:?usage: armb_measure.sh <ios|android> <arch> <label>}
LABEL=${3:?usage: armb_measure.sh <ios|android> <arch> <label>}
APP=${APP:?set APP}
REL=${REL:?set REL}
BASE=${BASE:-http://10.0.0.7:18080}
OUT=${OUT:-/tmp/armb}
: "${SHOREBIRD_TOKEN:?set SHOREBIRD_TOKEN}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

api() { curl -sS -H "Authorization: Bearer $SHOREBIRD_TOKEN" "$BASE$1"; }

RID=$(api "/api/v1/apps/$APP/releases" | REL="$REL" python3 -c '
import json,sys,os
d=json.load(sys.stdin)
rows=d if isinstance(d,list) else (d.get("releases") or [])
want=os.environ["REL"]
for r in rows:
    if r.get("version")==want: print(r["id"]); break
')
[ -n "$RID" ] || { echo "no release $REL on $APP" >&2; exit 1; }

URL=$(api "/api/v1/apps/$APP/releases/$RID/artifacts" | ARCH="$ARCH" python3 -c '
import json,sys,os
d=json.load(sys.stdin)
rows=d if isinstance(d,list) else (d.get("artifacts") or [])
want=os.environ["ARCH"]
for a in rows:
    if a.get("arch")==want:
        print(a.get("url") or a.get("download_url") or ""); break
')
[ -n "$URL" ] || { echo "no $ARCH artifact on release $RID" >&2; exit 1; }

D="$OUT/$LABEL"; rm -rf "$D"; mkdir -p "$D"
F="$D/artifact.bin"
curl -sSL -H "Authorization: Bearer $SHOREBIRD_TOKEN" "$URL" -o "$F"

# The DOWNLOADED BYTES are hashed first and separately. For iOS the signed
# object lives inside a zip, and zip containers can carry incidental metadata; so
# the report records both the container digest and the inner signed state, and
# the evidence is explicit about which is which.
echo "label: $LABEL"
echo "release_id: $RID"
echo "arch: $ARCH"
echo "container_sha256: $(shasum -a 256 "$F" | cut -d' ' -f1)"
echo "container_bytes: $(stat -f%z "$F")"

case "$MODE" in
ios)
  unzip -q -o "$F" -d "$D/x" 2>/dev/null || true
  APPDIR=$(find "$D/x" -maxdepth 6 -name '*.app' -type d | head -1)
  [ -n "$APPDIR" ] || { echo "no .app inside the fetched artifact" >&2; exit 1; }
  bash "$HERE/signing_state.sh" ios "$APPDIR"
  ;;
android)
  case "$ARCH" in
    aab) mv "$F" "$D/app.aab"; bash "$HERE/signing_state.sh" android "$D/app.aab" ;;
    apk) mv "$F" "$D/app.apk"; bash "$HERE/signing_state.sh" android "$D/app.apk" ;;
    *) echo "unexpected android arch $ARCH" >&2; exit 2 ;;
  esac
  ;;
*) echo "unknown mode $MODE" >&2; exit 2 ;;
esac
