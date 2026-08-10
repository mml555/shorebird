#!/usr/bin/env bash
# cspell:words killgate dynmod dartaotruntime
#
# run_all.sh -- Route B step 6: every host check, one command, one verdict.
#
# WHY THIS EXISTS. By the end of step 5 the checks were spread across five
# scripts in three directories, each with its own invocation and its own way of
# saying "passed". That is how a suite quietly stops being run: not by anyone
# deciding to skip it, but by nobody remembering the fifth one.
#
# It also enforces the pairing that makes step 1's result mean anything. The
# kill gate is run TWICE -- with the patchable call form and without -- because
# either run alone is consistent with the flag doing nothing. Reporting only the
# passing arm would be the single easiest way to fool ourselves here.
#
# Usage:
#   selfhost/engine/route_b/run_all.sh            # everything
#   selfhost/engine/route_b/run_all.sh --quick    # skip the slow retention sweep
set -uo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../../.." >/dev/null 2>&1 && pwd)"
QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

export SRC OUT

die() { echo "ERROR: $*" >&2; exit 1; }
[ -d "$OUT" ] || die "no build at $OUT — run build_host.sh first"
grep -q 'dart_dynamic_modules = true' "$OUT/args.gn" 2>/dev/null \
  || die "dart_dynamic_modules is not true in $OUT/args.gn"

# Guard the tree before trusting any result: a green suite on a tree missing a
# patch is worse than a red one, because it is believed.
"$REPO/selfhost/engine/dart_patches.sh" --dest "$SRC/flutter/third_party/dart" \
  --verify >/dev/null || die "dart_patches.sh --verify is not green"
grep -q 'patchable_static_calls' \
  "$SRC/flutter/third_party/dart/runtime/vm/compiler/backend/flow_graph_compiler_arm64.cc" \
  || die "the Route B step 1 patch is not in this tree"

names=(); verdicts=()
record() { names+=("$1"); verdicts+=("$2"); }

run() { # run <label> <expected-ERE> <command...>
  # An extended regex, not a fixed string: these scripts align their output in
  # columns, so a fixed-string match encodes the current column widths and
  # breaks when a label gets longer. That is a false failure, which costs more
  # trust than it saves.
  local label="$1" expect="$2"; shift 2
  printf '  %-38s ' "$label"
  local log; log="$(mktemp)"
  if "$@" >"$log" 2>&1 && grep -qE "$expect" "$log"; then
    echo "ok"; record "$label" ok
  else
    echo "FAILED"; record "$label" FAILED
    echo "    --- last 12 lines ---"
    tail -12 "$log" | sed 's/^/    /'
  fi
  rm -f "$log"
}

echo "Route B host suite"
echo "  tree: $SRC"
echo

echo "step 1 — patchable call emission"
# BOTH arms. The control is not a formality: without it, "the gate passes" is
# equally consistent with the flag being ignored entirely.
GEN_SNAPSHOT_FLAGS=--patchable_static_calls \
  run "kill gate, flag ON" "GATE: PASS" "$REPO/selfhost/engine/killgate/run.sh"
GEN_SNAPSHOT_FLAGS='' \
  run "kill gate, flag OFF (control)" "GATE: BASELINE" "$REPO/selfhost/engine/killgate/run.sh"
run "call-form inventory" "dynamic-instance +PATCHABLE" \
  "$HERE/inventory/run_inventory.sh"

echo
echo "step 2 — symbol retention"
run "patch binds an SDK symbol" "RESULT: PASS" "$HERE/verify_binding.sh"
if [[ "$QUICK" -eq 0 ]]; then
  run "retention breadth sweep" "app + named SDK members" "$HERE/measure_retention.sh"
else
  echo "  retention breadth sweep                skipped (--quick)"
fi

echo
echo "step 3 — target identity"
run "retention subsumes the pragma" "ANSWER: retention SUBSUMES" \
  "$HERE/identity/probe_retention_lookup.sh"

echo
echo "step 4 — patch container"
run "container apply/revert/refusals" "step 4: 10 passed, 0 failed" \
  "$HERE/packaging/verify_container.sh"

echo
echo "step 5 — patch production"
run "edit -> container -> apply -> revert" "step 5: 8 passed, 0 failed" \
  "$HERE/packaging/verify_patch_flow.sh"

echo
echo "4b — engine-side container reader"
# The rejection taxonomy. kWrongRelease is absent on purpose: it needs a live
# isolate, so it is proven on device in the milestone-1 sequence.
run "container reader taxonomy" "TAXONOMY: all passed" \
  "$HERE/packaging/verify_container_reader.sh"

echo
echo "--------------------------------------------------"
failed=0
for i in "${!names[@]}"; do
  [[ "${verdicts[$i]}" == ok ]] || { echo "FAILED: ${names[$i]}"; failed=$((failed + 1)); }
done
total=${#names[@]}
echo "Route B host suite: $((total - failed))/$total ok"
echo
echo "NOT covered here, and neither is optional before this ships:"
echo "  * nothing in this suite runs on iOS — the engine port has not happened"
echo "  * step 7's real-app size and frame-time veto"
echo "  * step 8's physical-device gate, step 9's sealed regression"
[[ "$failed" -eq 0 ]] || exit 1
