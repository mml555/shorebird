#!/usr/bin/env bash
#
# Re-sign an unsigned Shorebird iOS build (`shorebird release ios --no-codesign`)
# with an existing development cert + provisioning profile, WITHOUT needing an
# Apple ID signed into Xcode. This is the standard "resign" flow: embed the
# profile, sign the nested frameworks, then sign the app with dev entitlements.
#
# Why: automatic signing requires an Xcode account; manual signing in the Xcode
# project rejects Xcode-managed profiles. A direct `codesign` bypasses both and
# uses the dev cert + profile already in the keychain / on disk.
#
# Usage:
#   tool/ios_resign.sh <Runner.app> <identity-sha1> <profile.mobileprovision> <team-id> <bundle-id>
set -euo pipefail
APPB="${1:?path to Runner.app}"
IDENT="${2:?codesign identity sha1}"
PROFILE="${3:?path to .mobileprovision}"
TEAM="${4:?team id}"
BUNDLE="${5:?bundle id}"

ENT="$(mktemp -t ent).plist"
cat > "$ENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>application-identifier</key><string>${TEAM}.${BUNDLE}</string>
  <key>com.apple.developer.team-identifier</key><string>${TEAM}</string>
  <key>get-task-allow</key><true/>
  <key>keychain-access-groups</key><array><string>${TEAM}.${BUNDLE}</string></array>
</dict></plist>
EOF

cp "$PROFILE" "$APPB/embedded.mobileprovision"
# Sign nested frameworks/dylibs first (inside-out), then the app bundle.
if [ -d "$APPB/Frameworks" ]; then
  for f in "$APPB"/Frameworks/*; do
    codesign -f -s "$IDENT" --timestamp=none "$f" >/dev/null
  done
fi
codesign -f -s "$IDENT" --entitlements "$ENT" --timestamp=none "$APPB" >/dev/null
codesign --verify --deep --strict "$APPB" && echo "resigned OK: $(codesign -dv "$APPB" 2>&1 | grep -i TeamIdentifier)"
rm -f "$ENT"
