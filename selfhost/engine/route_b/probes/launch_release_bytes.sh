#!/usr/bin/env bash
# cspell:words ideviceinstaller idevicescreenshot otool noninteractive airgap
#
# launch_release_bytes.sh -- run a PRESERVED release's own bytes on the device,
# and read the beacon back.
#
# WHY THIS EXISTS. `shorebird patch ios` re-archives over `build/ios/archive`, and
# that archive is the PATCH BUILD: the replacement compiled straight into a fresh
# AOT binary. Launching it displays the patched value with the patch mechanism
# playing NO PART -- the strongest false positive this rig can produce
# (PARITY.md:1417, and `launch_fixture`'s own comment in airgap_acceptance.sh).
#
# The guard already existed in two places and was bypassed anyway, on 2026-08-13,
# by hand-rolling `ios-deploy --bundle <archive>/Runner.app` instead of going
# through `launch_fixture`. `assert_installed_release.sh` would have caught it, but
# it had been run BEFORE the patch build, when the archive was still the release.
# So the lesson is not "add a note" -- the note existed. It is: make the correct
# path the short one, and make identity a precondition of LAUNCHING rather than
# something checked at whatever moment the operator remembers.
#
# Identity comes from the .ipa, which the patch build leaves alone, and is compared
# against `selfhost/evidence/releases/<n>/LC_UUID` -- bytes preserved before any
# patch existed.
#
#   launch_release_bytes.sh <release-number> [--wait SECONDS] [--app-dir DIR]
#                                            [--container NAME] [--no-launch]
#                                            [--screenshot PATH]
#
# exit 0  launched, and a beacon was read (printed as the last line)
# exit 1  IDENTITY REFUSED -- the .ipa is not the preserved release
# exit 2  launched, but NO beacon arrived: see the Local Network note below
# exit 3  usage or environment
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../../../.." >/dev/null 2>&1 && pwd)"

REL=""
WAIT=45
APP_DIR="$REPO/selfhost/fixtures/airgap_app"
CONTAINER="${AIRGAP_CPS_CONTAINER:-cps-ios}"
LAUNCH=1
SHOT=

die() { echo "ERROR: $*" >&2; exit 3; }

while [ $# -gt 0 ]; do
  case "$1" in
    --wait)      WAIT="${2:?--wait needs seconds}"; shift 2 ;;
    --app-dir)   APP_DIR="${2:?--app-dir needs a path}"; shift 2 ;;
    --container) CONTAINER="${2:?--container needs a name}"; shift 2 ;;
    --no-launch) LAUNCH=0; shift ;;
    --screenshot) SHOT="${2:?--screenshot needs a path}"; shift 2 ;;
    -h|--help)   sed -n '1,32p' "$0"; exit 0 ;;
    -*)          die "unknown flag: $1" ;;
    *)           [ -z "$REL" ] || die "one release number only"; REL="$1"; shift ;;
  esac
done
[ -n "$REL" ] || die "usage: launch_release_bytes.sh <release-number> [--wait N]"

EVID="$REPO/selfhost/evidence/releases/$REL"
[ -d "$EVID" ] || die "no preserved evidence at $EVID"
[ -f "$EVID/LC_UUID" ] || die "no $EVID/LC_UUID -- run preserve_release_evidence.sh first"
WANT="$(tr -d '[:space:]' < "$EVID/LC_UUID")"
[ -n "$WANT" ] || die "$EVID/LC_UUID is empty"

command -v ios-deploy >/dev/null || die "ios-deploy not on PATH"
command -v otool >/dev/null || die "otool not on PATH"

uuid_of() { # <path-to-App-macho> -> lowercase hex uuid
  otool -l "$1" 2>/dev/null |
    awk '/LC_UUID/{f=1} f&&/uuid/{gsub(/-/,"",$2); print tolower($2); exit}'
}

IPA="$(ls -t "$APP_DIR/build/ios/ipa"/*.ipa 2>/dev/null | head -1)"
[ -n "$IPA" ] || die "no .ipa under $APP_DIR/build/ios/ipa"

STAGE="$APP_DIR/build/airgap-payload"
rm -rf "$STAGE"; mkdir -p "$STAGE"
unzip -qq "$IPA" -d "$STAGE" || die "could not unzip $IPA"
APP="$(find "$STAGE/Payload" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$APP" ] || die "no Payload/*.app inside $IPA"

