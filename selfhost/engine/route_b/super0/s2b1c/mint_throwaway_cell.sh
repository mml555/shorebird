#!/usr/bin/env bash
#
# mint_throwaway_cell.sh -- a cell carrying this lane's patched artifacts, for
# host end-to-end runs only.
#
# NOT A PUBLISHED CELL and never to become one. It exists because the SHIPPING
# producer cannot otherwise be driven on the host: `resolveRouteBCompiler`
# verifies every file's SHA-256 against PROVENANCE.txt, so the stock cell cannot
# simply have a file swapped in.
#
# A CELL IS A COHERENT SET, not a bag of files. The first version of this script
# swapped only dart2bytecode.aot, and the producer died on "the coverage analyzer
# speaks version 9, and this build understands 10" — the cell still carried the
# v9 analyzer. Every artifact this lane changed travels together or the bundle is
# incoherent in a way that only shows up as a confusing error.
#
# The `engine revision` line is left UNCHANGED on purpose: the cell must still
# identify the engine it belongs to, and lying about that would defeat the check
# that caught a mismatched bundle earlier in this lane.
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../../../../.." >/dev/null 2>&1 && pwd)"
ENGINE_HASH="${ENGINE_HASH:-4792f0eca461f3761001a1adbe131b4b115e3684}"
STOCK="$REPO/selfhost/cdn/overlay/download.shorebird.dev/shorebird/$ENGINE_HASH/route-b-compiler-darwin-arm64.zip"
OUTZIP="${OUTZIP:?set OUTZIP}"
REPLACE="${REPLACE:?set REPLACE to name=path[,name=path...]}"

die() { echo "ERROR: $*" >&2; exit 1; }
[ -f "$STOCK" ] || die "no stock cell at $STOCK"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
unzip -q -o "$STOCK" -d "$W/cell"

echo "$REPLACE" | tr ',' '\n' | while IFS= read -r pair; do
  [ -n "$pair" ] || continue
  name="${pair%%=*}"; path="${pair#*=}"
  [ -f "$W/cell/$name" ] || die "$name is not in the stock cell"
  [ -f "$path" ] || die "no replacement file at $path"
  cp "$path" "$W/cell/$name"
done

python3 "$HERE/rewrite_provenance.py" "$W/cell" "$REPLACE"

mkdir -p "$(dirname "$OUTZIP")"; rm -f "$OUTZIP"
( cd "$W/cell" && zip -q -r "$OUTZIP" . )
echo "  throwaway cell: $OUTZIP"
echo "  engine revision line unchanged ($ENGINE_HASH)"
