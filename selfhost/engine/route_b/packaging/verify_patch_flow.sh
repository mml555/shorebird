#!/usr/bin/env bash
# cspell:words dynmod killgate dartaotruntime sbrb SBRBPTCH pathlib
#
# verify_patch_flow.sh -- Route B step 5: the whole loop, from an edit to a
# running change, the way `shorebird patch` will eventually drive it.
#
#   release  -> app.aot + target manifest + release build id
#   (edit a Dart function)
#   rebuild  -> kernel diff says WHICH members changed and whether they can land
#   compile  -> bytecode for each changed member, against the release's kernel
#   pack     -> one container, stamped with the release build id
#   apply    -> the running app changes; revert puts it back
#
# The refusal case is tested too: editing a member the release cannot reach must
# fail the build, not produce a container that installs cleanly and does nothing.
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
RB="$(cd "$HERE/.." >/dev/null 2>&1 && pwd)"
WORK="${WORK:-$(mktemp -d)}"

DART_TREE="$SRC/flutter/third_party/dart"
PKGS="$DART_TREE/third_party/pkg/core/pkgs"
DART="$OUT/dart-sdk/bin/dart"
KERNEL_PKGS="--packages=$DART_TREE/.dart_tool/package_config.json"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
DART2BC="$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart"
GEN_SNAPSHOT="$OUT/gen_snapshot"
AOT_RUNTIME="$OUT/dartaotruntime"
URI="package:dynamic_modules/container_target.dart"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }
pass=0; fail=0
check() { if grep -qF "$2" "$3"; then echo "  PASS  $1"; pass=$((pass+1));
          else echo "  FAIL  $1 (expected: $2)"; sed 's/^/        /' "$3"; fail=$((fail+1)); fi; }

[ -d "$OUT" ] || die "no build at $OUT"
mkdir -p "$WORK/lib" "$WORK/.dart_tool"
cp "$HERE/container_target.dart" "$WORK/lib/container_target.dart"
cp "$WORK/lib/container_target.dart" "$WORK/original.dart"
cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$WORK/", "packageUri": "lib/", "languageVersion": "3.9" },
  { "name": "crypto", "rootUri": "file://$PKGS/crypto", "packageUri": "lib/", "languageVersion": "3.4" },
  { "name": "typed_data", "rootUri": "file://$PKGS/typed_data", "packageUri": "lib/", "languageVersion": "3.4" } ] }
JSON
cd "$WORK"

kernel() { "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json "${@:2}" -o "$1" "$URI" >/dev/null; }

note "release"
kernel base.dill
"$DART" "$KERNEL_PKGS" "$RB/gen_dynamic_interface.dart" --dill base.dill --out di.yaml 2>/dev/null
kernel release.dill --dynamic-interface di.yaml
"$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf --elf=app.aot release.dill
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot --no-link-platform \
  --packages .dart_tool/package_config.json -o import.dill "$URI" >/dev/null
"$DART" "$KERNEL_PKGS" "$RB/identity/gen_target_manifest.dart" \
  --dill base.dill --out targets.json 2>/dev/null
BUILD_ID=$("$AOT_RUNTIME" app.aot | sed -n 's/^BUILD_ID //p')
[ -n "$BUILD_ID" ] || die "no release build id"
note "release build id: $BUILD_ID"

note "1. edit a reachable function, then let the tools decide what changed"
python3 - <<PY
import pathlib
p = pathlib.Path("lib/container_target.dart"); s = p.read_text()
s = s.replace("? 'OLD-a' : 'X'", "? 'NEW-a' : 'X'")
p.write_text(s)
PY
kernel patched.dill
set +e
"$DART" "$KERNEL_PKGS" "$HERE/build_patch.dart" --base-dill base.dill \
  --patched-dill patched.dill --manifest targets.json --out changed.json > plan.log 2>&1
plan_rc=$?
set -e
cat plan.log | sed 's/^/    /'
[ "$plan_rc" -eq 0 ] || die "build_patch refused a reachable change (exit $plan_rc)"
check "one member changed"  "changed members : 1" plan.log
check "and it is patchable" "patchable     : 1"   plan.log

note "2. compile bytecode for exactly what changed, pack, apply"
SEL=$(python3 -c "import json;print(json.load(open('changed.json'))['patchable'][0])")
NAME="${SEL##*#}"
cat > repl.dart <<DART
@pragma('dyn-module:entry-point')
String $NAME() => 'NEW-a';
DART
"$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" --import-dill import.dill \
  -o repl.bytecode repl.dart >/dev/null 2>&1 || die "dart2bytecode failed"
"$DART" "$HERE/pack_patch.dart" --release-build-id "$BUILD_ID" --out patch.sbrb \
  --target "$SEL=$WORK/repl.bytecode" 2>/dev/null
"$AOT_RUNTIME" app.aot patch.sbrb --revert > run.log 2>&1 || true
check "applies"           "APPLY ok: 1 target(s)"         run.log
check "alpha changed"     "after  alpha=NEW-a beta=OLD-b" run.log
check "beta untouched"    "before alpha=OLD-a beta=OLD-b" run.log
check "reverts"           "revert alpha=OLD-a beta=OLD-b" run.log

note "3. an unreachable change is refused, not silently shipped"
cp original.dart lib/container_target.dart
python3 - <<'PY'
import pathlib
p = pathlib.Path("lib/container_target.dart"); s = p.read_text()
# Add a helper AND call it, which is what a real edit looks like. An unused
# addition is tree-shaken by --aot and never reaches the kernel at all -- the
# first version of this test added a function nobody called and detected
# nothing, which would have read as "additions are fine".
#
# This is the case that matters: the patch could replace alpha, but alpha's new
# body references a function the RELEASE does not contain, so the bytecode
# would fail to bind at load. The tool has to catch that at build time.
s = s.replace(
    "String alpha() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-a' : 'X';",
    "@pragma('vm:never-inline')\n"
    "String addedHelper() => 'helper';\n\n"
    "@pragma('vm:never-inline')\n"
    "String alpha() => addedHelper();")
p.write_text(s)
PY
kernel added.dill
# Expected to exit non-zero: an addition cannot be patched in, and the tool
# must say so rather than emit a container.
set +e
"$DART" "$KERNEL_PKGS" "$HERE/build_patch.dart" --base-dill base.dill \
  --patched-dill added.dill --manifest targets.json --out added.json > added.log 2>&1
set -e
cat added.log | sed 's/^/    /'
check "detects the addition"  "cannot be patched in" added.log
check "and refuses"           "REFUSING"            added.log
cp original.dart lib/container_target.dart

echo
echo "--------------------------------------------------"
echo "step 5: $pass passed, $fail failed"
echo "work dir kept: $WORK"
[ "$fail" -eq 0 ] || exit 1
