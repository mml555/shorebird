#!/usr/bin/env bash
# cspell:words dartaotruntime dynmod
#
# build_route_b_release_probe.sh -- P4.1's instrument, as a shippable artifact.
#
# WHY THIS TRAVELS IN THE CELL. It encodes gen_snapshot's v8 snapshot-profile
# schema (which carries no version field, so the probe asserts the shape
# structurally) and the VM's object-pool call form. Both belong to the COMPILER
# that produced the release, exactly like dart2bytecode and the kernel reader. A
# probe from another lineage would misread the profile and answer confidently.
#
# Unlike the analyzer this needs no package:kernel -- only dart:io and
# dart:convert -- but it is built with the same recipe and shipped in the same
# bundle, because the thing that must match the release is its SCHEMA knowledge,
# not its imports.
#
# Same AOT trap as the others: `dart compile kernel` produces a NON-AOT kernel
# and gen_snapshot then dies with "Missing table selector metadata!". Use
# gen_kernel.dart --aot.
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

# Same structural check as the other cell tools: a probe built from the wrong
# tree would encode a different profile schema than the release's gen_snapshot.
grep -q 'dart_dynamic_modules = true' "$OUT/args.gn" 2>/dev/null \
  || die "$OUT is not a dart_dynamic_modules build — wrong tree for Route B"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$OUTDIR"

cp "$HERE/release_probe.dart" "$W/release_probe.dart"

echo "== AOT kernel =="
cd "$DART_TREE"
"$OUT/dart-sdk/bin/dart" pkg/vm/bin/gen_kernel.dart \
  --aot --platform "$OUT/vm_platform.dill" \
  --packages=.dart_tool/package_config.json \
  -o "$W/probe.dill" "$W/release_probe.dart"

echo "== AOT snapshot =="
"$OUT/gen_snapshot" --snapshot_kind=app-aot-elf \
  --elf="$OUTDIR/route_b_release_probe.aot" "$W/probe.dill"

echo "== smoke =="
# --help must work: the producer validates a resolved cell by running its tools.
"$OUT/dartaotruntime" "$OUTDIR/route_b_release_probe.aot" --help \
  | head -3 | sed 's/^/    /'
"$OUT/dartaotruntime" "$OUTDIR/route_b_release_probe.aot" --help \
  | grep -q 'survival, not reachability\|SURVIVAL, not reachability' \
  || die "the help text no longer states the bound on the claim"

# Every other cell artifact records its own provenance beside itself. Without
# one, the probe would be the single member of the cell whose lineage could not
# be attributed after the fact.
DART_REV=$(git -C "$DART_TREE" rev-parse HEAD 2>/dev/null || echo unknown)
cat > "$OUTDIR/route_b_release_probe.aot.provenance" <<EOF
Route B release probe AOT snapshot (P4.1)
built        : $(date -u +%FT%TZ)
dart tree    : $DART_TREE
dart rev     : $DART_REV
host out     : $OUT
snapshot     : $(shasum -a 256 "$OUTDIR/route_b_release_probe.aot" | cut -d' ' -f1)
probe rev    : $(sed -n 's/^const probeRevision = \([0-9]*\);/\1/p' "$HERE/release_probe.dart")
runs with    : dartaotruntime from the SAME out dir (version-locked pair)
reads        : the release's v8 snapshot profile, which carries NO version field
               of its own -- so this probe asserts the schema structurally and
               fails closed as PROFILE_INVALID rather than misreading a column
answers      : per target, whether a supported invocation site SURVIVED
               compilation. NOT whether execution reaches it: a dead branch has
               a surviving call site and is reported green, deliberately
EOF

echo
echo "built $OUTDIR/route_b_release_probe.aot"
shasum -a 256 "$OUTDIR/route_b_release_probe.aot" | sed 's/^/  /'
sed 's/^/  /' "$OUTDIR/route_b_release_probe.aot.provenance"
