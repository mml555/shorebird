#!/usr/bin/env bash
# cspell:words dartaotruntime dynmod TFA
#
# build_route_b_analyzer.sh -- Route B producer step 3: coverage analysis, as a
# shippable artifact.
#
# `shorebird patch` cannot read a dill. package:kernel is not obtainable from
# pub (the published copy is the abandoned pre-null-safety one, sdk <3.0.0), the
# vended Flutter SDK ships no pkg/ at all, and the live package exists only
# inside an engine checkout. So the analyzer is built here and travels in the
# compiler cell.
#
# That is not a workaround. The kernel binary format is VERSIONED and must match
# the frontend that emitted the dill, so the analyzer belongs to the release's
# toolchain for the same reason dart2bytecode does. A reader from one lineage
# meeting a dill from another fails with a message that names neither -- the
# shape of every mixed-provenance failure in this project.
#
# Same AOT recipe as build_dart2bytecode.sh, including its trap: `dart compile
# kernel` produces a NON-AOT kernel and gen_snapshot then dies with "Missing
# table selector metadata!". Use gen_kernel.dart --aot.
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
DART_TREE=$SRC/flutter/third_party/dart
OUTDIR=${OUTDIR:-$OUT/zip_archives}
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -x "$OUT/dart-sdk/bin/dart" ] || die "no host dart at $OUT/dart-sdk/bin/dart"
[ -x "$OUT/gen_snapshot" ] || die "no gen_snapshot at $OUT/gen_snapshot"
[ -f "$OUT/vm_platform.dill" ] || die "no vm_platform.dill at $OUT"

# Same structural check as the compiler build. An analyzer from the wrong tree
# would read the release's dill with the wrong kernel format version.
grep -q 'dart_dynamic_modules = true' "$OUT/args.gn" 2>/dev/null \
  || die "$OUT is not a dart_dynamic_modules build — wrong tree for Route B"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$OUTDIR"

# The analyzer lives in this repo but must compile against the ENGINE tree's
# package:kernel, so it is staged into the Dart tree's package scope rather than
# resolved from here.
cp "$HERE/coverage/analyze_coverage.dart" "$W/analyze_coverage.dart"

echo "== AOT kernel =="
cd "$DART_TREE"
"$OUT/dart-sdk/bin/dart" pkg/vm/bin/gen_kernel.dart \
  --aot --platform "$OUT/vm_platform.dill" \
  --packages=.dart_tool/package_config.json \
  -o "$W/analyze.dill" "$W/analyze_coverage.dart"

echo "== AOT snapshot =="
"$OUT/gen_snapshot" --snapshot_kind=app-aot-elf \
  --elf="$OUTDIR/route_b_analyze.aot" "$W/analyze.dill"

echo "== capability check =="
# Prove the artifact is the tool we think it is, not merely a file with the
# right name -- the same check the compiler artifact gets, for the same reason.
usage=$("$OUT/dartaotruntime" "$OUTDIR/route_b_analyze.aot" --help 2>&1 || true)
grep -q 'Route B coverage analyzer' <<<"$usage" \
  || die "artifact does not identify itself as the Route B coverage analyzer"
grep -q -- '--patched-dill' <<<"$usage" \
  || die "artifact does not accept --patched-dill"

DART_REV=$(git -C "$DART_TREE" rev-parse HEAD 2>/dev/null || echo unknown)
cat > "$OUTDIR/route_b_analyze.aot.provenance" <<EOF
Route B coverage analyzer AOT snapshot
built        : $(date -u +%FT%TZ)
source       : selfhost/engine/route_b/coverage/analyze_coverage.dart
dart tree    : $DART_TREE
dart rev     : $DART_REV
host out     : $OUT
platform     : $OUT/vm_platform.dill ($(shasum -a 256 "$OUT/vm_platform.dill" | cut -c1-16))
snapshot     : $(shasum -a 256 "$OUTDIR/route_b_analyze.aot" | cut -d' ' -f1)
runs with    : dartaotruntime from the SAME out dir (version-locked pair)
reads        : dills emitted by THIS tree's frontend; the kernel binary format
               is versioned, which is why this ships per engine rather than
               once per CLI
EOF

ls -la "$OUTDIR/route_b_analyze.aot"
echo
echo "NEXT: selfhost/engine/route_b/publish_route_b_compiler.sh --rev <engineHash>"
