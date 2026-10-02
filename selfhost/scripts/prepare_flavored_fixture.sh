#!/usr/bin/env bash
# cspell:words pbxproj xcconfig xcconfigs xcshareddata xcschemes selfhost libexec
#
# prepare_flavored_fixture.sh — materialize selfhost/fixtures/flavored_app's
# generated iOS/Android trees and apply the committed flavor overlay.
#
# WHY THIS EXISTS. `flutter create` produces ONE scheme (`Runner`) and one
# `PRODUCT_BUNDLE_IDENTIFIER` for every configuration, so `--flavor foo` cannot
# build and there is nothing for a mismatch arm to mismatch against. The overlay
# under `ios_overlay/` adds the six flavored configurations, the `Foo`/`Bar`
# schemes and the two flavor xcconfigs. Applying it was a MANUAL step until this
# script existed, which is why `G4.2`'s arms stayed unconstructible.
#
# THE GENERATED TREES ARE DERIVED, NOT SOURCE. `ios/` and `android/` are
# gitignored. That is deliberate: they are a function of the pinned Flutter, and
# committing them would hide a generator change behind a diff nobody reads.
#
# ---------------------------------------------------------------------------
# THE SHA GATE, AND WHY IT HAS THREE OUTCOMES RATHER THAN TWO
#
# The overlay's `project.pbxproj` is not a patch — it is a WHOLE FILE derived
# from one specific generator's output (see `ios_overlay/derive_overlay.py`).
# Laying it over a tree produced by a DIFFERENT Flutter would silently discard
# whatever that generator changed, and the result would build. So the generated
# file is gated on `ios_overlay/BASELINE.project.pbxproj.sha256` before any copy.
#
# Two states are legitimate and a naive equal/not-equal gate confuses them:
#
#   current == BASELINE   a fresh `flutter create` from the pinned Flutter.
#                         Apply the overlay.
#   current == OVERLAY    already overlaid by a previous run. Do nothing to it;
#                         this script must be idempotent, and re-running it is
#                         the normal way to refresh the OTHER outputs.
#   anything else         REFUSE. Either the tree came from a different Flutter,
#                         or somebody hand-edited a derived file. Both are the
#                         same defect: the overlay's provenance no longer holds.
#
# The OVERLAY sha is computed at run time from the overlay file itself rather
# than recorded, so editing the overlay cannot leave a stale constant behind.
# ---------------------------------------------------------------------------
#
# Usage:
#   prepare_flavored_fixture.sh                      # materialize + overlay + verify
#   prepare_flavored_fixture.sh --app-id <id>        # also write .generated configs
#   prepare_flavored_fixture.sh --activate foo       # stamp the active shorebird.yaml
#   prepare_flavored_fixture.sh --recreate           # delete ios/ and regenerate first
#
# exit 0  the fixture is ready (or already was)
# exit 1  the sha gate refused, or verification failed
# exit 2  usage / environment
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
FIXTURE="${FIXTURE:-$HERE/../fixtures/flavored_app}"
OVERLAY="$FIXTURE/ios_overlay"
GEN_DIR="$FIXTURE/.generated"

APP_ID=""
ACTIVATE=""
BASE_URL="${BASE_URL:-http://localhost:18080}"
RECREATE=0

die()  { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-id)   APP_ID="${2:?--app-id needs a value}"; shift 2 ;;
    --activate) ACTIVATE="${2:?--activate needs a flavor}"; shift 2 ;;
    --base-url) BASE_URL="${2:?--base-url needs a value}"; shift 2 ;;
    --recreate) RECREATE=1; shift ;;
    -h|--help)  sed -n '2,50p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -d "$FIXTURE" ]]  || die "no fixture at $FIXTURE"
[[ -d "$OVERLAY" ]]  || die "no overlay at $OVERLAY"
command -v flutter >/dev/null || die "flutter is not on PATH"

PBX_REL="ios/Runner.xcodeproj/project.pbxproj"
BASELINE_FILE="$OVERLAY/BASELINE.project.pbxproj.sha256"
[[ -f "$BASELINE_FILE" ]] || die "no baseline at $BASELINE_FILE"
BASELINE_SHA="$(tr -d '[:space:]' < "$BASELINE_FILE")"
OVERLAY_SHA="$(shasum -a 256 "$OVERLAY/Runner.xcodeproj/project.pbxproj" | cut -d' ' -f1)"

# --- platform scaffolding -------------------------------------------------------
if [[ $RECREATE -eq 1 ]]; then
  note "--recreate: removing ios/ so the generator runs clean"
  rm -rf "$FIXTURE/ios"
fi

