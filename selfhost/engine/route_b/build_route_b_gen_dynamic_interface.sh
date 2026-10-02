#!/usr/bin/env bash
# cspell:words dartaotruntime dynmod TFA
#
# build_route_b_gen_dynamic_interface.sh -- Route B retention, as a shippable
# artifact.
#
# WHY A RELEASE MUST DECLARE RETENTION
#
# Patch bytecode does not resolve against the base snapshot for free: the AOT
# precompiler drops library dictionaries, so a replacement body referencing any
# symbol dies in bytecode_reader.cc:1172 with "Unable to find function X".
# Retention is declared at release time, via a dynamic interface, and Probe A0
# measured the cost of doing it by NAME at +0.006-0.009% -- against +310% for a
# whole `dart:core` library item.
#
# WHY IT SHIPS IN THE CELL
#
# gen_dynamic_interface.dart needs package:kernel, which exists only inside an
# engine checkout -- the same wall the analyzer and the frontend hit. Resolving
# it from the release's engine hash keeps one lineage across the whole chain:
#
#   release engine hash
#     -> kernel generator -> dynamic-interface generator
#     -> frontend/platform -> bytecode compiler
#
# Same AOT recipe and same trap as build_dart2bytecode.sh: `dart compile kernel`
# produces a NON-AOT kernel and gen_snapshot then dies with "Missing table
# selector metadata!". Use gen_kernel.dart --aot.
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

grep -q 'dart_dynamic_modules = true' "$OUT/args.gn" 2>/dev/null \
  || die "$OUT is not a dart_dynamic_modules build — wrong tree for Route B"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$OUTDIR"

# Staged into the Dart tree's package scope, like the analyzer: it lives in this
# repo but must compile against the ENGINE tree's package:kernel.
cp "$HERE/gen_dynamic_interface.dart" "$W/gen_dynamic_interface.dart"

echo "== AOT kernel =="
cd "$DART_TREE"
"$OUT/dart-sdk/bin/dart" pkg/vm/bin/gen_kernel.dart \
  --aot --platform "$OUT/vm_platform.dill" \
  --packages=.dart_tool/package_config.json \
  -o "$W/gen_di.dill" "$W/gen_dynamic_interface.dart"

echo "== AOT snapshot =="
"$OUT/gen_snapshot" --snapshot_kind=app-aot-elf \
  --elf="$OUTDIR/route_b_gen_dynamic_interface.aot" "$W/gen_di.dill"

echo "== capability check =="
# The three options the release-side invocation depends on. A build missing any
# of them would fail at release time, on someone else's machine.
usage=$("$OUT/dartaotruntime" "$OUTDIR/route_b_gen_dynamic_interface.aot" --help 2>&1 || true)
grep -q -- '--sdk-members' <<<"$usage" \
  || die "artifact does not accept --sdk-members"
grep -q -- '--dill' <<<"$usage" \
  || die "artifact does not accept --dill"

DART_REV=$(git -C "$DART_TREE" rev-parse HEAD 2>/dev/null || echo unknown)
cat > "$OUTDIR/route_b_gen_dynamic_interface.aot.provenance" <<EOF
Route B dynamic-interface generator AOT snapshot
built        : $(date -u +%FT%TZ)
dart tree    : $DART_TREE
dart rev     : $DART_REV
host out     : $OUT
snapshot     : $(shasum -a 256 "$OUTDIR/route_b_gen_dynamic_interface.aot" | cut -d' ' -f1)
runs with    : dartaotruntime from the SAME out dir (version-locked pair)
produces     : the release's dynamic_interface.yaml -- app libraries whole,
               SDK members BY NAME (whole dart:core measured at +310%)
EOF

ls -la "$OUTDIR/route_b_gen_dynamic_interface.aot"
echo
echo "NEXT: selfhost/engine/route_b/publish_route_b_compiler.sh --rev <engineHash>"
