#!/usr/bin/env bash
# MAOT-2 (#66) -- runtime implementation registry.
#
# One invocation produces both the transcript and the JSON: a caller-redirected
# transcript drifts from the record it claims to describe, so the tee happens
# inside this script rather than at the call site.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVIDENCE="$HERE/evidence"
mkdir -p "$EVIDENCE"

# bash expands {'a','b'} inside $( ) and splits one Python expression into
# several words; zsh does not. This lane has been bitten by exactly that, so
# it is a hard error rather than a comment.
if grep -nE "\\\$\(.*\{'[^']*',[^)]*\}" "$HERE"/lib/*.py "$0" 2>/dev/null; then
  echo "FATAL: brace-expansion hazard inside a command substitution" >&2
  exit 3
fi

exec > >(tee "$EVIDENCE/m2_transcript.txt") 2>&1
echo "=== MAOT-2 (#66) runtime implementation registry ==="
date -u +"run  %Y-%m-%dT%H:%M:%SZ"
echo "fork $(git -C "${MAOT_FORK:-/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart}" rev-parse HEAD 2>/dev/null || echo unavailable)"
echo
set +e
python3 "$HERE/lib/gate_m2.py" "$HERE" "$EVIDENCE/m2_evidence.json"
rc=$?
set -e
echo
echo "gate exit $rc"
exit $rc
