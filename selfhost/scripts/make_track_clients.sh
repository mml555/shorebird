#!/usr/bin/env bash
# cspell:words mobileprovision plutil codesign entitlements xcarchive
#
# make_track_clients.sh -- build two independent updater clients from ONE release.
#
# WHY THIS EXISTS. The tracks arm needs two clients that differ in the channel
# they request and in nothing else that matters. It cannot use two builds: a
# Route B patch is bound to one release artifact, so a second build would need
# its own patch and the comparison would be between two patches rather than two
# tracks. And iOS will not install one bundle id twice.
#
# So both clients are cut from one build. The ONLY edits are:
#   * `channel:` appended to the bundled shorebird.yaml -- the file the native
#     updater actually reads (vendor/updater/library/src/yaml.rs:60);
#   * CFBundleIdentifier, so iOS treats them as two apps;
#   * CFBundleDisplayName, so a human can tell which icon to tap.
#
# `App.framework/App` -- the Dart AOT, and the thing a patch is bound to -- must
# carry the same PAYLOAD in both clients, and this script ASSERTS that rather
# than trusting it. If it ever differs, the arm is invalid and the script
# refuses.
#
# WHY THE PAYLOAD AND NOT THE FILE. The first version compared the whole file
# and refused -- correctly on its own terms: re-signing App.framework rewrites
# the code-signature blob inside the Mach-O, so the file hash changes even
# though not one byte of AOT changed. Comparing the file would have made a valid
# arm impossible; quietly dropping the check would have removed the only thing
# standing between 'two clients, one release' and a rebuilt snapshot. So the
# comparison strips the signature first.
#
# That a re-signature is harmless is measured, not assumed: nothing on the
# device verifies the base binary. The updater's `check_hash`
# (vendor/updater/library/src/updater.rs:327) hashes the DOWNLOADED PATCH
# against the server's hash, and the comment at :334 about hashing `libapp.so`
# names a design that was never implemented. Route B's release-artifact binding
# is checked by the PRODUCER at publish time, not on device.
#
# The check request carries no bundle id and no base-app hash
# (vendor/updater/library/src/network.rs:250-300), so to the server these two
# differ only in `client_id` (a per-install random UUID) and `channel`.
set -euo pipefail

SRC=${1:?usage: make_track_clients.sh <Runner.app> <outdir>}
OUT=${2:?usage: make_track_clients.sh <Runner.app> <outdir>}
TEAM=${TEAM:-SK85S6YZP9}
IDENTITY=${IDENTITY:-EE8685A45DE3BE56F754883C4BF6C94A92EDE6FE}
BASE_ID=${BASE_ID:-dev.selfhost.flavoredProbe.foo}
PROFILE=${PROFILE:-}

die() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$SRC" ] || die "no app bundle at $SRC"
# Hash of the AOT with any code signature removed -- the header explains why the
# raw file hash is the wrong invariant.
payload_hash() {
  local tmp; tmp=$(mktemp -d)
  cp "$1" "$tmp/App"
  codesign --remove-signature "$tmp/App" >/dev/null 2>&1 || true
  shasum -a 256 "$tmp/App" | cut -d' ' -f1
  rm -rf "$tmp"
}
REF_AOT=$(payload_hash "$SRC/Frameworks/App.framework/App")

# The wildcard profile is what lets a NEW bundle id be signed without minting
# anything. Located by entitlement, not by filename, because filenames are UUIDs.
if [ -z "$PROFILE" ]; then
  for p in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.mobileprovision; do
    a=$(security cms -D -i "$p" 2>/dev/null | plutil -extract Entitlements.application-identifier raw - 2>/dev/null || true)
    [ "$a" = "$TEAM.*" ] && { PROFILE=$p; break; }
  done
fi
[ -n "$PROFILE" ] || die "no wildcard $TEAM.* provisioning profile found"
echo "profile : $(basename "$PROFILE")"

rm -rf "$OUT"; mkdir -p "$OUT"

