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
# Not covered: the `unsigned` USB variant Flutter fetches when it is set to use
# unsigned Mac binaries, and the Gradle distribution itself, which comes from
# services.gradle.org rather than GCS.
#
# Without them the mirror fetches these from upstream GCS through its /gcs/
# passthrough, so a build needs upstream, and a sealed mirror with a cold cache
# refuses them. The overlay is checked before every other route in the
# Caddyfile, so a file placed here is served whatever the engine hash. That is
# why every path is held to one of the three exact shapes above: a pin naming
# any other path (an engine artifact, say) is refused rather than shadowed.
#
# A download is checked against the md5 GCS sends in `x-goog-hash`, opened as
# an archive, and renamed into place. A file already in the overlay is checked
# the same way against a HEAD request, so --check also needs the network.
# Downloads are staged in a directory beside the overlay, never inside it.
#
# Usage:
#   publish_flutter_pins.sh --flutter <checkout> --overlay <dir> [--ref <rev>]
#                           [--from <base url>] [--check]
#
#   --flutter  a Flutter checkout (the fork's shorebird-flutter)
#   --ref      read the pins from that checkout's git history at this revision
#              (`git show`) instead of its working tree, e.g. the CLI's
#              bin/internal/flutter.version
#   --overlay  the mirror's overlay directory (selfhost/cdn/overlay)
#   --from     where to fetch from (default https://storage.googleapis.com);
#              any base serving the bucket paths and x-goog-hash works
#   --check    download nothing; list each file as present, MISSING or BROKEN
#              and exit 1 if any is not present
#
# Run it for every Flutter revision the mirror serves; it is idempotent.
set -euo pipefail
umask 022

FLUTTER="" REF="" OVERLAY="" FROM="https://storage.googleapis.com" CHECK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --flutter) FLUTTER="${2:?--flutter needs a value}"; shift 2 ;;
    --ref) REF="${2:?--ref needs a value}"; shift 2 ;;
    --overlay) OVERLAY="${2:?--overlay needs a value}"; shift 2 ;;
    --from) FROM="${2:?--from needs a value}"; FROM="${FROM%/}"; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '4,44p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done
[[ -n "$FLUTTER" && -n "$OVERLAY" ]] || { echo "--flutter and --overlay are required (see --help)" >&2; exit 2; }
[[ -d "$OVERLAY" ]] || { echo "no overlay directory at $OVERLAY" >&2; exit 2; }
for tool in curl openssl python3; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 2; }
done

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
  | sed -n "s/^[[:space:]]*'\([a-z0-9-]*\)',[[:space:]]*$/\1/p")
[[ -n "$USB_NAMES" ]] || { echo "found no IosUsbArtifacts.artifactNames in flutter_cache.dart; update this script" >&2; exit 2; }

HEX40='[0-9a-f]{40}'
PATHS=()
for name in $USB_NAMES; do
  ver=$(pin "bin/internal/$name.version" | tr -d '[:space:]')
  [[ "$ver" =~ ^$HEX40$ ]] || { echo "bin/internal/$name.version is not a 40-hex revision: '$ver'" >&2; exit 2; }
  PATHS+=("flutter_infra_release/ios-usb-dependencies/arm64_x86_64/$name/$ver/$name.zip")
done
fonts=$(pin bin/internal/material_fonts.version | tr -d '[:space:]')
[[ "$fonts" =~ ^flutter_infra_release/flutter/fonts/$HEX40/fonts\.zip$ ]] \
  || { echo "material_fonts.version is not flutter_infra_release/flutter/fonts/<40-hex>/fonts.zip: '$fonts'" >&2; exit 2; }
wrapper=$(pin bin/internal/gradle_wrapper.version | tr -d '[:space:]')
[[ "$wrapper" =~ ^flutter_infra_release/gradle-wrapper/$HEX40/gradle-wrapper\.tgz$ ]] \
  || { echo "gradle_wrapper.version is not flutter_infra_release/gradle-wrapper/<40-hex>/gradle-wrapper.tgz: '$wrapper'" >&2; exit 2; }
PATHS+=("$fonts" "$wrapper")

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

# The md5 GCS reports in the final response of a header dump (after any
# redirect), whether x-goog-hash comes as one header per hash or folded.
md5_from_headers() {
  tr -d '\r' < "$1" | awk '
    /^HTTP\// { m = "" }
    tolower($1) == "x-goog-hash:" {
      sub(/^[^:]*:[ \t]*/, "")
      n = split($0, parts, /[ \t]*,[ \t]*/)
      for (i = 1; i <= n; i++) if (parts[i] ~ /^md5=/) m = substr(parts[i], 5)
    }
    END { print m }'
}

md5_of() { openssl dgst -md5 -binary "$1" | openssl base64 -A; }

CURL=(curl -fsSL --retry 2 --proto '=https,http' --proto-redir '=https,http')

STAGE=""
cleanup() { [[ -n "$STAGE" ]] && rm -rf "$STAGE"; }
trap cleanup EXIT
STAGE=$(mktemp -d "$(cd "$OVERLAY/.." && pwd)/.publish_flutter_pins.XXXXXX")

missing=0 broken=0 fetched=0 kept=0
for rel in "${PATHS[@]}"; do
  dest="$OVERLAY/$rel"
  if [[ -f "$dest" ]]; then
    why=""
    if ! "${CURL[@]}" -I -o /dev/null -D "$STAGE/h" "$FROM/$rel"; then
      why="could not HEAD $FROM/$rel to verify it"
    else
      want=$(md5_from_headers "$STAGE/h")
      if [[ -z "$want" ]]; then why="$FROM/$rel sent no md5 to verify it against"
      elif [[ "$(md5_of "$dest")" != "$want" ]]; then why="md5 differs from GCS ($want)"
      elif ! archive_ok "$dest" "$rel"; then why="not a readable archive"
      fi
    fi
    if [[ -z "$why" ]]; then echo "present $rel"; kept=$((kept + 1)); continue; fi
    echo "BROKEN  $rel: $why" >&2; broken=$((broken + 1))
    [[ $CHECK -eq 1 ]] && continue
    echo "remove it, or fix the cause, and re-run" >&2; exit 1
  fi
  if [[ $CHECK -eq 1 ]]; then echo "MISSING $rel"; missing=$((missing + 1)); continue; fi

  tmp="$STAGE/body"
  "${CURL[@]}" -D "$STAGE/h" -o "$tmp" "$FROM/$rel" \
    || { echo "could not fetch $FROM/$rel" >&2; exit 1; }
  want=$(md5_from_headers "$STAGE/h")
  [[ -n "$want" ]] || { echo "$FROM/$rel sent no md5 in x-goog-hash; cannot verify it" >&2; exit 1; }
  got=$(md5_of "$tmp")
  [[ "$got" == "$want" ]] || { echo "md5 mismatch for $rel: got $got, GCS says $want" >&2; exit 1; }
  archive_ok "$tmp" "$rel" || { echo "$rel downloaded but is not a readable archive" >&2; exit 1; }
  chmod 644 "$tmp"
  mkdir -p "$(dirname "$dest")"
  mv "$tmp" "$dest"
  echo "fetched $rel (md5 $got)"; fetched=$((fetched + 1))
done

if [[ $CHECK -eq 1 ]]; then
  echo "present: $kept, missing: $missing, broken: $broken"
  [[ $missing -eq 0 && $broken -eq 0 ]]
else
  echo "fetched: $fetched, already present: $kept"
fi
