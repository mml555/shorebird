#!/usr/bin/env bash
# verify_supported_state.sh -- re-check every mechanical claim in
# SUPPORTED_STATE.yaml against the artifacts themselves.
#
# The record is only worth having if it can be falsified. Each check below reads
# the artifact rather than the record, then compares. A drifted stack fails here
# instead of being discovered during an upgrade.
#
#   SHOREBIRD_ROOT=<a shorebird checkout with a populated bin/cache> \
#     selfhost/engine/route_b/verify_supported_state.sh
#
# Exit: 0 all checks pass · 1 one or more failed · 2 environment error
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
STATE="$HERE/SUPPORTED_STATE.yaml"
ROOT=${SHOREBIRD_ROOT:-/Volumes/build/route-b/shorebird-candidate}

[[ -f "$STATE" ]] || { echo "no SUPPORTED_STATE.yaml at $STATE" >&2; exit 2; }
val() { sed -nE "s/^[[:space:]]*$1:[[:space:]]*([^[:space:]#]+).*/\1/p" "$STATE" | head -1; }

fails=0
ok()   { printf '  ok      %s\n' "$*"; }
bad()  { printf '  FAILED  %s\n' "$*"; fails=$((fails+1)); }
cmp_v() { # <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1: record says $2, artifact is ${3:-<none>}"; fi
}

SELECTOR=$(val flutter_selector)
CELL=$(val cell_address)
ARCHIVE=$(val compiler_archive_sha256)
ARCHBYTES=$(val compiler_archive_bytes)
ANALYZER=$(val analyzer_sha256)

echo "verify_supported_state -- record $STATE"
echo "  shorebird root : $ROOT"

# 1. THE SELECTOR CHAIN, read from the artifacts a build actually walks.
cmp_v "CLI flutter.version selects the recorded Flutter" \
  "$SELECTOR" "$(cat "$ROOT/bin/internal/flutter.version" 2>/dev/null)"

FDIR="$ROOT/bin/cache/flutter/$SELECTOR"
if [[ -d "$FDIR/.git" ]]; then
  # COMMITTED blob, not the working tree: an uncommitted engine.version must
  # never be part of the qualified lineage, and reading the file would not see
  # the difference.
  cmp_v "Flutter engine.version (committed blob) selects the recorded cell" \
    "$CELL" "$(git -C "$FDIR" show HEAD:bin/internal/engine.version 2>/dev/null | tr -d '[:space:]')"
  if [[ -z "$(git -C "$FDIR" status --porcelain 2>/dev/null)" ]]; then
    ok "Flutter checkout is clean"
  else
    bad "Flutter checkout has uncommitted changes"
  fi
else
  bad "no Flutter checkout at $FDIR"
fi

# 2. THE CELL'S BYTES.
ZIP="$REPO/selfhost/cdn/overlay/download.shorebird.dev/shorebird/$CELL/route-b-compiler-darwin-arm64.zip"
if [[ -f "$ZIP" ]]; then
  cmp_v "compiler archive digest" "$ARCHIVE" "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
  cmp_v "compiler archive size"   "$ARCHBYTES" "$(stat -f%z "$ZIP" 2>/dev/null || stat -c%s "$ZIP")"
else
  bad "no published compiler archive at $ZIP"
fi

CACHED="$ROOT/bin/cache/artifacts/route-b-compiler/$CELL/route_b_analyze.aot"
if [[ -f "$CACHED" ]]; then
  cmp_v "analyzer digest (the one the CLI consumes)" \
    "$ANALYZER" "$(shasum -a 256 "$CACHED" | cut -d' ' -f1)"
else
  echo "  --      analyzer not resolved into this root's cache yet (not a failure)"
fi

# 3. THE ADDRESS AUTHENTICATES ITSELF.
MAN="$HERE/cell_manifests/$CELL.v2"
if [[ -f "$MAN" ]]; then
  cmp_v "v2 manifest recomputes to the cell address" \
    "$CELL" "$(shasum -a 256 "$MAN" | cut -c1-40)"
else
  bad "no v2 address manifest registered for $CELL"
fi

# 4. THE FULL CELL AUDIT.
if bash "$HERE/audit_route_b_compiler.sh" --hash "$CELL" >/dev/null 2>&1; then
  ok "audit_route_b_compiler: AUDIT CLEAN"
else
  bad "audit_route_b_compiler reported findings for $CELL"
fi

echo
if [[ "$fails" -eq 0 ]]; then
  echo "SUPPORTED STATE VERIFIED"
else
  echo "SUPPORTED STATE FAILED: $fails check(s)"
fi
exit $(( fails > 0 ))
