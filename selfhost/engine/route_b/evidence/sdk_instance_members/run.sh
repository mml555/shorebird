#!/usr/bin/env bash
# run.sh <main|sub> <work dir>
#
# Host measurement of which dart: instance members resolve in a patch on a
# release that never calls them. One heavy job at a time: take
# ~/Developer/shorebird-wt/tmp/heavy.lock around it. Needs a host ddm build
# ($OUT), a published compiler cell zip ($CELL, analysis 17) and this repo
# bootstrapped (scripts/bootstrap.sh). Results: <work>/results.tsv
set -uo pipefail
VARIANT=${1:?main|sub}; WORK=${2:?work dir}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=${REPO:-$(cd "$HERE/../../../../.." && pwd)}
RB=$REPO/selfhost/engine/route_b
SRC=${SRC:-$HOME/shorebird-engine/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64_ddm}
CELL=${CELL:-$HOME/Developer/shorebird-wt/tmp/cell17.zip}
ENGINE=${ENGINE:-d0714887dd95d2990e0185fe1893523f3d600cc5}
DT=$SRC/flutter/third_party/dart
DART=$OUT/dart-sdk/bin/dart
KP="--packages=$DT/.dart_tool/package_config.json"
GK=$DT/pkg/vm/bin/gen_kernel.dart
PKGS=$DT/third_party/pkg/core/pkgs
PLAT=$OUT/vm_platform.dill
URI=package:dynamic_modules/container_target.dart
mkdir -p "$WORK/lib" "$WORK/.dart_tool"; cd "$WORK"
cat > .dart_tool/package_config.json <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$WORK/", "packageUri": "lib/", "languageVersion": "3.9" },
  { "name": "crypto", "rootUri": "file://$PKGS/crypto", "packageUri": "lib/", "languageVersion": "3.4" },
  { "name": "typed_data", "rootUri": "file://$PKGS/typed_data", "packageUri": "lib/", "languageVersion": "3.4" } ] }
JSON
python3 "$HERE/gen_probe.py" "$VARIANT" "$RB/packaging/container_target.dart" "$WORK/gen" || exit 1
cp gen/release_source.dart lib/container_target.dart
K="$DART $GK --platform $PLAT --packages .dart_tool/package_config.json"
$K --aot -o prepass.dill $URI >/dev/null || exit 1
$K --no-aot --no-link-platform -o import.dill $URI >/dev/null || exit 1
# The release's interface names only these SDK members (the product's list).
$DART $KP $RB/gen_dynamic_interface.dart --dill prepass.dill --private-dill import.dill --policy p2 \
  --out di.yaml --manifest manifest.json \
  --sdk-members 'dart:core#print,dart:core#DateTime.now,dart:core#DateTime.get:millisecondsSinceEpoch,dart:core#identical' >/dev/null || exit 1
$K --aot --dynamic-interface di.yaml -o base.dill $URI >/dev/null || exit 1
$OUT/gen_snapshot --patchable_static_calls --route_b_untabled_overrides --snapshot_kind=app-aot-elf --elf=app.aot base.dill || exit 1
BUILD_ID=$($OUT/dartaotruntime app.aot | sed -n 's/^BUILD_ID //p')
cp gen/patched_source.dart lib/container_target.dart
$K --aot --dynamic-interface di.yaml -o patched.dill $URI > gk.log 2>&1 || { head gk.log; exit 1; }
$DART --packages=$REPO/.dart_tool/package_config.json $RB/probes/cli_lower.dart "$CELL" base.dill patched.dill import.dill "$BUILD_ID" cli "$WORK" "$PLAT" "$ENGINE" manifest.json > cli.log 2>&1
C=$(sed -n 's/^OUT=//p' cli.log); [ -n "$C" ] || { tail -20 cli.log; exit 1; }
# One process per probe, one target per container: a member that exists without code ABORTS the process
# ("Attempt to compile function ...") instead of throwing, and one abort must
# not hide the others.
mkdir -p logs
for id in $(cat gen/ids.txt); do
  python3 "$HERE/repack.py" "$C" "p_$id" logs/$id.sbrb || continue
  PROBE=$id $OUT/dartaotruntime app.aot logs/$id.sbrb > logs/$id.log 2>&1; echo "exit=$?" >> logs/$id.log
done
python3 "$HERE/table.py" gen/ids.txt logs "$WORK/results.tsv"
