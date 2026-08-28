#!/usr/bin/env bash
# cspell:words dartaotruntime rbtrace
#
# verify_frozen_surfaces.sh -- refuse to proceed if anything the disappearance
# investigation is forbidden to touch has moved.
#
# WHY A SCRIPT AND NOT A RULE IN A DOCUMENT. The investigation's whole risk is
# that a plausible "fix" quietly moves a lifecycle boundary, which would end
# Epoch B and recreate the comparability problem the two-epoch split exists to
# avoid. A written rule cannot detect that; a byte comparison can.
#
# WHAT IS FROZEN, and it is deliberately broader than "the files I plan to edit":
#   * the SHIPPING updater's lifecycle + event surface (engine tree's
#     third_party/updater, NOT vendor/updater -- UPDATER_CONTRACT.md explains why
#     they are different trees and which one runs on device);
#   * the engine C++ boot path that selects and attributes a patch;
#   * the vendored mirror of the same lifecycle files, so the two cannot drift;
#   * the policy surface carrying PolicyEpoch.
#
# Baselines are BYTES, recorded in FROZEN_BASELINE.txt at the Epoch B activation
# commit. Not mtimes, not git status: this project has already measured a case
# where every identity-looking surface agreed while the bytes did not.
#
#   verify_frozen_surfaces.sh [--baseline <file>]
#
# Exit: 0 all frozen surfaces intact · 1 something moved · 2 usage/environment.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASELINE=${BASELINE:-$HERE/FROZEN_BASELINE.txt}
ENGINE=${ENGINE:-/Volumes/build/route-b/flutter/engine/src/flutter}
VENDOR=${VENDOR:-$HERE/../../vendor/updater}
REPO=${REPO:-$HERE/../..}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline) BASELINE="${2:?}"; shift 2 ;;
    -h|--help) sed -n '3,28p' "${BASH_SOURCE[0]}"; exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -r "$BASELINE" ]] || { echo "FAIL: no baseline at $BASELINE" >&2; exit 2; }

fail=0
ok()  { printf '  ok       %s\n' "$1"; }
bad() { printf '  MOVED    %s\n' "$1"; fail=1; }
und() { printf '  UNKNOWN  %s\n' "$1"; fail=1; }

echo "frozen-surface check"
echo "  baseline : $BASELINE"

while read -r kind path want; do
  case "$kind" in
    engine_updater) full="$ENGINE/third_party/updater/$path" ;;
    engine_cxx)     full="$ENGINE/$path" ;;
    vendor_updater) full="$VENDOR/$path" ;;
    policy)         full="$REPO/$path" ;;
    *) continue ;;
  esac
  if [[ ! -f "$full" ]]; then
    # ABSENT IS NOT UNCHANGED. A missing frozen file is a bigger problem than a
    # modified one, and must never read as a pass.
    und "$kind $path -- file is MISSING at $full"
    continue
  fi
  got=$(shasum -a 256 "$full" | cut -d' ' -f1)
  if [[ "$got" == "$want" ]]; then
    ok "$kind $path (${got:0:16})"
  else
    bad "$kind $path -- baseline ${want:0:16}, now ${got:0:16}"
  fi
done < <(grep -E '^(engine_updater|engine_cxx|vendor_updater|policy) ' "$BASELINE")

# The certified identities recorded alongside the hashes must also still hold.
cell_want=$(awk '/^certified_cell /{print $2}' "$BASELINE")
cell_got=$(tr -d '[:space:]' < "$HOME/.shorebird/bin/cache/flutter/$(tr -d '[:space:]' < "$HOME/.shorebird/bin/internal/flutter.version")/bin/internal/engine.version" 2>/dev/null || echo unreadable)
if [[ "$cell_got" == "$cell_want" ]]; then
  ok "active cell is the certified one (${cell_want:0:16})"
else
  bad "active cell is $cell_got, certified is $cell_want"
fi

echo
if [[ "$fail" -eq 0 ]]; then
  echo "FROZEN SURFACES INTACT — the investigation may proceed"
  exit 0
fi
cat <<'MSG'
FROZEN SURFACES HAVE MOVED — STOP

The disappearance investigation is observation-only. If a change here was
intentional, it is not part of this lane: moving a lifecycle boundary closes
Epoch B and opens Epoch C, which is a decision, not a refactor. See
selfhost/NEXT_LANES.md and selfhost/MEASUREMENT_MODE.md.
MSG
exit 1