GOT="$(uuid_of "$APP/Frameworks/App.framework/App")"
echo "release $REL"
echo "  ipa       : $IPA"
echo "  expected  : $WANT   (preserved before any patch build)"
echo "  ipa's App : ${GOT:-<unreadable>}"

# Attribution, printed whether or not it matters: after a patch build the archive
# holds DIFFERENT bytes, and naming both is what makes a later screenshot
# interpretable.
ARCH_APP="$(ls -td "$APP_DIR/build/ios/archive"/*.xcarchive 2>/dev/null | head -1)"
if [ -n "$ARCH_APP" ]; then
  A="$(uuid_of "$ARCH_APP/Products/Applications/Runner.app/Frameworks/App.framework/App")"
  echo "  archive   : ${A:-<unreadable>}"
  if [ -n "$A" ] && [ "$A" != "$WANT" ]; then
    echo "              ^ differs from the release: this archive is a PATCH BUILD."
    echo "                Never launch it. That is the rig's strongest false positive."
  fi
fi

if [ "$GOT" != "$WANT" ]; then
  echo
  echo "IDENTITY REFUSED: the .ipa is not release $REL's bytes."
  echo "A device result from it would describe a different build, and if the"
  echo "difference is a patch build it would show the patched value with the patch"
  echo "mechanism playing no part. Re-cut, or restore the release's .ipa."
  exit 1
fi
echo "  IDENTITY OK -- these are release $REL's own bytes"

[ "$LAUNCH" = 1 ] || exit 0

# NEVER `ios-deploy --uninstall_only` BETWEEN ARMS. Uninstalling resets iOS's
# Local Network consent for the bundle, and the fixture then blocks on
# "would like to find and connect to devices on your local network" before
# reaching any code: no `patches/check`, no patch download, no beacon. The
# failure is SILENT in every log this rig reads -- ios-deploy still reports
# `success` -- and it looks exactly like a dead gate. Measured 2026-08-13.
SINCE_MARK=$(date -u +%s)
LOG="$(mktemp)"
ios-deploy --noninteractive --bundle "$APP" > "$LOG" 2>&1 &
DEPLOY_PID=$!
echo "  launching (ios-deploy pid $DEPLOY_PID), waiting ${WAIT}s"
# `sleep` in the foreground on purpose: the process must outlive the wait, and
# backgrounding the wait instead is what truncated a run on 2026-08-13.
sleep "$WAIT"

# BEFORE the kill, or there is nothing on screen to photograph: killing
# ios-deploy terminates the app (evidence/README.md:63).
if [ -n "$SHOT" ]; then
  if idevicescreenshot "$SHOT" >/dev/null 2>&1; then
    echo "  screenshot: $SHOT"
  else
    echo "  (screenshot unavailable)"
  fi
fi

ELAPSED=$(( $(date -u +%s) - SINCE_MARK + 5 ))
BEACON="$(docker logs "$CONTAINER" --since "${ELAPSED}s" 2>&1 |
  grep -o '/selfhost-beacon/state?[^" ]*' | tail -1)"

kill "$DEPLOY_PID" 2>/dev/null
wait "$DEPLOY_PID" 2>/dev/null

if [ -z "$BEACON" ]; then
  echo
  echo "NO BEACON in the last ${ELAPSED}s from container '$CONTAINER'."
  echo "This is NOT a failed gate until you rule out, in this order:"
  echo "  1. Local Network consent. If the app was uninstalled or is newly"
  echo "     installed, iOS shows a modal BEFORE any code runs. Take a"
  echo "     screenshot (idevicescreenshot) and look. One tap on OK fixes it,"
  echo "     and the consent then persists until the next uninstall."
  echo "  2. Too short a wait. A fresh install costs ~20s before the first"
  echo "     frame; try --wait 60."
  echo "  3. The query string not being logged. Fixed 2026-08-13 in"
  echo "     code_push_server (loggedRequestPath); an old image logs the path"
  echo "     alone and the payload is invisible."
  echo "ios-deploy output: $LOG"
  exit 2
fi

echo
echo "$BEACON"
exit 0
