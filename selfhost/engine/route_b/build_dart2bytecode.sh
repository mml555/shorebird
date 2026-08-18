#!/usr/bin/env bash
# cspell:words dartaotruntime dynmod TFA killgate
#
# build_dart2bytecode.sh -- Route B producer step 1: the patch compiler, as a
# shippable artifact.
#
# `shorebird patch` cannot depend on a Dart script sitting in an engine
# checkout, so dart2bytecode has to become an owned host artifact alongside
# gen_snapshot and analyze_snapshot. This builds it; publishing it under the
# engine hash is the next step.
#
# PROVENANCE IS THE POINT, not convenience. The compiler that produces a patch
# must come from the SAME Route B Dart lineage as the release being patched.
# Every mixed-provenance failure in this project had one shape -- a tool from
# one tree meeting artifacts from another, failing with a message that named
# neither. The worst was an overlay whose sky_engine.zip came from the Route B
# tree while its platform dill came from the shipping tree; it surfaced as a CFE
# error about a missing method, pointing at nothing useful.
#
# So this must be built from the tree that built the engine, and resolved at
# patch time from the RELEASE's engine hash -- never from whichever binary
# happens to be on PATH.
#
# WHY AN AOT SNAPSHOT AND NOT A KERNEL. Same shape as frontend_server_aot:
# `dartaotruntime <snapshot>` needs no Dart SDK on the user's machine, and the
# dartaotruntime/snapshot pair is version-locked, which is exactly the coupling
# we want to be explicit about.
#
# TRAP: `dart compile kernel` produces a NON-AOT kernel, and gen_snapshot then
# dies with
#
#   dispatch_table_generator.cc: 438: error: Missing table selector metadata!
#   Probably gen_kernel was run in non-AOT mode or without TFA.
#
# which names the cause but not the fix. Use gen_kernel.dart --aot.
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
DART_TREE=$SRC/flutter/third_party/dart
OUTDIR=${OUTDIR:-$OUT/zip_archives}

die() { echo "ERROR: $*" >&2; exit 1; }

[ -x "$OUT/dart-sdk/bin/dart" ] || die "no host dart at $OUT/dart-sdk/bin/dart"
[ -x "$OUT/gen_snapshot" ] || die "no gen_snapshot at $OUT/gen_snapshot"
[ -f "$OUT/vm_platform.dill" ] || die "no vm_platform.dill at $OUT"

# The tree must be the Route B one, or the compiler will not agree with the
# engine it is meant to feed. Cheap structural check rather than a promise.
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
  -o "$W/dart2bytecode.dill" pkg/dart2bytecode/bin/dart2bytecode.dart

echo "== AOT snapshot =="
"$OUT/gen_snapshot" --snapshot_kind=app-aot-elf \
  --elf="$OUTDIR/dart2bytecode_aot.snapshot" "$W/dart2bytecode.dill"

echo "== capability check =="
# Prove the artifact is the tool we think it is, not merely a file with the
# right name. `--target flutter` is the mode Route B patches are compiled in;
# a build without it would fail at patch time, on a customer's machine.
usage=$("$OUT/dartaotruntime" "$OUTDIR/dart2bytecode_aot.snapshot" --help 2>&1 || true)
grep -q 'Compiles Dart sources to Dart bytecode' <<<"$usage" \
  || die "artifact does not identify itself as dart2bytecode"
grep -q 'flutter' <<<"$usage" \
  || die "artifact does not support --target flutter"

DART_REV=$(git -C "$DART_TREE" rev-parse HEAD 2>/dev/null || echo unknown)
cat > "$OUTDIR/dart2bytecode_aot.snapshot.provenance" <<EOF
dart2bytecode AOT snapshot
built        : $(date -u +%FT%TZ)
dart tree    : $DART_TREE
dart rev     : $DART_REV
host out     : $OUT
platform     : $OUT/vm_platform.dill ($(shasum -a 256 "$OUT/vm_platform.dill" | cut -c1-16))
snapshot     : $(shasum -a 256 "$OUTDIR/dart2bytecode_aot.snapshot" | cut -d' ' -f1)
runs with    : dartaotruntime from the SAME out dir (version-locked pair)
EOF

ls -la "$OUTDIR/dart2bytecode_aot.snapshot"
echo
echo "NEXT: publish under the engine hash, add to the provenance audit, then"
echo "      add a ShorebirdArtifact entry so the CLI resolves it from the"
echo "      RELEASE's engine hash rather than from PATH."
