#!/usr/bin/env bash
# cspell:words dwarfdump sbrbptch
#
# assert_installed_release.sh -- run this BEFORE interpreting any device result.
#
#   installed App LC_UUID  ==  the release the patch was built for
#
# A patch built for a release the device is not running produces
# "code patch: none" and looks exactly like an attach failure. That happened
# during rung B: a wait loop exited early on a benign `aot-tools.dill` warning,
# the previous release's IPA was staged and installed, and three launches were
# spent reading a delivery result as an ABI result.
#
# This is the cheapest discriminator available and it is now mandatory.
#
#   assert_installed_release.sh <path/to/Runner.app> <patch.log>
#   assert_installed_release.sh <path/to/Runner.app> --expect <buildId>
set -euo pipefail

APP=${1:?usage: assert_installed_release.sh <Runner.app> <patch.log|--expect ID>}
shift

if [[ "${1:-}" == "--expect" ]]; then
  WANT="${2:?--expect needs a build id}"
else
  LOG="${1:?need a patch log or --expect}"
  # The producer prints: "[route-b] packed N bytes for release <id> at <path>"
  WANT=$(sed -n 's/.*packed [0-9]* bytes for release \([0-9a-f]*\) .*/\1/p' \
    "$LOG" | tail -1)
  [[ -n "$WANT" ]] || {
    echo "ERROR: no 'packed ... for release <id>' line in $LOG" >&2
    exit 2
  }
fi

BIN="$APP/Frameworks/App.framework/App"
[[ -f "$BIN" ]] || { echo "ERROR: no App binary at $BIN" >&2; exit 2; }

GOT=$(dwarfdump --uuid "$BIN" \
  | sed -nE 's/^UUID: ([0-9A-Fa-f-]+).*/\1/p' | head -1 | tr -d '-' \
  | tr '[:upper:]' '[:lower:]')

echo "  installed App : $GOT"
echo "  patch built for: $WANT"
if [[ "$GOT" == "$WANT" ]]; then
  echo "  OK — the device will be running the release this patch targets"
  exit 0
fi
cat >&2 <<EOF

MISMATCH. The patch targets a release this .app is not.

Anything you observe on the device now is a DELIVERY result, not an attach or
ABI result: the updater will correctly refuse a patch built for another release,
and the app will show "code patch: none".

Stage the .ipa from the release the patch was built against and reinstall.
EOF
exit 1