make_client() { # <suffix> <channel> <display name>
  local suffix=$1 channel=$2 name=$3
  local app="$OUT/$suffix.app" id="$BASE_ID.$suffix"
  cp -R "$SRC" "$app"
  rm -rf "$app/_CodeSignature" "$app/Frameworks/App.framework/_CodeSignature"

  # 0. A DISTINCT executable UUID. Copies of one build share LC_UUID, and iOS
  # attributes local-network permission by executable UUID: with several
  # installed apps sharing one it logged `bundle_id: (null)` and every app in the
  # colliding set -- including the untouched base app that had worked minutes
  # earlier -- had its local-network connection refused instantly (~0.2ms, no
  # round trip). Deterministic per bundle id so a rebuild is reproducible.
  local uuid
  uuid=$(printf '%s' "$id" | shasum -a 256 | cut -c1-32)
  python3 "$(dirname "${BASH_SOURCE[0]}")/set_macho_uuid.py" "$app/Runner" "$uuid" >/dev/null \
    || die "$suffix: failed to set LC_UUID"

  # 1. the channel, into the file the updater reads
  local yaml="$app/Frameworks/App.framework/flutter_assets/shorebird.yaml"
  [ -f "$yaml" ] || die "$suffix: no bundled shorebird.yaml"
  printf '\nchannel: %s\n' "$channel" >> "$yaml"
  grep -q "^channel: $channel\$" "$yaml" || die "$suffix: channel not written"

  # 2. identity
  plutil -replace CFBundleIdentifier -string "$id" "$app/Info.plist"
  plutil -replace CFBundleDisplayName -string "$name" "$app/Info.plist"
  cp "$PROFILE" "$app/embedded.mobileprovision"

  # 3. entitlements from the profile, with the app id substituted. Taking them
  # from the profile rather than hand-writing them keeps this working if the
  # team's profile gains capabilities.
  local ent="$OUT/$suffix.entitlements.plist"
  security cms -D -i "$PROFILE" | plutil -extract Entitlements xml1 -o "$ent" -
  plutil -replace application-identifier -string "$TEAM.$id" "$ent"

  # 4. sign inside-out. App.framework changed (its assets did), so it must be
  # re-signed; Flutter.framework did not and keeps its original signature.
  codesign -f -s "$IDENTITY" --timestamp=none \
    "$app/Frameworks/App.framework" >/dev/null 2>&1 \
    || die "$suffix: failed to sign App.framework"
  codesign -f -s "$IDENTITY" --timestamp=none --entitlements "$ent" \
    "$app" >/dev/null 2>&1 || die "$suffix: failed to sign the app"

  # 5. the assertion that makes the arm valid: the AOT payload is untouched.
  local aot; aot=$(payload_hash "$app/Frameworks/App.framework/App")
  [ "$aot" = "$REF_AOT" ] \
    || die "$suffix: App.framework/App CHANGED ($aot != $REF_AOT) — one patch cannot bind to both"

  printf '  %-4s id=%-40s channel=%-6s aot=%s uuid=%s\n' "$suffix" "$id" "$channel" \
    "${aot:0:12}" "$(dwarfdump --uuid "$app/Runner" 2>/dev/null | awk '{print $2}' | head -1)"
}

echo "clients :"
make_client tka alpha 'Tracks A'
make_client tkb beta  'Tracks B'

echo
echo "verify  :"
A=$OUT/tka.app; B=$OUT/tkb.app
printf '  AOT payload identical   : %s\n' \
  "$([ "$(payload_hash "$A/Frameworks/App.framework/App")" = \
       "$(payload_hash "$B/Frameworks/App.framework/App")" ] && echo YES || echo NO)"
printf '  ...and equal to source  : %s\n' \
  "$([ "$(payload_hash "$A/Frameworks/App.framework/App")" = "$REF_AOT" ] && echo YES || echo NO)"
printf '  signed files DO differ  : %s (expected -- the signature blob)\n' \
  "$([ "$(shasum -a256 "$A/Frameworks/App.framework/App"|cut -d' ' -f1)" != \
       "$(shasum -a256 "$B/Frameworks/App.framework/App"|cut -d' ' -f1)" ] && echo YES || echo NO)"
printf '  bundle ids differ       : %s / %s\n' \
  "$(plutil -extract CFBundleIdentifier raw "$A/Info.plist")" \
  "$(plutil -extract CFBundleIdentifier raw "$B/Info.plist")"
printf '  exec UUIDs differ       : %s\n' \
  "$([ "$(dwarfdump --uuid "$A/Runner" | awk '{print $2}' | head -1)" != \
       "$(dwarfdump --uuid "$B/Runner" | awk '{print $2}' | head -1)" ] && echo YES || echo NO)"
printf '  channels differ         : %s / %s\n' \
  "$(sed -n 's/^channel: //p' "$A/Frameworks/App.framework/flutter_assets/shorebird.yaml")" \
  "$(sed -n 's/^channel: //p' "$B/Frameworks/App.framework/flutter_assets/shorebird.yaml")"
printf '  app_id held fixed       : %s / %s\n' \
  "$(sed -n 's/^app_id: //p' "$A/Frameworks/App.framework/flutter_assets/shorebird.yaml")" \
  "$(sed -n 's/^app_id: //p' "$B/Frameworks/App.framework/flutter_assets/shorebird.yaml")"
printf '  release_version fixed   : %s / %s\n' \
  "$(plutil -extract CFBundleShortVersionString raw "$A/Info.plist")+$(plutil -extract CFBundleVersion raw "$A/Info.plist")" \
  "$(plutil -extract CFBundleShortVersionString raw "$B/Info.plist")+$(plutil -extract CFBundleVersion raw "$B/Info.plist")"
for c in "$A" "$B"; do
  codesign --verify --deep --strict "$c" 2>&1 | sed "s|^|  signature $(basename "$c"): |" || true
  printf '  signature %-9s: %s\n' "$(basename "$c")" "$(codesign -dv "$c" 2>&1 | sed -n 's/^Identifier=//p')"
done
