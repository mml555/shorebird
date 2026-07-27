#!/usr/bin/env bash
#
# Generate a valid export-options-plist for `shorebird release ios
# --export-options-plist=<out>` (the manual / CI signing path — no Xcode UI).
#
# It pins the one Shorebird-specific rule the CLI enforces:
# `manageAppVersionAndBuildNumber = false`. If Xcode is allowed to rewrite the
# build number, the shipped version won't match what Shorebird recorded and
# patches silently fail to apply (see assertValidExportOptionsPlist).
#
# Values are derived from a provisioning profile when given, or passed
# explicitly. Prints the path it wrote.
#
# Usage:
#   tool/ios_export_options.sh --profile dev.mobileprovision \
#       [--method development] [--cert "Apple Development"] \
#       [--out export_options.plist] [--bundle-id id] [--team id]
#
#   method: development | ad-hoc | app-store-connect | enterprise
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/ios_signing.sh
. "$HERE/lib/ios_signing.sh"

PROFILE="" METHOD="development" CERT="Apple Development"
OUT="export_options.plist" BUNDLE="" TEAM="" PROFILE_NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --method) METHOD="$2"; shift 2 ;;
    --cert) CERT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --bundle-id) BUNDLE="$2"; shift 2 ;;
    --team) TEAM="$2"; shift 2 ;;
    --profile-name) PROFILE_NAME="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) ios::_err "unknown arg: $1"; exit 2 ;;
  esac
done

case "$METHOD" in
  development|ad-hoc|app-store-connect|enterprise) ;;
  *) ios::_err "invalid --method '$METHOD' (development|ad-hoc|app-store-connect|enterprise)"; exit 2 ;;
esac

if [ -n "$PROFILE" ]; then
  decoded="$(mktemp -t prof).plist"; trap 'rm -f "$decoded"' EXIT
  ios::decode "$PROFILE" "$decoded"
  ios::warn_if_expired "$decoded"
  [ -n "$TEAM" ] || TEAM="$(ios::team "$decoded")"
  [ -n "$BUNDLE" ] || BUNDLE="$(ios::bundle_id "$decoded")"
  PROFILE_NAME="$(ios::field "$decoded" Name)"
fi

[ -n "$TEAM" ] || { ios::_err "team id required (--team or --profile)"; exit 1; }
[ -n "$BUNDLE" ] || { ios::_err "bundle id required (--bundle-id or --profile)"; exit 1; }
if [ "$BUNDLE" = "*" ]; then
  ios::_err "profile is wildcard; pass a concrete --bundle-id"; exit 1
fi
[ -n "$PROFILE_NAME" ] || { ios::_err "provisioning profile name required (pass --profile)"; exit 1; }

cat >"$OUT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>${METHOD}</string>
  <key>teamID</key><string>${TEAM}</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>${CERT}</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>${BUNDLE}</key><string>${PROFILE_NAME}</string>
  </dict>
  <!-- Shorebird requires this false: Xcode must NOT rewrite the build number,
       or the shipped version won't match the recorded release and patches fail. -->
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>stripSwiftSymbols</key><true/>
</dict>
</plist>
PLIST

# Validate we produced a well-formed plist.
plutil -lint "$OUT" >/dev/null || { ios::_err "generated plist failed plutil -lint"; exit 1; }
echo "$OUT"
ios::_err "wrote export options: method=$METHOD team=$TEAM bundle=$BUNDLE profile=\"$PROFILE_NAME\""
