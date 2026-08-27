#!/usr/bin/env bash
# cspell:words codesign mobileprovision entitlements jarsigner apksigner plutil CDHash certs
#
# signing_state.sh -- measure the platform-signing state of a release artifact.
#
# Arm B asks one narrow question: does publishing a Shorebird patch mutate the
# already-signed application release? This script produces the BEFORE and AFTER
# measurements. It never modifies the artifact it is given.
#
# THE LOAD-BEARING FIELD IS THE WHOLE-ARTIFACT DIGEST. If the server-fetched
# bytes are identical before and after, every embedded signing structure is
# necessarily identical too. The platform-specific fields then establish that
# what stayed the same was a VALIDLY SIGNED package rather than merely a stable
# blob.
#
#   signing_state.sh ios <artifact.zip|xcarchive-dir|Runner.app>
#   signing_state.sh android <app.aab|app.apk>
#
# Output is one `key: value` per line, sorted, so two runs diff cleanly.
set -uo pipefail

MODE=${1:?usage: signing_state.sh <ios|android> <artifact>}
ART=${2:?usage: signing_state.sh <ios|android> <artifact>}
[ -e "$ART" ] || { echo "no artifact at $ART" >&2; exit 2; }

emit() { printf '%s: %s\n' "$1" "$2"; }
digest() { shasum -a 256 "$1" | cut -d' ' -f1; }

# The whole-artifact digest, computed on exactly the bytes handed to us.
if [ -f "$ART" ]; then
  emit artifact_sha256 "$(digest "$ART")"
  emit artifact_bytes "$(stat -f%z "$ART")"
else
  # A directory: hash the sorted file list plus contents so the value is stable.
  emit artifact_sha256 "$(cd "$ART" && find . -type f -print0 | sort -z \
    | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)"
  emit artifact_bytes "dir"
fi

case "$MODE" in
ios)
  W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
  APP=""
  if [ -d "$ART" ]; then
    case "$ART" in
      *.app) APP=$ART ;;
      *) APP=$(find "$ART" -maxdepth 4 -name '*.app' -type d | head -1) ;;
    esac
  else
    # A zip: an IPA (Payload/*.app) or a zipped xcarchive.
    unzip -q -o "$ART" -d "$W" 2>/dev/null || true
    APP=$(find "$W" -maxdepth 6 -name '*.app' -type d | head -1)
  fi
  [ -n "$APP" ] || { echo "no .app inside $ART" >&2; exit 2; }
  emit app_bundle_name "$(basename "$APP")"

  # Verification. Reported as a value rather than an exit code so a BEFORE/AFTER
  # diff shows a change from PASS to FAIL instead of aborting the run.
  if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
    emit codesign_verify PASS
  else
    emit codesign_verify FAIL
  fi

  DV=$(codesign -dv --verbose=4 "$APP" 2>&1 || true)
  emit identifier      "$(printf '%s' "$DV" | sed -n 's/^Identifier=//p' | head -1)"
  emit team_identifier "$(printf '%s' "$DV" | sed -n 's/^TeamIdentifier=//p' | head -1)"
  emit authority       "$(printf '%s' "$DV" | sed -n 's/^Authority=//p' | head -1)"
  emit cd_hash         "$(printf '%s' "$DV" | sed -n 's/^CandidateCDHash sha256=//p' | head -1)"
  emit cd_hashes       "$(printf '%s' "$DV" | sed -n 's/^CDHash=//p' | head -1)"

  PROF="$APP/embedded.mobileprovision"
  if [ -f "$PROF" ]; then
    emit profile_sha256 "$(digest "$PROF")"
    PLIST=$(security cms -D -i "$PROF" 2>/dev/null || true)
    get() { printf '%s' "$PLIST" | plutil -extract "$1" raw - 2>/dev/null || echo ''; }
    emit profile_uuid            "$(get UUID)"
    emit profile_name            "$(get Name)"
    emit profile_team_identifier "$(get 'TeamIdentifier.0')"
    emit profile_app_identifier  "$(get 'Entitlements.application-identifier')"
    emit profile_expiration      "$(get ExpirationDate)"
  else
    emit profile_sha256 ABSENT
  fi

  # Entitlements, NORMALIZED before hashing. codesign can emit these as binary
  # or xml with incidental ordering, and comparing raw output would manufacture
  # differences that mean nothing about signing.
  ENT="$W/entitlements.plist"
  if codesign -d --entitlements :- --xml "$APP" > "$ENT" 2>/dev/null && [ -s "$ENT" ]; then
    plutil -convert xml1 "$ENT" 2>/dev/null || true
    emit entitlements_normalized_sha256 "$(digest "$ENT")"
    emit entitlements_get_task_allow \
      "$(plutil -extract 'get-task-allow' raw "$ENT" 2>/dev/null || echo absent)"
    emit entitlements_app_identifier \
      "$(plutil -extract 'application-identifier' raw "$ENT" 2>/dev/null || echo absent)"
  else
    emit entitlements_normalized_sha256 ABSENT
  fi
  ;;

