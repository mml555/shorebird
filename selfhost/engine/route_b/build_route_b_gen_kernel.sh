#!/usr/bin/env bash
# cspell:words dartaotruntime dynmod TFA
#
# build_route_b_gen_kernel.sh -- Route B producer step 4: the release's own
# frontend, as a shippable artifact.
#
# WHY THE RELEASE NEEDS A SECOND KERNEL
#
# `dart2bytecode --import-dill` cannot read the AOT kernel that `flutter build
# ipa` produces. Reproduced against the shipped compiler:
#
#   Crash when compiling: Null check operator used on a null value
#   #0  new DillExtensionBuilder (front_end/src/dill/dill_extension_builder.dart:66)
#
# So the release must also carry a `--no-aot --no-link-platform` kernel. That is
# not something `flutter build ipa` emits, so it takes its own gen_kernel run.
#
# WHY GEN_KERNEL SHIPS IN THE CELL RATHER THAN BEING FOUND LOCALLY
#
# "Generate it at release time, the ambient toolchain IS the release toolchain"
# is true today and is exactly the kind of ambient invariant this project keeps
# removing. Resolving the frontend from the release's engine hash makes the
# relationship structural instead: both release kernels are then provably from
# the release engine's frontend lineage, and no machine's PATH or checkout can
# change that.
#
# It is also the same wall the analyzer hit -- gen_kernel.dart needs
# package:kernel, which exists only inside an engine checkout.
#
# Same AOT recipe and same trap as build_dart2bytecode.sh: `dart compile kernel`
# produces a NON-AOT kernel and gen_snapshot then dies with "Missing table
# selector metadata!". Use gen_kernel.dart --aot to build gen_kernel.
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
DART_TREE=$SRC/flutter/third_party/dart
OUTDIR=${OUTDIR:-$OUT/zip_archives}

die() { echo "ERROR: $*" >&2; exit 1; }

[ -x "$OUT/dart-sdk/bin/dart" ] || die "no host dart at $OUT/dart-sdk/bin/dart"
[ -x "$OUT/gen_snapshot" ] || die "no gen_snapshot at $OUT/gen_snapshot"
[ -f "$OUT/vm_platform.dill" ] || die "no vm_platform.dill at $OUT"

grep -q 'dart_dynamic_modules = true' "$OUT/args.gn" 2>/dev/null \
  || die "$OUT is not a dart_dynamic_modules build — wrong tree for Route B"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$OUTDIR"

echo "== AOT kernel =="
cd "$DART_TREE"
"$OUT/dart-sdk/bin/dart" pkg/vm/bin/gen_kernel.dart \
  --aot --platform "$OUT/vm_platform.dill" \
  --packages=.dart_tool/package_config.json \
  -o "$W/gen_kernel.dill" pkg/vm/bin/gen_kernel.dart

echo "== AOT snapshot =="
"$OUT/gen_snapshot" --snapshot_kind=app-aot-elf \
  --elf="$OUTDIR/route_b_gen_kernel.aot" "$W/gen_kernel.dill"

echo "== capability check =="
# The three options the release-side invocation depends on. A build missing any
# of them would fail at release time, on someone else's machine.
usage=$("$OUT/dartaotruntime" "$OUTDIR/route_b_gen_kernel.aot" --help 2>&1 || true)
grep -q 'Compiles Dart sources to a kernel binary file' <<<"$usage" \
  || die "artifact does not identify itself as gen_kernel"
# Printed as --[no-]aot / --[no-]link-platform, so match the option name rather
# than the negated spelling the release-side invocation actually passes.
for opt in '--\[no-\]aot' '--\[no-\]link-platform' '--packages'; do
  grep -q -- "$opt" <<<"$usage" || die "artifact does not accept $opt"
done

DART_REV=$(git -C "$DART_TREE" rev-parse HEAD 2>/dev/null || echo unknown)
cat > "$OUTDIR/route_b_gen_kernel.aot.provenance" <<EOF
Route B frontend (gen_kernel) AOT snapshot
built        : $(date -u +%FT%TZ)
dart tree    : $DART_TREE
dart rev     : $DART_REV
host out     : $OUT
snapshot     : $(shasum -a 256 "$OUTDIR/route_b_gen_kernel.aot" | cut -d' ' -f1)
runs with    : dartaotruntime from the SAME out dir (version-locked pair)
produces     : the release's --no-aot --no-link-platform kernel, so both release
               kernels come from ONE frontend lineage -- the release engine's
EOF

ls -la "$OUTDIR/route_b_gen_kernel.aot"
echo
echo "NEXT: selfhost/engine/route_b/publish_route_b_compiler.sh --rev <engineHash>"
