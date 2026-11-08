#!/usr/bin/env bash
# MAOT-4 (#68) -- optimizer invariants for mutable declarations.
#
# One invocation produces both the transcript and the JSON: a caller-redirected
# transcript drifts from the record it describes.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVIDENCE="$HERE/evidence"
mkdir -p "$EVIDENCE"

if grep -nE "\\\$\(.*\{'[^']*',[^)]*\}" "$HERE"/lib/*.py "$0" 2>/dev/null; then
  echo "FATAL: brace-expansion hazard inside a command substitution" >&2
  exit 3
fi

exec > >(tee "$EVIDENCE/m4_transcript.txt") 2>&1
echo "=== MAOT-4 (#68) optimizer invariants for mutable declarations ==="
date -u +"run  %Y-%m-%dT%H:%M:%SZ"
echo "fork $(git -C "${MAOT_FORK:-/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart}" rev-parse HEAD 2>/dev/null || echo unavailable)"
echo
set +e
python3 "$HERE/lib/gate_m4.py" "$HERE" "$EVIDENCE/m4_evidence.json"
rc=$?
set -e
echo
echo "gate exit $rc"
exit $rc