if [[ ! -d "$FIXTURE/ios" || ! -d "$FIXTURE/android" ]]; then
  note "materializing ios/ and android/ with flutter create ($(flutter --version 2>/dev/null | head -1))"
  ( cd "$FIXTURE" && flutter create --platforms=ios,android \
      --project-name flavored_probe --org dev.selfhost . >/dev/null )
else
  note "ios/ and android/ already present"
fi

[[ -f "$FIXTURE/$PBX_REL" ]] || die "no $PBX_REL after flutter create"

# --- THE SHA GATE ----------------------------------------------------------------
CURRENT_SHA="$(shasum -a 256 "$FIXTURE/$PBX_REL" | cut -d' ' -f1)"
APPLY_OVERLAY=1
if [[ "$CURRENT_SHA" == "$BASELINE_SHA" ]]; then
  note "sha gate: generated tree matches the recorded baseline — applying overlay"
elif [[ "$CURRENT_SHA" == "$OVERLAY_SHA" ]]; then
  note "sha gate: already overlaid (idempotent re-run) — leaving project.pbxproj alone"
  APPLY_OVERLAY=0
else
  echo >&2
  echo "REFUSING TO OVERLAY: $PBX_REL matches neither the baseline nor the overlay." >&2
  echo "  current : $CURRENT_SHA" >&2
  echo "  baseline: $BASELINE_SHA   (the pinned Flutter's generated output)" >&2
  echo "  overlay : $OVERLAY_SHA   (what a previous run would have left)" >&2
  echo >&2
  echo "The overlay is a WHOLE FILE derived from one generator's output, not a" >&2
  echo "patch. Laying it over a tree from a different Flutter would silently" >&2
  echo "discard that generator's changes and still build." >&2
  echo >&2
  echo "Either the Flutter pin moved — in which case re-derive the overlay with" >&2
  echo "  $OVERLAY/derive_overlay.py" >&2
  echo "and record a new BASELINE.project.pbxproj.sha256 — or a derived file was" >&2
  echo "hand-edited, in which case: prepare_flavored_fixture.sh --recreate" >&2
  exit 1
fi

# --- apply the overlay -----------------------------------------------------------
# Copied explicitly rather than with a bulk `cp -R` of the overlay directory:
# BASELINE.project.pbxproj.sha256 and derive_overlay.py are overlay TOOLING and
# must never land in the generated tree.
if [[ $APPLY_OVERLAY -eq 1 ]]; then
  note "applying the flavor overlay"
  mkdir -p "$FIXTURE/ios/Flutter" \
           "$FIXTURE/ios/Runner.xcodeproj/xcshareddata/xcschemes"
  cp "$OVERLAY/Flutter/Foo.xcconfig" "$FIXTURE/ios/Flutter/Foo.xcconfig"
  cp "$OVERLAY/Flutter/Bar.xcconfig" "$FIXTURE/ios/Flutter/Bar.xcconfig"
  cp "$OVERLAY/Runner.xcodeproj/project.pbxproj" "$FIXTURE/$PBX_REL"
  cp "$OVERLAY/Runner.xcodeproj/xcshareddata/xcschemes/Foo.xcscheme" \
     "$FIXTURE/ios/Runner.xcodeproj/xcshareddata/xcschemes/Foo.xcscheme"
  cp "$OVERLAY/Runner.xcodeproj/xcshareddata/xcschemes/Bar.xcscheme" \
     "$FIXTURE/ios/Runner.xcodeproj/xcshareddata/xcschemes/Bar.xcscheme"
fi

# --- iOS Info.plist: local network + cleartext -----------------------------------
# Re-injected on EVERY run, not only after a create: `ios/` is regenerated
# wholesale and these keys are not in the overlay's pbxproj. Without them the app
# blocks on a Local Network consent modal before any Dart code runs, and the
# failure looks like a control-plane outage rather than a missing plist key.
PLIST="$FIXTURE/ios/Runner/Info.plist"
if [[ -f "$PLIST" ]]; then
  /usr/libexec/PlistBuddy -c "Delete :NSLocalNetworkUsageDescription" "$PLIST" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :NSLocalNetworkUsageDescription string Reaches the self-hosted control plane on this Mac over the USB link." "$PLIST" >/dev/null
  /usr/libexec/PlistBuddy -c "Delete :NSAppTransportSecurity" "$PLIST" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$PLIST" >/dev/null
  /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$PLIST" >/dev/null
  note "Info.plist: local-network usage + NSAllowsLocalNetworking injected"
fi

