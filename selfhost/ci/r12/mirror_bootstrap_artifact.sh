#!/usr/bin/env bash
# Import ONE exact upstream Flutter bootstrap artifact into the owned overlay.
#
#   mirror_bootstrap_artifact.sh <engine-revision> <relative/path.zip>
#
# WHAT THIS IS. The narrowest possible repair for the R12 prerequisite: the
# supported Flutter pin names engine 69f9831c…, and our overlay publishes no
# Flutter artifacts at that address, so a cold bootstrap escapes to upstream GCS.
# This moves the HOSTING of those exact bytes from upstream to owned. It does not
# rebuild, re-sign, repack or otherwise produce different bytes:
#
#     source identity   unchanged      flutter pin      unchanged
#     engine identity   unchanged      certified runtime unchanged
#     artifact bytes    unchanged      hosting          upstream -> owned
#
# WHAT IT REFUSES TO DO. It will not overwrite an existing overlay file whose
# bytes differ. Silently replacing a published artifact is how a mirror stops
# being a mirror, and the overlay is what the CDN serves in preference to
# everything else.
set -euo pipefail

ENG="${1:?usage: mirror_bootstrap_artifact.sh <engine-revision> <relative/path>}"
REL="${2:?usage: mirror_bootstrap_artifact.sh <engine-revision> <relative/path>}"

REPO=/Users/mendell/shorebird
OVERLAY="$REPO/selfhost/cdn/overlay/flutter_infra_release/flutter"
LEDGER="$REPO/selfhost/evidence/r12-linux-ci/bootstrap_closure.tsv"
UPSTREAM="https://storage.googleapis.com/download.shorebird.dev/flutter_infra_release/flutter"

die() { echo "FAIL: $*" >&2; exit 1; }

[[ "$ENG" =~ ^[0-9a-f]{40}$ ]] || die "engine '$ENG' is not 40 lowercase hex"
case "$REL" in
  */../*|/*|*..*) die "refusing suspicious relative path '$REL'" ;;
esac

URL="$UPSTREAM/$ENG/$REL"
DEST="$OVERLAY/$ENG/$REL"

# Declared length first, so a truncated body is caught by comparison rather than
# trusted. The 2026-08-28 checkpoint saw a transfer die after 21 bytes; a mirror
# that banks a short read publishes corruption under an owned name.
declared="$(curl -sSI -m 60 "$URL" | tr -d '\r' \
            | awk 'tolower($1)=="content-length:"{print $2}' | tail -1)"
[[ -n "$declared" ]] || die "no Content-Length from $URL (does the object exist?)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL --retry 3 --retry-delay 2 -m 900 -o "$TMP/blob" "$URL" \
  || die "download failed: $URL"

got="$(wc -c < "$TMP/blob" | tr -d ' ')"
[[ "$got" == "$declared" ]] \
  || die "TRUNCATED: got $got bytes, Content-Length declared $declared ($URL)"
sha="$(shasum -a 256 "$TMP/blob" | awk '{print $1}')"

if [[ -f "$DEST" ]]; then
  have="$(shasum -a 256 "$DEST" | awk '{print $1}')"
  [[ "$have" == "$sha" ]] \
    && { echo "already owned, bytes identical: $ENG/$REL"; exit 0; }
  die "overlay already holds $ENG/$REL with DIFFERENT bytes
     owned  $have
     remote $sha
     Refusing to overwrite. Investigate before touching it."
fi

mkdir -p "$(dirname "$DEST")"
cp "$TMP/blob" "$DEST"

mkdir -p "$(dirname "$LEDGER")"
[[ -f "$LEDGER" ]] || printf 'engine\tartifact\tbytes\tsha256\tsource\n' > "$LEDGER"
printf '%s\t%s\t%s\t%s\t%s\n' "$ENG" "$REL" "$got" "$sha" "$URL" >> "$LEDGER"

echo "owned: $ENG/$REL"
echo "  bytes  $got"
echo "  sha256 $sha"
echo "  source $URL"
