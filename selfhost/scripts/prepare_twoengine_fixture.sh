#!/usr/bin/env bash
# cspell:words PlistBuddy plutil twoengine libexec udid
#
# prepare_twoengine_fixture.sh -- materialize selfhost/fixtures/twoengine_app.
#
# WHY A SEPARATE SCRIPT. `prepare_airgap_fixture.sh:32` hardcodes
# FIXTURE=.../airgap_app and its arg parser dies on an unknown flag, so it cannot
# be pointed at a clone. Adding `--fixture` there would edit a script that a
# device gate uses while device gates are running; a second script contends with
# nothing.
#
# WHAT IT REBUILDS, AND WHY EACH STEP EXISTS
#
#   1. `flutter create` the ios/ tree if absent. Generated and gitignored, so it
#      must be reproducible rather than reviewed.
#   2. Copy ios_overlay/AppDelegate.swift over ios/Runner/AppDelegate.swift. An
#      in-place edit is deleted by the next materialize; re-injection is the
#      pattern airgap's script already uses for its two Info.plist keys.
#   3. DELETE UIMainStoryboardFile. This is the harness's correctness condition,
#      not tidiness: the key makes the Runner boot an IMPLICIT engine, so two
#      constructed engines become THREE and every per-engine reading is
#      unattributable. The host refuses to interpret such a run; this is what
#      prevents it arising.
#   4. Re-inject the two local-network Info.plist keys, matching
#      prepare_airgap_fixture.sh:96-110, so a later device/control-plane arm can
#      reach a LAN control plane without a second round of debugging.
#   5. Write shorebird.yaml from the template, because pubspec declares it as an
#      asset and `flutter run` fails without it.
#
# It is IDEMPOTENT: run it twice and the second run reports the platform dir
# already present and rewrites only the overlay and config.
#
#   prepare_twoengine_fixture.sh [--app-id ID] [--base-url URL] [--flutter PATH]
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/.." >/dev/null 2>&1 && pwd)"
FIXTURE="$REPO/fixtures/twoengine_app"

APP_ID="${TWOENGINE_APP_ID:-REPLACE-ME}"
BASE_URL="${TWOENGINE_BASE_URL:-http://localhost:18080}"
# STOCK Flutter by default, and that default is load-bearing for experiment B:
# the structural claim must not be made against a Route B experimental engine, or
# a green boot could be misread as saying something about arming.
FLUTTER="${TWOENGINE_FLUTTER:-/opt/homebrew/bin/flutter}"

die() { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --app-id)   APP_ID="${2:?--app-id needs a value}"; shift 2 ;;
    --base-url) BASE_URL="${2:?--base-url needs a value}"; shift 2 ;;
    --flutter)  FLUTTER="${2:?--flutter needs a path}"; shift 2 ;;
    -h|--help)  sed -n '1,32p' "$0"; exit 0 ;;
    *)          die "unknown flag: $1" ;;
  esac
done

[ -d "$FIXTURE" ] || die "no fixture at $FIXTURE"
[ -x "$FLUTTER" ] || die "no flutter at $FLUTTER"
OVERLAY="$FIXTURE/ios_overlay/AppDelegate.swift"
[ -f "$OVERLAY" ] || die "no committed overlay at $OVERLAY"

cd "$FIXTURE"

# 1. the generated tree
if [ -d ios ]; then
  echo "==> ios/ already present (generated); leaving the tree in place"
else
  echo "==> flutter create (ios only)"
  "$FLUTTER" create --platforms=ios --project-name twoengine_probe \
    --org dev.selfhost . >/dev/null
fi
PLIST=ios/Runner/Info.plist
[ -f "$PLIST" ] || die "no $PLIST after create"

# 2. the host
cp "$OVERLAY" ios/Runner/AppDelegate.swift
echo "==> overlay copied: ios/Runner/AppDelegate.swift"

# 3. the implicit engine's source, removed
if /usr/libexec/PlistBuddy -c "Print :UIMainStoryboardFile" "$PLIST" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Delete :UIMainStoryboardFile" "$PLIST"
  echo "==> UIMainStoryboardFile DELETED (no implicit engine)"
else
  echo "==> UIMainStoryboardFile already absent"
fi

# 4. local-network keys, same as the airgap fixture's script
if ! /usr/libexec/PlistBuddy -c "Print :NSLocalNetworkUsageDescription" "$PLIST" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Add :NSLocalNetworkUsageDescription string Reaches the self-hosted control plane on this Mac over the USB link." "$PLIST"
fi
if ! /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity" "$PLIST" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$PLIST"
  /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$PLIST"
fi
echo "==> local-network keys present"

# 5. the config the asset declaration requires
sed -e "s|^app_id: .*|app_id: $APP_ID|" \
    -e "s|^base_url: .*|base_url: $BASE_URL|" \
    shorebird.yaml.template > shorebird.yaml
echo "==> shorebird.yaml written (app_id=$APP_ID base_url=$BASE_URL)"

echo
echo "VERIFY THE SHAPE (these are the harness's correctness conditions):"
echo "  grep -c FlutterDartProject ios/Runner/AppDelegate.swift        # expect 3"
echo "  grep -c 'FlutterEngineGroup\\|spawnWithEntrypoint' ios/Runner/AppDelegate.swift  # expect 0"
echo "  /usr/libexec/PlistBuddy -c 'Print :UIMainStoryboardFile' $PLIST  # expect: does not exist"
echo
echo "THEN, simulator only (never a wirelessly paired device):"
echo "  $FLUTTER run -d <simulator-udid>"
echo "Expect two G15-ENGINE lines with DIFFERENT engine= and isolate= values, two"
echo "G15-MARKER lines, and G15-HOST engines_constructed=2 with both run flags 1."
