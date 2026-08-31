#!/usr/bin/env bash
# cspell:words dartaotruntime dynmod
#
# run_hygiene.sh -- D0.1. Drive the SHIPPING producer over each `self` hygiene
# control and record the precommitted verdict.
#
# Runs `RouteBCoverageAnalyzer` + `RouteBProducer` -- the code `shorebird patch`
# runs -- via producer/cli_produce.dart, not a reimplementation of the edit.
#
# For each case:
#   1  compile base/patched/import kernels exactly as host_equivalence.sh does
#   2  run the CLI producer; record ACCEPT or REFUSE and the refusal text
#   3  preserve the emitted `replacement_0.dart`
#   4  where a replacement was emitted, HOST-EXECUTE it against the same
#      receiver the source would have used, and compare with the ground truth
#      taken from running patched.dart directly
#
# Step 4 is what separates UNSAFE from LOUD: a replacement that fails to compile
# names itself, and a replacement that compiles but answers differently from the
# source it stands in for is the silent defect.
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../../../.." >/dev/null 2>&1 && pwd)"
WORK=${WORK:-$(mktemp -d)}

DART=$OUT/dart-sdk/bin/dart
CLI_PKGS="${CLI_PKGS:-$REPO/.dart_tool/package_config.json}"
GEN_KERNEL=$OUT/zip_archives/route_b_gen_kernel.aot
RUNTIME=$OUT/dartaotruntime
BUILD_ID=${BUILD_ID:-deadbeefcafe}
CELL_ZIP=${CELL_ZIP:-$REPO/selfhost/cdn/overlay/download.shorebird.dev/shorebird/591a9f8d8e21f8c08cd379ac4c63a0300ac98959/route-b-compiler-darwin-arm64.zip}

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }

[ -x "$DART" ] || die "no host dart at $DART"
[ -f "$CELL_ZIP" ] || die "no compiler cell at $CELL_ZIP"
[ -f "$CLI_PKGS" ] || die "no package config at $CLI_PKGS"

CASES=("$@")
if [ ${#CASES[@]} -eq 0 ]; then
  while IFS= read -r d; do CASES+=("$(basename "$d")"); done \
    < <(find "$HERE" -mindepth 1 -maxdepth 1 -type d | sort)
fi

echo "work dir: $WORK"
for case_name in "${CASES[@]}"; do
  CASE_SRC="$HERE/$case_name"
  [ -f "$CASE_SRC/patched.dart" ] || die "no such case: $case_name"
  W="$WORK/$case_name"; mkdir -p "$W/lib" "$W/.dart_tool"
  cat > "$W/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "corpus", "rootUri": "file://$W/", "packageUri": "lib/",
    "languageVersion": "3.9" } ] }
JSON

  kernel() { ( cd "$W" && "$RUNTIME" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
      "${@:2}" --packages .dart_tool/package_config.json \
      -o "$1" package:corpus/main.dart >/dev/null 2>&1 ); }

  note "$case_name"

  # GROUND TRUTH, from the unmodified patched source. This is what the
  # replacement is supposed to be equivalent to.
  truth=$("$DART" run "$CASE_SRC/patched.dart" 2>&1) || truth="<source did not run>"
  echo "  source truth : $truth"

  cp "$CASE_SRC/base.dart" "$W/lib/main.dart"
  kernel "$W/base.dill" --aot        || die "$case_name: base kernel failed"
  kernel "$W/import.dill" --no-aot --no-link-platform \
                                     || die "$case_name: import kernel failed"
  cp "$CASE_SRC/patched.dart" "$W/lib/main.dart"
  kernel "$W/patched.dill" --aot     || die "$case_name: patched kernel failed"

  set +e
  "$DART" --packages="$CLI_PKGS" "$REPO/selfhost/engine/route_b/producer/cli_produce.dart" \
    "$CELL_ZIP" "$W/base.dill" "$W/patched.dill" "$W/import.dill" \
    "$BUILD_ID" "$W/out" "$W" > "$W/produce.log" 2>&1
  rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    echo "  producer     : REFUSED (exit $rc)"
    grep -iE "unsupported|refus|reject|cannot|takes |reads |calls |assigns" "$W/produce.log" \
      | head -6 | sed 's/^/                 /'
  else
    echo "  producer     : ACCEPTED"
  fi
  repl=$(find "$W/out" -name 'replacement_*.dart' 2>/dev/null | head -1)
  if [ -n "$repl" ]; then
    echo "  replacement  : $repl"
    sed 's/^/                 /' "$repl"
  else
    echo "  replacement  : none emitted"
  fi
  cp -f "$W/produce.log" "$W/produce.log.kept" 2>/dev/null || true
done

echo
echo "work dir kept: $WORK"
