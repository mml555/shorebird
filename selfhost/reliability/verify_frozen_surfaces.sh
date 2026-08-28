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

# ---------------------------------------------------------------------------
# THE RUNTIME MUST BE VERIFIED BY BYTES, NOT BY ITS STAMP.
#
# This block replaced a check that read `bin/internal/engine.version` and
# declared "active cell is the certified one". That proved only what the stamp
# SAYS -- and the exact counterexample is already measured in this project:
#
#     engine.version         4792f0ec
#     engine.stamp           4792f0ec
#     engine-dart-sdk.stamp  4792f0ec
#     cached ios-release engine   ca7d2c0d's, a week old
#     verdict                COHERENT
#
# An evidence harness whose whole purpose is "prove we reproduced against the
# frozen certified runtime" cannot finish on the assumption that already failed.
#
# REUSES verify_toolchain_coherence.sh rather than inventing a second, weaker
# comparison: its check 3b extracts each iOS mode's engine from THAT cell's own
# published artifacts.zip and compares byte for byte. One implementation, one
# place to fix.
#
# WITH ONE DELIBERATE DIFFERENCE. That script is a diagnostic and may report a
# not-yet-cached engine as fine. An evidence gate must refuse: at capture time an
# absent engine means identity was NOT ESTABLISHED, and absence is not a match.
# So existence is asserted here as well.
cell_want=$(awk '/^certified_cell /{print $2}' "$BASELINE")
FLUTTER_ROOT_GUESS="$HOME/.shorebird/bin/cache/flutter/$(tr -d '[:space:]' < "$HOME/.shorebird/bin/internal/flutter.version" 2>/dev/null)"

for mode in ios ios-profile ios-release; do
  cached="$FLUTTER_ROOT_GUESS/bin/cache/artifacts/engine/$mode/Flutter.xcframework/ios-arm64/Flutter.framework/Flutter"
  if [[ ! -f "$cached" ]]; then
    und "cached $mode engine is MISSING -- identity not established, and absent is not a match"
  fi
  pub="$REPO/selfhost/cdn/overlay/flutter_infra_release/flutter/$cell_want/$mode/artifacts.zip"
  if [[ ! -f "$pub" ]]; then
    und "published reference for $mode is MISSING at $pub -- nothing to compare against"
  fi
done

coh=$(PLATFORM=ios bash "$REPO/selfhost/scripts/verify_toolchain_coherence.sh" 2>&1)
coh_rc=$?
if [[ "$coh_rc" -eq 0 ]] && printf '%s' "$coh" | grep -q 'COHERENT: 0 failure'; then
  # Surface the per-mode byte verdicts, so a run's evidence records the digests
  # rather than a bare "it passed".
  printf '%s' "$coh" | grep -E 'cached engine IS this cell' | sed 's/^ *OK */  ok       /'
  ok "engine byte identity VERIFIED against published cell ${cell_want:0:16}"
else
  printf '%s' "$coh" | grep -E 'FAIL|cached engine is NOT' | sed 's/^ */  /'
  bad "engine byte identity NOT VERIFIED -- see the coherence output above"
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
