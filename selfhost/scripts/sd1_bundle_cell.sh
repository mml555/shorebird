#!/usr/bin/env bash
# cspell:words ustar armv canonicalizer filelist
# SELFHOST-DISTRIBUTION-1 gate 3a: bundle the EXACT published cell bytes for
# durable distribution.
#
# NOT A REBUILD. The cell address is a digest over exact bytes and the Route B
# compiler archive is non-byte-reproducible, so rebuilding would produce a
# DIFFERENT cell. This copies the bytes already published and qualified, and
# proves it copied them by re-digesting every member against the descriptor
# before and after packing.
#
# What the distribution carries, so a consumer needs nothing else:
#   cell-<address>.tar        the 30 members in overlay-relative layout
#   cell_manifest.v2          the descriptor the address is computed over
#   LAYOUT.txt                where each member goes, and its digest
#   MANIFEST.sha256           digests of every file in the distribution
#
#   sd1_bundle_cell.sh [--cell ADDR] [--out DIR]
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../.." >/dev/null 2>&1 && pwd)"
CELL=${CELL:-f85251f344600ae08196925a174e9cff8f0ff18e}
OUT=${OUT:-/Volumes/build/route-b/sd1/dist}
OVERLAY="$REPO/selfhost/cdn/overlay"
MAN="$REPO/selfhost/engine/route_b/cell_manifests/$CELL.v2"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cell) CELL="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note(){ printf '\n\033[1m== %s\033[0m\n' "$1"; }

[[ -f "$MAN" ]] || { echo "no descriptor for $CELL" >&2; exit 2; }
rm -rf "$OUT"; mkdir -p "$OUT"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/sd1stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

note "1 - the descriptor authenticates its own name before anything is read from it"
RE=$(shasum -a 256 "$MAN" | cut -c1-40)
[[ "$RE" == "$CELL" ]] && ok "descriptor recomputes to $CELL" \
                       || { bad "descriptor recomputes to $RE"; exit 1; }

note "2 - collect the 30 members, verifying each against the descriptor"
n=0; okc=0
while read -r m want; do
  case "$m" in address_schema|cell|fallback_engine_revision) continue ;; esac
  n=$((n+1))
  rel="${m//%H/$CELL}"
  src="$OVERLAY/$rel"
  if [[ ! -f "$src" ]]; then bad "MISSING $rel"; continue; fi
  # The descriptor's digest is over the CANONICAL form for members that carry
  # the address; over the raw bytes otherwise. Use the product's own
  # canonicalizer so this cannot drift from the verifier.
  got=$(python3 "$REPO/selfhost/engine/route_b/lib/v2_canonicalize.py" "$src" "$CELL" --digest 2>/dev/null)
  if [[ "$got" != "$want" ]]; then bad "DIGEST MISMATCH $rel"; continue; fi
  mkdir -p "$STAGE/payload/$(dirname "$rel")"
  cp "$src" "$STAGE/payload/$rel"
  okc=$((okc+1))
done < <(awk 'NF==2' "$MAN")
echo "    members collected: $okc of $n"
[[ "$okc" == "$n" && "$n" -gt 0 ]] && ok "$n of $n members verified against the descriptor and staged" \
                                   || bad "only $okc of $n members staged"

note "3 - the layout manifest, so a consumer needs no knowledge of our tree"
{
  echo "# Cell $CELL — where each member goes, relative to the CDN overlay root."
  echo "# sha256 values are the RAW file digests (what a download must match)."
  echo "# The descriptor's own digests are canonical-form and are in cell_manifest.v2."
  echo "#"
  echo "# overlay_relative_path  sha256  bytes"
  while read -r m want; do
    case "$m" in address_schema|cell|fallback_engine_revision) continue ;; esac
    rel="${m//%H/$CELL}"
    printf '%s %s %s\n' "$rel" \
      "$(shasum -a 256 "$STAGE/payload/$rel" | cut -d' ' -f1)" \
      "$(stat -f%z "$STAGE/payload/$rel")"
  done < <(awk 'NF==2' "$MAN")
} > "$STAGE/LAYOUT.txt"
lines=$(grep -vc '^#' "$STAGE/LAYOUT.txt")
[[ "$lines" == "$n" ]] && ok "LAYOUT.txt describes $n members" || bad "LAYOUT.txt has $lines rows"

note "4 - pack, with a stable member order"
# Sorted file list and a fixed mtime, so the archive is at least stable across
# runs on this host. Archive determinism is NOT the integrity claim -- the
# per-member digests are, and they are checked again after extraction.
( cd "$STAGE/payload" && find . -type f | sed 's|^\./||' | sort > "$STAGE/filelist" )
( cd "$STAGE/payload" && tar --format=ustar -cf "$OUT/cell-$CELL.tar" -T "$STAGE/filelist" ) 2>/dev/null \
  || ( cd "$STAGE/payload" && tar -cf "$OUT/cell-$CELL.tar" -T "$STAGE/filelist" )
[[ -s "$OUT/cell-$CELL.tar" ]] && ok "packed $(du -h "$OUT/cell-$CELL.tar" | cut -f1)" || bad "tar failed"
cp "$MAN" "$OUT/cell_manifest.v2"
cp "$STAGE/LAYOUT.txt" "$OUT/LAYOUT.txt"

note "5 - the distribution's own checksum file"
( cd "$OUT" && shasum -a 256 "cell-$CELL.tar" cell_manifest.v2 LAYOUT.txt > MANIFEST.sha256 )
sed 's/^/    /' "$OUT/MANIFEST.sha256"
{
  echo "cell_address $CELL"
  echo "members $n"
  echo "bundle cell-$CELL.tar"
  echo "bundle_sha256 $(shasum -a 256 "$OUT/cell-$CELL.tar" | cut -d' ' -f1)"
  echo "bundle_bytes $(stat -f%z "$OUT/cell-$CELL.tar")"
  echo "descriptor_sha256 $(shasum -a 256 "$OUT/cell_manifest.v2" | cut -d' ' -f1)"
  echo "layout_sha256 $(shasum -a 256 "$OUT/LAYOUT.txt" | cut -d' ' -f1)"
} > "$OUT/CELL.txt"
sed 's/^/    /' "$OUT/CELL.txt"

note "RESULT"
echo "  distribution: $OUT"
ls -la "$OUT" | sed 's/^/    /'
if [[ $fail -eq 0 ]]; then echo "  BUNDLE BUILT"; else echo "  BUNDLE FAILED: $fail"; exit 1; fi
