#!/usr/bin/env bash
# cspell:words imobiledevice usbmuxd imobiledeviceglue namelist testzip getnames
#
# Copy the Flutter tool's version-pinned downloads that belong to no engine
# hash into the mirror's overlay, so the mirror serves them from local disk:
#
#   flutter_infra_release/ios-usb-dependencies/arm64_x86_64/<name>/<ver>/<name>.zip
#       the six iOS USB tools `flutter precache --ios` fetches (names read from
#       flutter_cache.dart's IosUsbArtifacts.artifactNames, versions from
#       bin/internal/<name>.version)
#   flutter_infra_release/flutter/fonts/<hash>/fonts.zip      (material_fonts.version)
#   flutter_infra_release/gradle-wrapper/<hash>/gradle-wrapper.tgz (gradle_wrapper.version)
#
# Without them the mirror fetches these from upstream GCS through its /gcs/
# passthrough, so a build needs upstream, and a sealed mirror with a cold cache
# refuses them. The overlay is checked before every other route in the
# Caddyfile, so a file placed here is served whatever the engine hash.
#
# Every file is checked against the md5 GCS sends in `x-goog-hash`, then
# opened as an archive, then renamed into place. A file already in the overlay
# is opened as an archive and kept.
#
# Usage:
#   publish_flutter_pins.sh --flutter <checkout> --overlay <dir> [--ref <rev>]
#                           [--from <base url>] [--check]
#
#   --flutter  a Flutter checkout (the fork's shorebird-flutter)
#   --ref      read the pins at this revision (`git show`) instead of the
#              working tree, e.g. the CLI's bin/internal/flutter.version
#   --overlay  the mirror's overlay directory (selfhost/cdn/overlay)
#   --from     where to fetch from (default https://storage.googleapis.com);
#              any base serving the bucket paths and x-goog-hash works
#   --check    fetch nothing; list each file as present or missing and exit 1
#              if any is missing
#
# Run it for every Flutter revision the mirror serves; it is idempotent.
set -euo pipefail

FLUTTER="" REF="" OVERLAY="" FROM="https://storage.googleapis.com" CHECK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --flutter) FLUTTER="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --overlay) OVERLAY="$2"; shift 2 ;;
    --from) FROM="${2%/}"; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done
[[ -n "$FLUTTER" && -n "$OVERLAY" ]] || { echo "--flutter and --overlay are required (see --help)" >&2; exit 2; }
[[ -d "$OVERLAY" ]] || { echo "no overlay directory at $OVERLAY" >&2; exit 2; }

# Read a file from the checkout, at --ref when given.
pin() {
  if [[ -n "$REF" ]]; then git -C "$FLUTTER" show "$REF:$1"
  else cat "$FLUTTER/$1"; fi
}

CACHE_DART=$(pin packages/flutter_tools/lib/src/flutter_cache.dart) \
  || { echo "cannot read flutter_cache.dart from $FLUTTER${REF:+ at $REF}" >&2; exit 2; }
# The URL shape this script writes. If Flutter changes it, stop rather than
# publish files nobody will ask for.
case "$CACHE_DART" in
  *"'ios-usb-dependencies/arm64_x86_64"*) ;;
  *) echo "flutter_cache.dart no longer builds ios-usb-dependencies/arm64_x86_64 URLs; update this script" >&2; exit 2 ;;
esac
USB_NAMES=$(printf '%s\n' "$CACHE_DART" \
  | sed -n '/static const artifactNames = <String>\[/,/\];/p' \
  | sed -n "s/^[[:space:]]*'\([A-Za-z0-9._-]*\)',[[:space:]]*$/\1/p")
[[ -n "$USB_NAMES" ]] || { echo "found no IosUsbArtifacts.artifactNames in flutter_cache.dart; update this script" >&2; exit 2; }

PATHS=()
for name in $USB_NAMES; do
  ver=$(pin "bin/internal/$name.version" | tr -d '[:space:]')
  PATHS+=("flutter_infra_release/ios-usb-dependencies/arm64_x86_64/$name/$ver/$name.zip")
done
PATHS+=("$(pin bin/internal/material_fonts.version | tr -d '[:space:]')")
PATHS+=("$(pin bin/internal/gradle_wrapper.version | tr -d '[:space:]')")

# Opens the archive and lists it; a truncated or wrong file fails here.
# $1 the file, $2 the name it is published under (which says zip or tgz).
archive_ok() {
  python3 -I - "$1" "$2" <<'PY' >/dev/null 2>&1
import sys, tarfile, zipfile
p = sys.argv[1]
if sys.argv[2].endswith('.zip'):
    with zipfile.ZipFile(p) as z:
        sys.exit(0 if z.namelist() and z.testzip() is None else 1)
with tarfile.open(p) as t:
    sys.exit(0 if t.getnames() else 1)
PY
}

TMP=""
trap '[[ -n "$TMP" ]] && rm -f "$TMP" "$TMP.h"' EXIT
missing=0 fetched=0 kept=0
for rel in "${PATHS[@]}"; do
  if [[ ! "$rel" =~ ^flutter_infra_release/[A-Za-z0-9._/-]+\.(zip|tgz)$ || "/$rel/" == */../* ]]; then
    echo "refusing unexpected path from the checkout: $rel" >&2; exit 2
  fi
  dest="$OVERLAY/$rel"
  if [[ -f "$dest" ]]; then
    archive_ok "$dest" "$rel" || { echo "BROKEN  $rel (in the overlay, but not a readable archive; remove it and re-run)" >&2; exit 1; }
    echo "present $rel"; kept=$((kept + 1)); continue
  fi
  if [[ $CHECK -eq 1 ]]; then echo "MISSING $rel"; missing=$((missing + 1)); continue; fi

  mkdir -p "$(dirname "$dest")"
  TMP="$dest.$$.tmp"
  curl -fsSL --retry 2 -D "$TMP.h" -o "$TMP" "$FROM/$rel" \
    || { echo "could not fetch $FROM/$rel" >&2; exit 1; }
  # The last response's headers (after any redirect) carry the object's md5.
  want=$(tr -d '\r' < "$TMP.h" | awk 'tolower($1)=="http/1.1"||tolower($1)=="http/2"{m=""} tolower($1)=="x-goog-hash:" && $2 ~ /^md5=/ {m=substr($2,5)} END{print m}')
  [[ -n "$want" ]] || { echo "$FROM/$rel sent no md5 in x-goog-hash; cannot verify it" >&2; exit 1; }
  got=$(openssl dgst -md5 -binary "$TMP" | openssl base64 -A)
  [[ "$got" == "$want" ]] || { echo "md5 mismatch for $rel: got $got, GCS says $want" >&2; exit 1; }
  archive_ok "$TMP" "$rel" || { echo "$rel downloaded but is not a readable archive" >&2; exit 1; }
  chmod 644 "$TMP"
  mv "$TMP" "$dest"; rm -f "$TMP.h"; TMP=""
  echo "fetched $rel (md5 $got)"; fetched=$((fetched + 1))
done

if [[ $CHECK -eq 1 ]]; then
  echo "present: $kept, missing: $missing"
  [[ $missing -eq 0 ]]
else
  echo "fetched: $fetched, already present: $kept"
fi