android)
  case "$ART" in
    *.apk)
      if command -v apksigner >/dev/null 2>&1; then
        OUT=$(apksigner verify --verbose --print-certs "$ART" 2>&1 || true)
        printf '%s' "$OUT" | grep -q 'Verifies' \
          && emit apk_verify PASS || emit apk_verify FAIL
        emit signer_cert_sha256 \
          "$(printf '%s' "$OUT" | sed -n 's/.*SHA-256 digest: *//p' | head -1)"
        emit signer_dn \
          "$(printf '%s' "$OUT" | sed -n 's/.*certificate DN: *//p' | head -1)"
        for s in 'v1 scheme' 'v2 scheme' 'v3 scheme'; do
          emit "scheme_${s%% *}" \
            "$(printf '%s' "$OUT" | sed -n "s/.*Verified using $s ([^)]*): *//p" | head -1)"
        done
      else
        emit apk_verify APKSIGNER_UNAVAILABLE
      fi
      ;;
    *.aab)
      # An AAB is a jar-signed zip; jarsigner is the oracle.
      if command -v jarsigner >/dev/null 2>&1; then
        OUT=$(jarsigner -verify -verbose:summary -certs "$ART" 2>&1 || true)
        printf '%s' "$OUT" | grep -q 'jar verified' \
          && emit aab_verify PASS || emit aab_verify FAIL
        emit aab_verify_detail \
          "$(printf '%s' "$OUT" | grep -iE 'jar verified|jar is unsigned|no manifest' | head -1)"
        emit signer_dn \
          "$(printf '%s' "$OUT" | sed -n 's/^ *X\.509, *//p' | head -1)"
        emit signature_algorithm \
          "$(printf '%s' "$OUT" | sed -n 's/^ *Signature algorithm: *//p' | head -1)"
        # jarsigner does not print certificate fingerprints in this mode, so the
        # signer identity comes from the signature block itself via keytool.
        # Without this the field came back EMPTY, which would have compared
        # "equal" before and after while proving nothing about the signer.
        CERT=$(unzip -p "$ART" 'META-INF/*.RSA' 'META-INF/*.DSA' 'META-INF/*.EC' \
          2>/dev/null | keytool -printcert 2>/dev/null || true)
        emit signer_cert_sha256 \
          "$(printf '%s' "$CERT" | sed -n 's/^[[:space:]]*SHA256:[[:space:]]*//p' \
            | head -1 | tr -d ' ')"
        emit signer_cert_owner \
          "$(printf '%s' "$CERT" | sed -n 's/^Owner: *//p' | head -1)"
      else
        emit aab_verify JARSIGNER_UNAVAILABLE
      fi
      ;;
    *) echo "unsupported android artifact: $ART" >&2; exit 2 ;;
  esac
  ;;
*) echo "unknown mode: $MODE" >&2; exit 2 ;;
esac
