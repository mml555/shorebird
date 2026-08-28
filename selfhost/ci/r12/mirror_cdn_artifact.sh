#!/usr/bin/env bash
# Import one exact upstream artifact into the owned overlay.
#
#   mirror_cdn_artifact.sh <client_path> <gcs_path> [label]
#
# TWO ADDRESSES, AND THEY ARE NOT THE SAME ONE. The overlay is consulted on the
# path the CLIENT asked for; the bytes live upstream at the path Caddy/the
# artifact proxy REWRITES that to. They differ in more than a bucket prefix — the
# proxy also remaps the engine hash for artifacts Shorebird does not rebuild:
#
#   client   /flutter_infra_release/flutter/69f9831c…/sky_engine.zip
#   upstream /gcs/flutter_infra_release/flutter/83675ed2…/sky_engine.zip
#                                       ^^^^^^^^ different hash
#
# An earlier version of this script derived the overlay destination from the
# upstream URI by stripping /gcs/ and a bucket segment. For that pair it wrote
# 83675ed2…/sky_engine.zip — a real file, correct bytes, at an address nothing
# ever requests. The mirror reported success, the seal kept refusing, and the
# discovery loop burned 28 iterations re-importing a file it already had. So BOTH
# paths are now required arguments: the caller must pair the 502 with the 302
# that produced it, and this script will not guess.
set -euo pipefail

CLIENT="${1:?usage: mirror_cdn_artifact.sh <client_path> <gcs_path> [label]}"
GCS="${2:?usage: mirror_cdn_artifact.sh <client_path> <gcs_path> [label]}"
LABEL="${3:-release_patch}"

REPO=/Users/mendell/shorebird
OVERLAY_ROOT="$REPO/selfhost/cdn/overlay"
LEDGER="$REPO/selfhost/evidence/r12-linux-ci/${LABEL}_closure.tsv"

die() { echo "FAIL: $*" >&2; exit 1; }

case "$CLIENT$GCS" in *..*) die "refusing suspicious path" ;; esac
GCS_PATH="${GCS#/gcs/}"; GCS_PATH="${GCS_PATH#/}"
CLIENT_PATH="${CLIENT#/}"
[[ -n "$GCS_PATH" && -n "$CLIENT_PATH" ]] || die "empty path"

UPSTREAM="https://storage.googleapis.com/$GCS_PATH"
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
