#!/usr/bin/env bash
#
# Shared iOS code-signing helpers for the self-host tooling. Source, don't run:
#
#   . "$(dirname "$0")/lib/ios_signing.sh"
#
# Everything here is read-only profile/keychain inspection built on the macOS
# signing stack (security, plutil, PlistBuddy, codesign). Functions print their
# result to stdout and return non-zero (with a message on stderr) on failure.
#
# The one non-obvious bit: a `.mobileprovision` is a CMS-signed blob, so it must
# be decoded to a plist before anything can read it — that's `ios::decode`.

# shellcheck shell=bash

ios::_err() { printf 'ios-signing: %s\n' "$*" >&2; }

# Decode a .mobileprovision (CMS blob) to a plain plist file. macOS 13+ prefers
# `-o`; older releases only support stdout redirection, so we handle both.
ios::decode() {
  local profile="$1" out="$2"
  [ -f "$profile" ] || { ios::_err "profile not found: $profile"; return 1; }
  if ! security cms -D -i "$profile" -o "$out" 2>/dev/null; then
    security cms -D -i "$profile" >"$out" 2>/dev/null ||
      { ios::_err "could not decode profile (not a .mobileprovision?): $profile"; return 1; }
  fi
  [ -s "$out" ] || { ios::_err "decoded profile is empty: $profile"; return 1; }
}

# Print a top-level scalar (UUID, Name, ...) from a decoded profile plist.
ios::field() {
  local decoded="$1" key="$2"
  plutil -extract "$key" raw -o - "$decoded" 2>/dev/null
}

# Write the profile's real Entitlements dict to `out` as a standalone plist.
# This is the whole point of the hardened resign: keep every declared capability
# (push, app groups, associated domains, keychain groups, ...) instead of a
# hand-written minimal set that silently strips them.
ios::entitlements() {
  local decoded="$1" out="$2"
  plutil -extract Entitlements xml1 -o "$out" "$decoded" 2>/dev/null ||
    { ios::_err "profile has no Entitlements dict"; return 1; }
  [ -s "$out" ]
}

# Team id: prefer the entitlement, fall back to the TeamIdentifier array.
ios::team() {
  local decoded="$1" team
  team="$(plutil -extract 'Entitlements.com.apple.developer.team-identifier' raw -o - "$decoded" 2>/dev/null)"
  [ -n "$team" ] || team="$(plutil -extract 'TeamIdentifier.0' raw -o - "$decoded" 2>/dev/null)"
  [ -n "$team" ] && printf '%s\n' "$team"
}

# Bundle id derived from `application-identifier` (= TEAM.bundle). Prints the
# bundle portion; prints `*` for a wildcard profile (caller must then supply an
# explicit bundle id).
ios::bundle_id() {
  local decoded="$1" appid team bundle
  appid="$(plutil -extract 'Entitlements.application-identifier' raw -o - "$decoded" 2>/dev/null)" || return 1
  team="${appid%%.*}"
  bundle="${appid#"$team".}"
  printf '%s\n' "$bundle"
}

# `true` for a development profile (get-task-allow enabled), `false` for
# ad-hoc/distribution. Drives the entitlement we sign with.
ios::get_task_allow() {
  local decoded="$1" v
  v="$(plutil -extract 'Entitlements.get-task-allow' raw -o - "$decoded" 2>/dev/null)"
  [ "$v" = "true" ] && printf 'true\n' || printf 'false\n'
}

# Succeeds if the profile provisions the given device UDID. A distribution
# profile has no ProvisionedDevices; treat that as "not a device profile".
ios::provisions_device() {
  local decoded="$1" udid="$2" xml
  xml="$(plutil -extract ProvisionedDevices xml1 -o - "$decoded" 2>/dev/null)" || return 2
  # UDIDs are hex; compare case-insensitively.
  printf '%s\n' "$xml" | grep -iq "<string>$udid</string>"
}

# Warn (don't fail) if the profile is past its ExpirationDate.
ios::warn_if_expired() {
  local decoded="$1" exp
  exp="$(ios::field "$decoded" ExpirationDate)" || return 0
  [ -n "$exp" ] || return 0
  # ExpirationDate is ISO-8601 (e.g. 2026-09-01T12:00:00Z). Lexical compare
  # against `now` in the same format is correct for UTC 'Z' timestamps.
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ "$exp" < "$now" ]]; then
    ios::_err "WARNING: provisioning profile expired on $exp"
  fi
}

# Resolve a codesigning identity SHA-1. If `$1` is non-empty it's taken as-is.
# Otherwise: if exactly one codesigning identity is in the keychain, use it;
# if several, error and list them (matching by team from a cert subject isn't
# reliable, so we ask the caller to pick rather than guess wrong).
ios::resolve_identity() {
  local given="$1"
  if [ -n "$given" ]; then printf '%s\n' "$given"; return 0; fi
  local ids
  ids="$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '[0-9A-F]{40}' | sort -u)"
  local count
  count="$(printf '%s\n' "$ids" | grep -c . || true)"
  if [ "$count" -eq 1 ]; then printf '%s\n' "$ids"; return 0; fi
  if [ "$count" -eq 0 ]; then
    ios::_err "no codesigning identities in the keychain (import a .p12 or use tool/ios_ci_keychain.sh)"
    return 1
  fi
  ios::_err "multiple codesigning identities — pass one explicitly:"
  security find-identity -v -p codesigning >&2
  return 1
}
