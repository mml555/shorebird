#!/usr/bin/env bash
# cspell:words dartaotruntime dynmod wonderous wonders airgap TFA
#
# run_census.sh -- D0.2. Compile each corpus the way a RELEASE is compiled, then
# ask the shipping lowering contract about every instance method in it.
#
# THE KERNEL IS BUILT `--aot --tfa`, deliberately. That is the dill the analyzer
# reads in production, so it is the one whose bodies the contract actually sees.
# A non-AOT kernel would contain methods a release does not ship and bodies TFA
# has not touched, and would answer a question nobody asks.
#
# Each corpus is measured and reported SEPARATELY. They are not comparable and
# must never be pooled: one is a synthetic regression fixture written to exercise
# this mechanism, the other is an app written by people who had never heard of it.
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../../../.." >/dev/null 2>&1 && pwd)"
WORK=${WORK:-$(mktemp -d)}

DART_TREE=$SRC/flutter/third_party/dart
DART=$OUT/dart-sdk/bin/dart
GEN_KERNEL=$DART_TREE/pkg/vm/bin/gen_kernel.dart
KERNEL_PKGS="--packages=$DART_TREE/.dart_tool/package_config.json"
PLATFORM=$OUT/flutter_patched_sdk/platform_strong.dill
AOT_RUNTIME=$OUT/dartaotruntime
ANALYZER=${ANALYZER:-$OUT/zip_archives/route_b_analyze.aot}

AIRGAP=${AIRGAP:-$REPO/selfhost/fixtures/airgap_app}
WONDEROUS=${WONDEROUS:-/Volumes/build/route-b/wonderous}

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }

[ -x "$DART" ]        || die "no host dart at $DART"
[ -f "$PLATFORM" ]    || die "no Flutter platform dill at $PLATFORM"
[ -f "$ANALYZER" ]    || die "no analyzer at $ANALYZER — run build_route_b_analyzer.sh"
mkdir -p "$WORK"

# corpus <name> <app dir> <entry uri> <include prefix>
corpus() {
  local name=$1 app=$2 entry=$3 prefix=$4
  [ -d "$app" ] || die "$name: no app at $app"
  [ -f "$app/.dart_tool/package_config.json" ] \
    || die "$name: no package_config; run flutter pub get in $app"

  note "$name: kernel (--aot --tfa, as a release is)"
  ( cd "$app" && "$DART" "$GEN_KERNEL" --platform "$PLATFORM" \
      --target flutter --aot --tfa \
      --packages .dart_tool/package_config.json \
      -o "$WORK/$name.dill" "$entry" ) >"$WORK/$name.kernel.log" 2>&1 \
    || { tail -20 "$WORK/$name.kernel.log"; die "$name: gen_kernel failed"; }

  note "$name: census"
  "$AOT_RUNTIME" "$ANALYZER" --census --dill "$WORK/$name.dill" \
    --include "$prefix" --out "$WORK/$name.census.jsonl"
  head -1 "$WORK/$name.census.jsonl" | python3 -m json.tool --compact
}

corpus airgap "$AIRGAP" package:airgap_probe/main.dart package:airgap_probe/
corpus wonderous "$WONDEROUS" package:wonders/main.dart package:wonders/

note "report"
python3 "$HERE/census_report.py" \
  --corpus "airgap_app|synthetic regression fixture|$WORK/airgap.census.jsonl" \
  --corpus "Wonderous|real application|$WORK/wonderous.census.jsonl" \
  --out "$WORK/CENSUS.txt"
cat "$WORK/CENSUS.txt"
echo
echo "work dir kept: $WORK"
