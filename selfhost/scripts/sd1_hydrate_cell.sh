#!/usr/bin/env bash
# cspell:words armv
# SELFHOST-DISTRIBUTION-1 gate 3b: reconstruct a CDN overlay for a cell from the
# DURABLE DISTRIBUTION alone.
#
# Nothing here reads the qualification machine. The inputs are the distribution
# files and the recorded digests; the output is an overlay hierarchy a CDN can
# serve, verified member by member and then re-verified as an address.
#
#   sd1_hydrate_cell.sh --dist DIR --overlay DIR [--cell ADDR]
#
# --dist may be a downloaded directory or a URL base (curl-fetched into a temp
# directory first). Exit 0 only if 30/30 members verify AND the address
# recomputes.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../.." >/dev/null 2>&1 && pwd)"
CELL=${CELL:-f85251f344600ae08196925a174e9cff8f0ff18e}
DIST=""; DEST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dist) DIST="${2:?}"; shift 2 ;;
    --overlay) DEST="${2:?}"; shift 2 ;;
    --cell) CELL="${2:?}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$DIST" && -n "$DEST" ]] || { echo "usage: --dist DIR|URL --overlay DIR" >&2; exit 2; }
fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note(){ printf '\n\033[1m== %s\033[0m\n' "$1"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sd1hyd.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

note "1 - obtain the distribution"
if [[ "$DIST" == http* ]]; then
  mkdir -p "$WORK/dist"
  for f in "cell-$CELL.tar" cell_manifest.v2 LAYOUT.txt MANIFEST.sha256 CELL.txt; do
    curl -fsSL "$DIST/$f" -o "$WORK/dist/$f" || { bad "could not download $f"; }
  done
  DIST="$WORK/dist"
fi
for f in "cell-$CELL.tar" cell_manifest.v2 LAYOUT.txt; do
  [[ -f "$DIST/$f" ]] || bad "the distribution is missing $f"
done
[[ $fail -eq 0 ]] || { echo; echo "  HYDRATION FAILED: the distribution is incomplete"; exit 1; }
ok "the distribution carries the bundle, the descriptor and the layout"

note "2 - the distribution's own checksums"
if [[ -f "$DIST/MANIFEST.sha256" ]]; then
  if ( cd "$DIST" && shasum -a 256 -c MANIFEST.sha256 >/dev/null 2>&1 ); then
    ok "MANIFEST.sha256 verifies every distribution file"
  else
    bad "a distribution file does not match MANIFEST.sha256"
    ( cd "$DIST" && shasum -a 256 -c MANIFEST.sha256 2>&1 | grep -v OK$ | sed 's/^/      /' )
  fi
else
  bad "no MANIFEST.sha256 in the distribution"
fi

note "3 - the descriptor authenticates its own name"
RE=$(shasum -a 256 "$DIST/cell_manifest.v2" | cut -c1-40)
[[ "$RE" == "$CELL" ]] && ok "descriptor recomputes to $CELL" \
                       || bad "descriptor recomputes to $RE, not $CELL"

note "4 - extract into the overlay hierarchy"
mkdir -p "$DEST"
tar -xf "$DIST/cell-$CELL.tar" -C "$DEST" || bad "extraction failed"
got=$(cd "$DEST" && find . -type f -path "*$CELL*" | wc -l | tr -d ' ')
echo "    files placed under the overlay: $got"

note "5 - every member matches its RAW digest from LAYOUT.txt"
n=0; good=0
while read -r rel want bytes; do
  [[ "$rel" == \#* || -z "$rel" ]] && continue
  n=$((n+1))
  f="$DEST/$rel"
  if [[ ! -f "$f" ]]; then bad "MISSING after extraction: $rel"; continue; fi
  h=$(shasum -a 256 "$f" | cut -d' ' -f1)
  sz=$(stat -f%z "$f")
  if [[ "$h" == "$want" && "$sz" == "$bytes" ]]; then good=$((good+1))
  else bad "BYTES DIFFER: $rel"; fi
done < "$DIST/LAYOUT.txt"
[[ "$good" == "$n" && "$n" -gt 0 ]] && ok "$good of $n members match their recorded bytes exactly" \
                                    || bad "$good of $n members match"

note "6 - and the ADDRESS recomputes from what was placed"
# The authority, not the layout file: the product's own verifier, against the
# reconstructed overlay. This is what proves the hydrated tree IS the cell.
# The descriptor comes from the DISTRIBUTION, not from this repository's
# registry -- otherwise the check would be reading an authority the consumer
# does not have.
mkdir -p "$WORK/manifests"
cp "$DIST/cell_manifest.v2" "$WORK/manifests/$CELL.v2"
out=$(CELL_MANIFESTS="$WORK/manifests" bash "$REPO/selfhost/engine/route_b/verify_cell_members.sh" \
        "$CELL" --overlay "$DEST" 2>&1)
echo "$out" | sed 's/^/    /'
echo "$out" | grep -q "CELL MEMBERS VERIFIED ($n/$n)" && ok "verify_cell_members: $n/$n against the hydrated overlay" \
                                                      || bad "verify_cell_members did not report $n/$n"

note "RESULT"
echo "  overlay: $DEST"
if [[ $fail -eq 0 ]]; then echo "  CELL HYDRATED FROM THE DURABLE DISTRIBUTION"; else
  echo "  HYDRATION FAILED: $fail"; exit 1; fi
