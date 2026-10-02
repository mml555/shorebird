#!/usr/bin/env bash
# cspell:words dynmod killgate dartaotruntime
#
# verify_binding.sh -- Route B steps 1 and 2, together, in one run.
#
# The kill gate proves dispatch with a self-contained replacement. Spike B
# proves binding, but judges it on the native's own C++ invoke because no Dart
# call site could reach the new body yet. Neither run is the thing a real patch
# has to do, which is BOTH: bind to symbols in the installed release, and be
# reached by ordinary Dart calls.
#
# So this compiles a replacement that calls print() -- an SDK symbol, retained
# by a generated dynamic interface -- and checks it arrives back through plain
# call sites. The two halves fail differently on purpose:
#
#   no BOUND line at all            -> retention (step 2)
#   BOUND, but call shapes are OLD  -> dispatch  (step 1)
#
# Run:
#   SRC=/Volumes/build/route-b/flutter/engine/src \
#   OUT=$SRC/out/host_release_arm64 verify_binding.sh
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
WORK="${WORK:-$(mktemp -d)}"

DART_TREE="$SRC/flutter/third_party/dart"
DART="$OUT/dart-sdk/bin/dart"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
DART2BC="$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart"
GEN_SNAPSHOT="$OUT/gen_snapshot"
AOT_RUNTIME="$OUT/dartaotruntime"
TARGET_URI="package:dynamic_modules/target.dart"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }

[ -d "$OUT" ] || die "no build at $OUT"
grep -q 'dart_dynamic_modules = true' "$OUT/args.gn" 2>/dev/null \
  || die "dart_dynamic_modules is not true in $OUT/args.gn"

mkdir -p "$WORK/lib" "$WORK/.dart_tool"
cp "$REPO/selfhost/engine/killgate/target.dart" "$WORK/lib/target.dart"
cp "$HERE/replacement_binding.dart" "$WORK/replacement.dart"
cat > "$WORK/.dart_tool/package_config.json" <<JSON
{
  "configVersion": 2,
  "packages": [
    {
      "name": "dynamic_modules",
      "rootUri": "file://$WORK/",
      "packageUri": "lib/",
      "languageVersion": "3.9"
    }
  ]
}
JSON

cd "$WORK"

# The interface is generated FROM a kernel, so the kernel is built twice: once
# plain to discover the app's libraries, then again with retention applied. A
# real release pipeline has the same shape.
note "1/5 discovery kernel"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o discover.dill "$TARGET_URI"

note "2/5 dynamic interface (app whole + named SDK members)"
"$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
  "$HERE/gen_dynamic_interface.dart" --dill discover.dill --out di.yaml
sed 's/^/    /' di.yaml

note "3/5 release kernel + AOT snapshot, with retention and the patchable call form"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json \
  --dynamic-interface di.yaml -o target.dill "$TARGET_URI"
"$GEN_SNAPSHOT" --patchable_static_calls \
  --snapshot_kind=app-aot-elf --elf=target.aot target.dill

# dart2bytecode --import-dill wants a PRE-AOT kernel (--no-aot
# --no-link-platform). Feeding it the AOT kernel crashes the CFE -- the dynmod
# recipe, and Spike B's hard-won workaround.
note "4/5 patch bytecode, compiled against the release's kernel"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
  --no-aot --no-link-platform \
  --packages .dart_tool/package_config.json -o host_import.dill "$TARGET_URI"
"$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" \
  --import-dill host_import.dill \
  -o replacement.bytecode replacement.dart

note "5/5 run"
echo "--------------------------------------------------"
set +e
"$AOT_RUNTIME" target.aot replacement.bytecode "$TARGET_URI" 2>&1 | tee run.log
set -e
echo "--------------------------------------------------"

bound=$(grep -c '^BOUND$' run.log || true)
printed=$(grep -c 'NEW-PRINTED' run.log || true)
olds=$(grep -cE '^after .*: OLD$' run.log || true)

echo
if [[ "$bound" -eq 0 ]]; then
  echo "RESULT: RETENTION FAILED (step 2) -- the patch never bound to dart:core print."
  echo "        Look for bytecode_reader.cc:1172 above."
  exit 1
elif [[ "$olds" -gt 0 ]]; then
  echo "RESULT: DISPATCH FAILED (step 1) -- the patch bound and ran, but"
  echo "        $olds call shape(s) still reach the old body."
  exit 1
elif [[ "$printed" -eq 0 ]]; then
  echo "RESULT: INCONCLUSIVE -- BOUND printed but no call shape returned NEW-PRINTED."
  exit 1
else
  echo "RESULT: PASS -- the patch bound to an SDK symbol AND every Dart call"
  echo "        shape reached it. Steps 1 and 2 hold together."
fi

echo
echo "work dir kept: $WORK"
