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
# RUN IT BEFORE THE PATCH BUILD. `shorebird patch ios` re-archives, overwriting
# build/ios/archive/Runner.xcarchive with the PATCH build -- so afterwards this
# compares the patch's own App binary against the patch's target and reports a
# mismatch that means nothing. Capture the release's LC_UUID at install time and
# use --expect from then on.
#
# Related trap on this rig, now GUARDED but still worth knowing: `shorebird
# release ios` fails the IPA export ("No Accounts", "No profiles"), which used to
# leave the PREVIOUS release's .ipa sitting in build/ios/ipa/ looking current --
# and one release published with the wrong artifact that way. Since c57c6537 the
# release refuses an .ipa older than the .xcarchive its own invocation just
# produced, so the silent substitution is no longer possible. Install from the
# xcarchive regardless.
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

WHAT WILL ACTUALLY HAPPEN, because the obvious guess is wrong and it will cost
you a debugging session: the updater does NOT refuse this patch. A Route B
container is deliberately BASE-INDEPENDENT (0003-4b-lifecycle-delivery.patch,
"a base-independent artifact through the normal inflate"), so check_hash passes
on any device. The patch downloads, inflates, installs, is promoted, and reports
BOTH __patch_download__ and __patch_install__ to the control plane. Every
delivery signal you would look at says success.

The refusal happens later and in one place only: the native pre-main hook
compares the container's stamp to the App binary's LC_UUID and declines with
kWrongRelease. The app then shows "code patch: none" -- the same thing you would
see if delivery had failed, if the producer had emitted nothing, or if the
release had been built without --patchable_static_calls.

So "code patch: none" here means NOTHING about attach, binding or ABI. That is
the whole reason this pre-flight exists: the four causes are indistinguishable
after the fact, and three launches were spent learning it once already.

Stage the .ipa from the release the patch was built against and reinstall.
EOF
exit 1
