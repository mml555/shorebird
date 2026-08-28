#!/usr/bin/env bash
# Import one exact upstream artifact into the owned overlay, from a SEALED
# REFUSAL URI as it appears in the mirror's access log.
#
#   mirror_cdn_artifact.sh /gcs/flutter_infra_release/flutter/fonts/<h>/fonts.zip
#
# THE MAPPING IS NOT THE IDENTITY, and getting it wrong silently produces a file
# nobody serves. Caddy rewrites the CLIENT path to a /gcs/<bucket>/… path for the
# upstream fetch, while the overlay is keyed by the CLIENT path:
#
#   client   /flutter_infra_release/flutter/<eng>/dart-sdk-linux-x64.zip
#   upstream /gcs/download.shorebird.dev/flutter_infra_release/flutter/<eng>/…
#   overlay  /overlay/flutter_infra_release/flutter/<eng>/dart-sdk-linux-x64.zip
#
# so a leading bucket segment belongs to the upstream address, not to the overlay
# layout. @overlay_hit is a plain try_files against the overlay root, so any path
# can be owned this way — not only engine-hash ones.
#
# Same discipline as mirror_bootstrap_artifact.sh: verify the body against the
# declared Content-Length before banking, and never overwrite differing bytes.
set -euo pipefail

URI="${1:?usage: mirror_cdn_artifact.sh /gcs/<bucket-path>}"
LABEL="${2:-release-patch}"

REPO=/Users/mendell/shorebird
OVERLAY_ROOT="$REPO/selfhost/cdn/overlay"
LEDGER="$REPO/selfhost/evidence/r12-linux-ci/${LABEL}_closure.tsv"

die() { echo "FAIL: $*" >&2; exit 1; }

case "$URI" in
  /gcs/*) ;;
  *) die "expected a /gcs/… refusal URI, got '$URI'" ;;
esac
case "$URI" in *..*) die "refusing suspicious path '$URI'" ;; esac

GCS_PATH="${URI#/gcs/}"                       # <bucket>/<object…>
UPSTREAM="https://storage.googleapis.com/$GCS_PATH"

# The overlay is keyed by the client path: drop a leading download.shorebird.dev
# bucket segment, keep everything else exactly as-is.
CLIENT_PATH="$GCS_PATH"
case "$CLIENT_PATH" in
  download.shorebird.dev/flutter_infra_release/*)
    CLIENT_PATH="${CLIENT_PATH#download.shorebird.dev/}" ;;
esac
DEST="$OVERLAY_ROOT/$CLIENT_PATH"

declared="$(curl -sSI -m 60 "$UPSTREAM" | tr -d '\r' \
            | awk 'tolower($1)=="content-length:"{print $2}' | tail -1)"
[[ -n "$declared" ]] || die "no Content-Length from $UPSTREAM (does the object exist?)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL --retry 3 --retry-delay 2 -m 1800 -o "$TMP/blob" "$UPSTREAM" \
  || die "download failed: $UPSTREAM"
got="$(wc -c < "$TMP/blob" | tr -d ' ')"
[[ "$got" == "$declared" ]] \
  || die "TRUNCATED: got $got bytes, Content-Length declared $declared ($UPSTREAM)"
sha="$(shasum -a 256 "$TMP/blob" | awk '{print $1}')"

if [[ -f "$DEST" ]]; then
  have="$(shasum -a 256 "$DEST" | awk '{print $1}')"
  [[ "$have" == "$sha" ]] && { echo "already owned, bytes identical: $CLIENT_PATH"; exit 0; }
  die "overlay already holds $CLIENT_PATH with DIFFERENT bytes
     owned  $have
     remote $sha
     Refusing to overwrite. Investigate before touching it."
fi

mkdir -p "$(dirname "$DEST")"
cp "$TMP/blob" "$DEST"

mkdir -p "$(dirname "$LEDGER")"
[[ -f "$LEDGER" ]] || printf 'client_path\tbytes\tsha256\tsource\n' > "$LEDGER"
printf '%s\t%s\t%s\t%s\n' "$CLIENT_PATH" "$got" "$sha" "$UPSTREAM" >> "$LEDGER"

echo "owned: $CLIENT_PATH"
echo "  bytes  $got"
echo "  sha256 $sha"
echo "  source $UPSTREAM"
