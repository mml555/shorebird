#!/usr/bin/env bash
# cspell:words iosdev
#
# One command to release (and optionally patch) an iOS app against a self-hosted
# code_push_server, choosing the right signing path automatically:
#
#   auto    plain `shorebird release ios` — Xcode project already signs
#           (Apple ID in Xcode or DEVELOPMENT_TEAM set). The normal path.
#   manual  `--export-options-plist` — headless/CI manual signing. Give a
#           profile (IOS_PROFILE) or a ready plist (IOS_EXPORT_OPTIONS).
#   resign  `--no-codesign` + tool/ios_resign.sh — no Apple ID in Xcode; resign
#           an unsigned build with an existing cert + profile.
#
# Mode is IOS_SIGN_MODE if set; else inferred: IOS_EXPORT_OPTIONS -> manual,
# else IOS_PROFILE -> resign, else auto.
#
# Usage:
#   APP_DIR=/path/to/flutterapp DEVICE=<udid> tool/ios_ship.sh [release|patch|both]
#
# Env: SHOREBIRD_TOKEN or OAuth env for the CLI; IOS_PROFILE, IOS_IDENTITY,
#   IOS_EXPORT_OPTIONS, IOS_METHOD (default development), RELEASE_VERSION (patch).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/ios_signing.sh
. "$HERE/lib/ios_signing.sh"
# shellcheck source=lib/ios_device.sh
. "$HERE/lib/ios_device.sh"

ACTION="${1:-release}"
APP_DIR="${APP_DIR:?set APP_DIR to the Flutter app directory}"
DEVICE="${DEVICE:-}"

MODE="${IOS_SIGN_MODE:-}"
if [ -z "$MODE" ]; then
  if [ -n "${IOS_EXPORT_OPTIONS:-}" ]; then MODE=manual
  elif [ -n "${IOS_PROFILE:-}" ]; then MODE=resign
  else MODE=auto; fi
fi
echo "== iOS ship: action=$ACTION mode=$MODE =="

cd "$APP_DIR"

# Build the mode-specific release/patch flags, and (for manual) an export plist.
REL_FLAGS=() PATCH_FLAGS=()
case "$MODE" in
  auto) ;;
  manual)
    OPTS="${IOS_EXPORT_OPTIONS:-}"
    if [ -z "$OPTS" ]; then
      : "${IOS_PROFILE:?manual mode needs IOS_PROFILE or IOS_EXPORT_OPTIONS}"
      OPTS="$(mktemp -t eo).plist"
      "$HERE/ios_export_options.sh" --profile "$IOS_PROFILE" \
        --method "${IOS_METHOD:-development}" --out "$OPTS" >/dev/null
    fi
    REL_FLAGS+=(--export-options-plist="$OPTS")
    PATCH_FLAGS+=(--export-options-plist="$OPTS")
    ;;
  resign)
    : "${IOS_PROFILE:?resign mode needs IOS_PROFILE}"
    REL_FLAGS+=(--no-codesign)
    PATCH_FLAGS+=(--no-codesign)  # patch only diffs; device runs the signed app
    ;;
  *) ios::_err "invalid IOS_SIGN_MODE '$MODE' (auto|manual|resign)"; exit 2 ;;
esac

find_app()  { find build/ios/archive -name 'Runner.app' -path '*Products/Applications*' 2>/dev/null | head -1; }
find_ipa()  { find build/ios/ipa -name '*.ipa' 2>/dev/null | head -1; }

install_to_device() {
  [ -n "$DEVICE" ] || { echo "(no DEVICE set — skipping install)"; return 0; }
  local artifact="$1"
  # Transport is chosen by the device's iOS version: devicectl is iOS 17+ only,
  # and an older device is invisible to it rather than merely unsupported. See
  # lib/ios_device.sh.
  if iosdev::install "$DEVICE" "$artifact"; then
    return 0
  fi
  ios::_err "install failed — install manually (Xcode ▸ Devices, or ios-deploy)"
  return 1
}

do_release() {
  echo "-- shorebird release ios ${REL_FLAGS[*]:-} --"
  shorebird release ios "${REL_FLAGS[@]}"
  if [ "$MODE" = resign ]; then
    local app; app="$(find_app)"
    [ -n "$app" ] || { ios::_err "no unsigned Runner.app found under build/ios/archive"; exit 1; }
    IOS_DEVICE_UDID="$DEVICE" "$HERE/ios_resign.sh" "$app" "${IOS_IDENTITY:-}" "$IOS_PROFILE"
    install_to_device "$app"
  else
    local ipa; ipa="$(find_ipa)"
    if [ -n "$ipa" ]; then install_to_device "$ipa"
    else ios::_err "no signed .ipa under build/ios/ipa (check signing config)"; fi
  fi
}

do_patch() {
  local rv=()
  [ -n "${RELEASE_VERSION:-}" ] && rv+=(--release-version="$RELEASE_VERSION")
  echo "-- shorebird patch ios ${PATCH_FLAGS[*]:-} ${rv[*]:-} --"
  shorebird patch ios "${PATCH_FLAGS[@]}" "${rv[@]}"
  echo "Patch published. Relaunch the app twice on the device: the updater"
  echo "downloads on launch N and applies on launch N+1 (same as Android)."
}

case "$ACTION" in
  release) do_release ;;
  patch)   do_patch ;;
  both)    do_release; do_patch ;;
  *) ios::_err "action must be release|patch|both"; exit 2 ;;
esac