# --- shorebird.yaml, per flavor --------------------------------------------------
# foo and bar share ONE app_id on purpose — see shorebird.yaml.template. Distinct
# ids would make `patch --flavor bar` query a different app and fail
# "release not found" BEFORE the fingerprint is compared, which is a refusal for
# the wrong reason, and a wrong-reason refusal in the mismatch arm reads exactly
# like the right one.
mkdir -p "$GEN_DIR"
if [[ -n "$APP_ID" ]]; then
  cat > "$GEN_DIR/shorebird.flavored.yaml" <<EOF
# GENERATED by selfhost/scripts/prepare_flavored_fixture.sh — do not hand-edit.
# app_id is server-generated and instance-specific, which is exactly why it is
# not a committed constant. foo and bar map to the SAME app_id deliberately.
app_id: $APP_ID
flavors:
  foo: $APP_ID
  bar: $APP_ID
base_url: $BASE_URL
EOF
  note "wrote .generated/shorebird.flavored.yaml (app_id $APP_ID, base_url $BASE_URL)"
fi

# A shorebird.yaml MUST EXIST for `flutter build` to succeed at all — pubspec.yaml
# declares it as an asset (the CLI refuses to build without that declaration,
# because the updater reads app_id and base_url out of the bundled copy at
# runtime). So a missing one fails as `Failed to bundle asset files`, which names
# neither shorebird.yaml nor the real cause.
#
# H2 step 7's arms are explicitly "no control plane, no device", so they must run
# before any app is registered. Write a HOST-ONLY placeholder in that case, marked
# loudly enough that it cannot be mistaken for a registration: a control-plane
# command against it fails "app not found", which is the loud direction.
if [[ ! -f "$FIXTURE/shorebird.yaml" && -z "$APP_ID" ]]; then
  cat > "$FIXTURE/shorebird.yaml" <<EOF
# GENERATED by selfhost/scripts/prepare_flavored_fixture.sh — HOST BUILDS ONLY.
#
# This app_id is NOT REGISTERED anywhere. It exists so that \`flutter build ios
# --flavor …\` can run with no control plane, which is what H2 step 7's arms need.
# Any \`shorebird\` command against it will fail "app not found" — loudly, which is
# the correct direction. For a real release:
#   prepare_flavored_fixture.sh --app-id <server-generated id> --activate foo
app_id: HOST-ONLY-NOT-REGISTERED
flavors:
  foo: HOST-ONLY-NOT-REGISTERED
  bar: HOST-ONLY-NOT-REGISTERED
base_url: $BASE_URL
EOF
  note "wrote a HOST-ONLY shorebird.yaml (unregistered app_id) so flutter build can run"
fi

if [[ -n "$ACTIVATE" ]]; then
  case "$ACTIVATE" in
    foo|bar) ;;
    *) die "--activate takes 'foo' or 'bar', not '$ACTIVATE'" ;;
  esac
  src="$GEN_DIR/shorebird.flavored.yaml"
  [[ -f "$src" ]] || die "no generated config yet. Run with --app-id <id> first."
  cp -f "$src" "$FIXTURE/shorebird.yaml"
  note "ACTIVE flavor: $ACTIVATE -> app_id $(awk '/^app_id:/{print $2}' "$FIXTURE/shorebird.yaml")"
fi

# --- verify ----------------------------------------------------------------------
# The check is on the PROJECT, not on a file listing: a copied xcconfig proves
# nothing if the pbxproj does not reference it.
note "verifying with xcodebuild -list"
LIST="$(cd "$FIXTURE/ios" && xcodebuild -list -project Runner.xcodeproj 2>/dev/null)" \
  || die "xcodebuild -list failed — the project is not loadable"

missing=0
for want in Debug-Foo Release-Foo Profile-Foo Debug-Bar Release-Bar Profile-Bar; do
  printf '%s' "$LIST" | grep -q "[[:space:]]$want$" || { echo "  MISSING configuration: $want" >&2; missing=1; }
done
for want in Foo Bar Runner; do
  printf '%s' "$LIST" | grep -q "[[:space:]]$want$" || { echo "  MISSING scheme: $want" >&2; missing=1; }
done
[[ $missing -eq 0 ]] || die "the overlay did not take — see the missing entries above"

echo
echo "flavored fixture ready:"
echo "  configurations : Debug/Release/Profile x {plain, -Foo, -Bar}"
echo "  schemes        : Runner, Foo, Bar"
echo "  bundle ids     : dev.selfhost.flavoredProbe{,.foo,.bar}"
echo
echo "NEXT: this only proves the PROJECT resolves flavors. That --flavor reaches"
echo "the COMPILER is H2 step 7's arms, and a device arm needs a release."
