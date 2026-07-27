#!/usr/bin/env bash
#
# Re-sign an unsigned Shorebird iOS build (`shorebird release ios --no-codesign`)
# with an existing cert + provisioning profile, WITHOUT needing an Apple ID
# signed into Xcode. Standard inside-out resign: embed the profile, extract its
# REAL entitlements, sign nested frameworks/plugins, then sign the app.
#
# Why: automatic signing requires an Xcode account; manual signing in the Xcode
# project rejects Xcode-managed profiles. A direct `codesign` bypasses both.
#
# What's different from a naive resign: the entitlements come from the profile
# (so push / app-groups / associated-domains / keychain-groups survive), nested
# code is signed inside-out, and the target device is validated against the
# profile. Team and bundle id are derived from the profile when omitted.
#
# Usage:
#   tool/ios_resign.sh <Runner.app> [identity-sha1] <profile.mobileprovision> \
#                      [team-id] [bundle-id]
#
#   # minimal — identity auto-selected, team+bundle read from the profile:
#   tool/ios_resign.sh build/.../Runner.app "" dev.mobileprovision
#
# Env:
#   IOS_DEVICE_UDID   if set, assert the profile provisions this device (else warn)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/ios_signing.sh
. "$HERE/lib/ios_signing.sh"

APPB="${1:?path to Runner.app}"
IDENT_IN="${2:-}"
PROFILE="${3:?path to .mobileprovision}"
TEAM_IN="${4:-}"
BUNDLE_IN="${5:-}"

[ -d "$APPB" ] || { ios::_err "app bundle not found: $APPB"; exit 1; }

decoded="$(mktemp -t prof).plist"
ent="$(mktemp -t ent).plist"
trap 'rm -f "$decoded" "$ent"' EXIT

ios::decode "$PROFILE" "$decoded"
ios::warn_if_expired "$decoded"

# Resolve signing inputs, preferring explicit args, then the profile.
IDENT="$(ios::resolve_identity "$IDENT_IN")"
TEAM="${TEAM_IN:-$(ios::team "$decoded")}"
[ -n "$TEAM" ] || { ios::_err "could not determine team id; pass it as arg 4"; exit 1; }

BUNDLE="$BUNDLE_IN"
if [ -z "$BUNDLE" ]; then
  BUNDLE="$(ios::bundle_id "$decoded")"
  if [ "$BUNDLE" = "*" ]; then
    ios::_err "profile is wildcard (TEAM.*); pass the concrete bundle id as arg 5"
    exit 1
  fi
fi

# Real entitlements from the profile, with application-identifier /
# team-identifier / keychain-access-groups pinned to the resolved bundle so a
# wildcard-or-mismatched profile still yields a coherent, signable set.
if ! ios::entitlements "$decoded" "$ent"; then
  ios::_err "no entitlements in profile — cannot resign safely"; exit 1
fi
GTA="$(ios::get_task_allow "$decoded")"
/usr/libexec/PlistBuddy \
  -c "Set :application-identifier ${TEAM}.${BUNDLE}" \
  -c "Set :com.apple.developer.team-identifier ${TEAM}" \
  -c "Delete :get-task-allow" -c "Add :get-task-allow bool ${GTA}" \
  "$ent" >/dev/null 2>&1 || true

# Device check (dev profiles list ProvisionedDevices; distribution ones don't).
if [ -n "${IOS_DEVICE_UDID:-}" ]; then
  set +e
  ios::provisions_device "$decoded" "$IOS_DEVICE_UDID"; rc=$?
  set -e
  case "$rc" in
    0) ;;                                        # device is in the profile
    2) ios::_err "NOTE: distribution profile (no device list) — install won't work on a specific device via this profile" ;;
    *) ios::_err "ERROR: device $IOS_DEVICE_UDID is NOT in the provisioning profile"; exit 1 ;;
  esac
fi

echo "resigning $APPB"
echo "  identity : $IDENT"
echo "  team     : $TEAM"
echo "  bundle   : $BUNDLE"
echo "  profile  : $(ios::field "$decoded" Name) ($(ios::field "$decoded" UUID))"
echo "  dev/get-task-allow: $GTA"

cp "$PROFILE" "$APPB/embedded.mobileprovision"

# Sign inside-out: nested frameworks/dylibs first (no entitlements — frameworks
# don't carry app entitlements), then any app extensions best-effort, then the
# app bundle with the profile's entitlements.
if [ -d "$APPB/Frameworks" ]; then
  find "$APPB/Frameworks" -type d -name "*.framework" -print0 2>/dev/null |
    while IFS= read -r -d '' fw; do codesign -f -s "$IDENT" --timestamp=none "$fw" >/dev/null; done
  find "$APPB/Frameworks" -maxdepth 1 -type f \( -name "*.dylib" -o -perm -u+x \) -print0 2>/dev/null |
    while IFS= read -r -d '' dy; do codesign -f -s "$IDENT" --timestamp=none "$dy" >/dev/null; done
fi
if [ -d "$APPB/PlugIns" ]; then
  find "$APPB/PlugIns" -maxdepth 1 -type d -name "*.appex" -print0 2>/dev/null |
    while IFS= read -r -d '' ax; do
      ios::_err "NOTE: signing app extension $(basename "$ax") with identity only — extensions with their own bundle id may need their own profile"
      codesign -f -s "$IDENT" --timestamp=none "$ax" >/dev/null
    done
fi

codesign -f -s "$IDENT" --entitlements "$ent" --timestamp=none "$APPB" >/dev/null
codesign --verify --deep --strict "$APPB"
echo "resigned OK: $(codesign -dv "$APPB" 2>&1 | grep -i TeamIdentifier || true)"
