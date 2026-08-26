#!/usr/bin/env bash
# cspell:words dynmod prebuilt xcframework
#
# qualify_ios_modes_gate.sh -- the state transition between "ninja finished" and
# "these artifacts may be minted".
#
#   ALL DONE
#       ↓
#   debug qualification PASS
#       ↓
#   profile qualification PASS
#       ↓
#   deterministic packaging PASS
#       ↓
#   eligible to mint
#
# WHY THIS IS A SCRIPT AND NOT A HABIT. "ALL DONE" means the build PROCESS
# completed. It does not mean the artifacts are qualified, and the two are easy
# to conflate at the end of a long build when the log looks finished. Every
# other conflation of that shape in this project has cost a wrong conclusion, so
# the transition is machine-enforced: if either mode fails qualification this
# refuses, EVEN IF ninja exited zero.
#
#   qualify_ios_modes_gate.sh [--log <build log>]
#
# Exit codes: 0 eligible to mint · 1 not eligible · 2 usage/environment.
set -uo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LOG=${LOG:-$(ls -t /Volumes/build/route-b/logs/ios_modes_*.log 2>/dev/null | head -1)}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log) LOG="${2:?}"; shift 2 ;;
    -h|--help) sed -n '3,24p' "${BASH_SOURCE[0]}"; exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "${LOG:-}" && -f "$LOG" ]] || { echo "no build log found" >&2; exit 2; }

fail=0
step() { echo; echo "==> $*"; }
bad()  { echo "  REFUSE  $*"; fail=1; }
ok()   { echo "  ok      $*"; }

echo "iOS mode qualification gate"
echo "  log : $LOG"

# ---- 1 · the build PROCESS completed ---------------------------------------
step "1 · did the build process complete?"
if grep -q "ALL DONE" "$LOG"; then
  ok "log reports ALL DONE"
else
  bad "log does not report ALL DONE — the build is still running or died"
  echo; echo "NOT ELIGIBLE — nothing further was checked."; exit 1
fi

# AND every ninja exited zero. `ALL DONE` is printed unconditionally by the
# build script's outer block, so it survives a failed ninja -- which is exactly
# the conflation this gate exists to break.
nonzero=$(grep -oE "ninja exit=[0-9]+" "$LOG" | grep -v "exit=0" | head -3)
count=$(grep -c "ninja exit=" "$LOG")
if [[ -n "$nonzero" ]]; then
  bad "a ninja invocation exited non-zero: $(echo "$nonzero" | tr '\n' ' ')"
elif [[ "$count" -lt 2 ]]; then
  bad "only $count ninja invocation(s) recorded; expected one per mode"
else
  ok "$count ninja invocations, all exit=0"
fi

# ---- 2 · each mode qualifies ON ITS OWN ------------------------------------
# Delegated to package_ios_mode_artifacts.sh --dry-run, so the gate and the
# packager cannot disagree about what qualification means.
declare -a DIGEST
i=0
for mode in debug profile; do
  step "2.$((++i)) · qualify out/ios_$mode independently"
  out=$(bash "$HERE/package_ios_mode_artifacts.sh" --mode "$mode" \
          --hash qualification-only --dry-run 2>&1)
  rc=$?
  echo "$out" | sed -n '/qualifying/,$p' | sed 's/^/      /'
  if [[ "$rc" -ne 0 ]]; then
    bad "$mode did NOT qualify — stopping here even though ninja exited zero"
  else
    d=$(echo "$out" | grep -oE "REPRODUCIBLE  [0-9a-f]{32}" | awk '{print $2}')
    DIGEST[$i]="$d"
    ok "$mode qualified, archive ${d:0:16} and REPRODUCIBLE"
  fi
done

# ---- 3 · the verdict -------------------------------------------------------
echo
if [[ "$fail" -eq 0 ]]; then
  echo "ELIGIBLE TO MINT"
  echo "  ios/artifacts.zip          ${DIGEST[1]}"
  echo "  ios-profile/artifacts.zip  ${DIGEST[2]}"
  echo
  echo "Next: package for real under the successor hash, extend the manifest"
  echo "with both digests, and mint. Do not touch the rig before the empty-cache"
  echo "9/9 proof."
  exit 0
fi
echo "NOT ELIGIBLE TO MINT"
echo
echo "A completed build is not a qualified artifact set. Fix the refusal above;"
echo "do not proceed to minting on the strength of ninja's exit code."
exit 1
