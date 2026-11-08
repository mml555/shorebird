#!/usr/bin/env bash
# cspell:words dartaotruntime dynmod devirtualizes pathlib
#
# parity.sh -- Route B step 3 acceptance: the ported coverage analysis must
# agree with the reference tooling on every field, for every case.
#
# THREE IMPLEMENTATIONS, ONE KERNEL PAIR:
#
#   reference   identity/gen_target_manifest.dart + packaging/build_patch.dart,
#               run exactly as they are today and NOT modified for this harness
#   analyzer    coverage/analyze_coverage.dart, the transcription that ships in
#               the compiler cell
#   cli         shorebird_cli's RouteBCoverage parser, via cli_verdict.dart
#
# Compared: changed target set, target identity, representable set, conditional
# set, rejected set, THE EXACT REJECTION REASON FOR EACH, and the whole-patch
# verdict. Any mismatch fails the case, including when all three ultimately
# reject -- rejecting for the wrong reason sends someone to debug the wrong
# half, which is the failure this whole chain exists to prevent.
#
# The reference tools stay untouched on purpose. If the analyzer imported their
# code the harness would prove nothing: transcription error IS the risk.
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
RB="$(cd "$HERE/.." >/dev/null 2>&1 && pwd)"
REPO="$(cd "$RB/../../.." >/dev/null 2>&1 && pwd)"
WORK="${WORK:-$(mktemp -d)}"

DART_TREE="$SRC/flutter/third_party/dart"
DART="$OUT/dart-sdk/bin/dart"
KERNEL_PKGS="--packages=$DART_TREE/.dart_tool/package_config.json"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
AOT_RUNTIME="$OUT/dartaotruntime"
ANALYZER="${ANALYZER:-$OUT/zip_archives/route_b_analyze.aot}"
# The repo is a pub workspace, so the resolved config is at its root, not in
# the package dir.
CLI_PKGS="${CLI_PKGS:-$REPO/.dart_tool/package_config.json}"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }

[ -x "$DART" ] || die "no host dart at $DART"
[ -f "$ANALYZER" ] || die "no analyzer at $ANALYZER — run build_route_b_analyzer.sh"
[ -f "$CLI_PKGS" ] || die "no package config at $CLI_PKGS; run dart pub get at the repo root"

CASES=("$@")
if [ ${#CASES[@]} -eq 0 ]; then
  while IFS= read -r d; do CASES+=("$(basename "$d")"); done \
    < <(find "$HERE/corpus" -mindepth 1 -maxdepth 1 -type d | sort)
fi

pass=0; fail=0; failed_cases=()

for case_name in "${CASES[@]}"; do
  CASE_SRC="$HERE/corpus/$case_name"
  [ -d "$CASE_SRC" ] || die "no such case: $case_name"
  W="$WORK/$case_name"
  mkdir -p "$W/lib" "$W/.dart_tool"

  # One package name for both sides so the library URI -- and therefore every
  # target key -- is identical. Keys that differ only by a temp path would make
  # every case a mismatch.
  cat > "$W/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "corpus", "rootUri": "file://$W/", "packageUri": "lib/",
    "languageVersion": "3.9" } ] }
JSON

  # --aot, matching the real pipeline. It matters: TFA tree-shakes, and the
  # added-member case is only meaningful once something references the addition.
  build_dill() { # <src> <out>
    cp "$1" "$W/lib/main.dart"
    ( cd "$W" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
        --packages .dart_tool/package_config.json \
        -o "$2" package:corpus/main.dart >/dev/null 2>&1 )
  }

  note "$case_name"
  build_dill "$CASE_SRC/base.dart"    "$W/base.dill"    || die "$case_name: base kernel failed"
  build_dill "$CASE_SRC/patched.dart" "$W/patched.dill" || die "$case_name: patched kernel failed"

  # ---- reference -------------------------------------------------------
  "$DART" $KERNEL_PKGS "$RB/identity/gen_target_manifest.dart" \
    --dill "$W/base.dill" --out "$W/ref_targets.json" 2>/dev/null
  set +e
  "$DART" $KERNEL_PKGS "$RB/packaging/build_patch.dart" \
    --base-dill "$W/base.dill" --patched-dill "$W/patched.dill" \
    --manifest "$W/ref_targets.json" --out "$W/ref_changed.json" \
    > "$W/ref.log" 2>&1
  ref_rc=$?
  set -e

  # ---- analyzer (the artifact that ships in the cell) ------------------
  "$AOT_RUNTIME" "$ANALYZER" --base-dill "$W/base.dill" \
    --patched-dill "$W/patched.dill" --out "$W/analysis.json"

  # ---- cli parser ------------------------------------------------------
  set +e
  "$DART" --packages="$CLI_PKGS" "$HERE/cli_verdict.dart" "$W/analysis.json" \
    > "$W/cli.json" 2> "$W/cli.err"
  cli_rc=$?
  set -e
  if [ "$cli_rc" -ne 0 ]; then
    echo "  FAIL  the CLI parser rejected the analysis"
    sed 's/^/        /' "$W/cli.err"
    fail=$((fail+1)); failed_cases+=("$case_name"); continue
  fi

  # ---- compare ---------------------------------------------------------
  # The pin is optional so a new case can be written, run, and inspected before
  # its expectations are committed. A case without one still gets full
  # three-way parity; it just cannot catch all three drifting together.
  pin=("")
  if [ -f "$CASE_SRC/expected.json" ]; then
    pin=(--expected "$CASE_SRC/expected.json")
  else
    pin=()
  fi
  if python3 "$HERE/compare.py" \
      --case "$case_name" \
      --ref-changed "$W/ref_changed.json" \
      --ref-targets "$W/ref_targets.json" \
      --ref-rc "$ref_rc" \
      --analysis "$W/analysis.json" \
      --cli "$W/cli.json" \
      ${pin[@]+"${pin[@]}"}; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); failed_cases+=("$case_name")
  fi
done

echo
echo "--------------------------------------------------"
echo "coverage parity: $pass passed, $fail failed"
echo "work dir kept: $WORK"
if [ "$fail" -ne 0 ]; then
  echo "failed: ${failed_cases[*]}"
  exit 1
fi
