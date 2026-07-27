#!/usr/bin/env bash
#
# Set up (or tear down) a temporary keychain + provisioning profile so
# `shorebird release ios --export-options-plist=...` can codesign on a headless
# machine (CI) with no Xcode UI and no login-keychain pollution.
#
# Secrets: pass the .p12 password via the IOS_P12_PASSWORD env var, NOT on the
# command line (argv is visible to other processes). This script only imports a
# cert you already own into a throwaway keychain; it never transmits it.
#
# Usage:
#   IOS_P12_PASSWORD=... tool/ios_ci_keychain.sh setup \
#       --p12 cert.p12 --profile dev.mobileprovision
#   tool/ios_ci_keychain.sh teardown
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/ios_signing.sh
. "$HERE/lib/ios_signing.sh"

KEYCHAIN="$HOME/Library/Keychains/shorebird-ci.keychain-db"
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
STATE="${TMPDIR:-/tmp}/shorebird-ci-keychain.state"

cmd="${1:-}"; shift || true
P12="" PROFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --p12) P12="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    *) ios::_err "unknown arg: $1"; exit 2 ;;
  esac
done

setup() {
  [ -f "$P12" ] || { ios::_err "--p12 file not found: $P12"; exit 1; }
  [ -f "$PROFILE" ] || { ios::_err "--profile file not found: $PROFILE"; exit 1; }
  local p12pw="${IOS_P12_PASSWORD:-}"
  [ -n "$p12pw" ] || { ios::_err "set IOS_P12_PASSWORD (the .p12 export password)"; exit 1; }
  # Random per-run keychain password; the keychain is throwaway.
  local kcpw
  kcpw="$(security list-keychains >/dev/null 2>&1; head -c16 /dev/urandom | xxd -p)"

  security create-keychain -p "$kcpw" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"   # auto-lock after 6h
  security unlock-keychain -p "$kcpw" "$KEYCHAIN"
  # Prepend to the search list so codesign/xcodebuild find the identity.
  local existing
  existing="$(security list-keychains -d user | sed 's/[”"]//g' | xargs)"
  # shellcheck disable=SC2086
  security list-keychains -d user -s "$KEYCHAIN" $existing
  security import "$P12" -k "$KEYCHAIN" -P "$p12pw" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  # Allow codesign to use the imported key without an interactive prompt.
  security set-key-partition-list -S apple-tool:,apple: -k "$kcpw" "$KEYCHAIN" >/dev/null 2>&1 || true

  # Install the profile under its UUID (where Xcode/xcodebuild look for it).
  mkdir -p "$PROFILE_DIR"
  local decoded uuid
  decoded="$(mktemp -t prof).plist"
  ios::decode "$PROFILE" "$decoded"
  uuid="$(ios::field "$decoded" UUID)"
  rm -f "$decoded"
  [ -n "$uuid" ] || { ios::_err "could not read profile UUID"; exit 1; }
  cp "$PROFILE" "$PROFILE_DIR/$uuid.mobileprovision"

  printf '%s\n%s\n' "$KEYCHAIN" "$PROFILE_DIR/$uuid.mobileprovision" >"$STATE"
  echo "keychain ready: $KEYCHAIN"
  echo "profile installed: $uuid.mobileprovision"
  echo "identities:"; security find-identity -v -p codesigning "$KEYCHAIN"
}

teardown() {
  if [ -f "$STATE" ]; then
    local installed
    installed="$(sed -n '2p' "$STATE")"
    [ -n "$installed" ] && rm -f "$installed" || true
  fi
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -f "$STATE"
  echo "torn down: removed $KEYCHAIN and the installed profile"
}

case "$cmd" in
  setup) setup ;;
  teardown) teardown ;;
  *) ios::_err "usage: ios_ci_keychain.sh <setup|teardown> [--p12 f --profile f]"; exit 2 ;;
esac
