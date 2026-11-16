#!/usr/bin/env bash
# cspell:words dartaotruntime sbrbptch
#
# added_helper.sh -- a Route B patch may ADD a top-level function (a "helper").
#
# Until analysis version 16 any function present only in the patched kernel
# made the whole patch unrepresentable. The replacement library can hold more
# than its entry declaration, so the producer now appends the source of every
# helper a target reaches. This drives the CLI's own analyzer and producer over
# REAL patched source (an edit to the test app, not text injected into the
# replacement) and runs the container on a runtime that attaches.
#
# Arms, one patched source each:
#   control             an ordinary body edit; nothing new
#   public_helper       alpha calls an added public function
#   private_helper      ... an added private function
#   helper_getter       ... an added top-level getter
#   helper_args         ... an added function with arguments
#   helper_closure      ... passes a closure to an added function
#   helper_chain        ... added function calling added function
#   helper_calls_release  an added function calling a release function
#   shared_by_two       alpha and beta both call one added function
#   unused_helper       an added function nothing calls: shipped nowhere, no refusal
#   refused_*           an added static member of a class; an added instance method called on another receiver
#                       member (setters, operators, extension members and
#                       part-file members are covered by the analyzer's reasons)
#   refused_tear_off    an added function used as a value, plain or in a const:
#                       each patched function would carry its own copy
#   refused_entry_point_helper, refused_release_private_in_helper,
#   refused_setter      the producer's and analyzer's other helper refusals
#   back_compat         the OLD cell (analysis 15) must still refuse a helper
#
# Host, not device. Needs a runtime that attaches (host_release_arm64_ddm).
#
#   OUT=$HOME/shorebird-engine/flutter/engine/src/out/host_release_arm64_ddm \
#     added_helper.sh <route_b dir> <cell zip with analysis 16> <old cell zip>
set -euo pipefail
SRC=${SRC:-$HOME/shorebird-engine/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64_ddm}
HERE=$(cd "$(dirname "$0")" && pwd)
RB=$1
CELL_NEW=$2
CELL_OLD=$3
REPO=$(cd "$RB/../../.." && pwd)
WORK=${WORK:-$REPO/../tmp/added_helper_work}
rm -rf "$WORK"; mkdir -p "$WORK/lib" "$WORK/.dart_tool"
WORK=$(cd "$WORK" && pwd)
DART_TREE=$SRC/flutter/third_party/dart
DART=$OUT/dart-sdk/bin/dart
KERNEL_PKGS="--packages=$DART_TREE/.dart_tool/package_config.json"
GEN_KERNEL=$DART_TREE/pkg/vm/bin/gen_kernel.dart
PKGS_DIR=$DART_TREE/third_party/pkg/core/pkgs
ENGINE=d0714887dd95d2990e0185fe1893523f3d600cc5
CLI_PKGS=$REPO/.dart_tool/package_config.json
cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$WORK/", "packageUri": "lib/", "languageVersion": "3.9" },
  { "name": "crypto", "rootUri": "file://$PKGS_DIR/crypto", "packageUri": "lib/", "languageVersion": "3.4" },
  { "name": "typed_data", "rootUri": "file://$PKGS_DIR/typed_data", "packageUri": "lib/", "languageVersion": "3.4" } ] }
JSON
URI=package:dynamic_modules/container_target.dart
PLAT=$OUT/vm_platform.dill
cd "$WORK"
cp "$RB/packaging/container_target.dart" lib/container_target.dart
# An instance method for the method-target arm, the shape of a widget's
# `build`: it reads its own field. Printed with alpha and beta.
cat >> lib/container_target.dart <<'DART'

class RbBox {
  String tag = 'BOX';
  @pragma('vm:never-inline')
  String show() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-box' : 'X';
}
DART
sed -i '' 's|^void _state(String when) => print(.\$when alpha=\${alpha()} beta=\${beta()}.);|void _state(String when) => print('"'"'$when alpha=${alpha()} beta=${beta()} box=${RbBox().show()}'"'"');|' lib/container_target.dart
grep -q 'box=\${RbBox().show()}' lib/container_target.dart || { echo "ERROR: could not add box= to _state"; exit 1; }
"$DART" "$GEN_KERNEL" --platform "$PLAT" --aot --packages .dart_tool/package_config.json -o prepass.dill "$URI" >/dev/null
"$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill prepass.dill --out di.yaml --sdk-members \
  'dart:core#print,dart:core#DateTime.now,dart:core#DateTime.get:millisecondsSinceEpoch' 2>/dev/null
"$DART" "$GEN_KERNEL" --platform "$PLAT" --aot --packages .dart_tool/package_config.json --dynamic-interface di.yaml -o base.dill "$URI" >/dev/null
"$OUT/gen_snapshot" --patchable_static_calls --snapshot_kind=app-aot-elf --elf=app.aot base.dill
"$DART" "$GEN_KERNEL" --platform "$PLAT" --no-aot --no-link-platform --packages .dart_tool/package_config.json -o import.dill "$URI" >/dev/null
BUILD_ID=$("$OUT/dartaotruntime" app.aot | sed -n 's/^BUILD_ID //p')
echo "release $BUILD_ID"
cp lib/container_target.dart release_source.dart

NOW="DateTime.now().millisecondsSinceEpoch >= 0"
FAILS=0
RESULTS=()

# patch_source <alpha-expr> <beta-expr> <extra top-level text> [<line for ApplyResult>]
# Writes the patched source: alpha/beta bodies replaced, text appended, and an
# optional line inserted into the existing class ApplyResult.
patch_source() {
  cp release_source.dart lib/container_target.dart
  # An empty expression leaves the release's own body, so a member the arm does
  # not mean to change is not reported as changed.
  if [ -n "$1" ]; then sed -i '' "s|^String alpha() => .*|String alpha() => $1;|" lib/container_target.dart; fi
  if [ -n "$2" ]; then sed -i '' "s|^String beta() => .*|String beta() => $2;|" lib/container_target.dart; fi
  if [ -n "${3:-}" ]; then printf '\n%s\n' "$3" >> lib/container_target.dart; fi
  if [ -n "${4:-}" ]; then
    awk -v line="  $4" '{print} /^class ApplyResult \{/{print line}' lib/container_target.dart > edited.dart
    mv edited.dart lib/container_target.dart
  fi
  "$DART" "$GEN_KERNEL" --platform "$PLAT" --aot --packages .dart_tool/package_config.json --dynamic-interface di.yaml -o patched.dill "$URI" >"$d/gen_kernel.log" 2>&1 \
    || { echo "  ! patched source did not compile"; sed 's/^/  ! /' "$d/gen_kernel.log" | head; return 1; }
}

drive() { # <cell> <outdir>
  set +e
  "$DART" --packages="$CLI_PKGS" "$HERE/cli_lower.dart" "$1" base.dill patched.dill import.dill "$BUILD_ID" "$2/cli" "$WORK" "$PLAT" "$ENGINE" > "$2/cli.log" 2>&1
  CLI_EXIT=$?
  set -e
}

record() { RESULTS+=("$1|$2"); echo "  RESULT $1: $2"; [ "$2" = PASS ] || FAILS=$((FAILS+1)); }

# arm <label> <cell> <alpha> <beta> <text> <class-edit> <want-alpha> <want-beta> [<shipped-grep-not>]
arm() {
  local label=$1 cell=$2
  d=$WORK/$label; mkdir -p "$d"
  echo; echo "==> $label"
  patch_source "$3" "$4" "${5:-}" "${6:-}" || { record "$label" "FAIL (harness)"; return; }
  drive "$cell" "$d"
  grep -E '^(coverage|helpers|unused|REFUSED|REJECT|container|  target)' "$d/cli.log" | sed 's/^/  /' || true
  if [ -f "$d/cli/replacement_0.dart" ]; then sed 's/^/  | /' "$d/cli/replacement_0.dart" | sed -n '/entry-point/,$p'; fi
  local c; c=$(sed -n 's/^OUT=//p' "$d/cli.log")
  if [ -z "$c" ]; then tail -12 "$d/cli.log" | sed 's/^/  ! /'; record "$label" "FAIL (no container)"; return; fi
  "$OUT/dartaotruntime" app.aot "$c" > "$d/run.log" 2>&1 || true
  grep -E '^(APPLY|after)' "$d/run.log" | sed 's/^/  /'
  local a b
  a=$(sed -n 's/^after .*alpha=\([^ ]*\).*/\1/p' "$d/run.log"); b=$(sed -n 's/^after .*beta=\([^ ]*\).*/\1/p' "$d/run.log")
  if [ "$a" = "$7" ] && [ "$b" = "$8" ]; then record "$label" PASS
  else record "$label" "FAIL got alpha=${a:-none} beta=${b:-none} want alpha=$7 beta=$8"; fi
}

# refused <label> <cell> <alpha> <text> <class-edit> <phrase the refusal must contain>
refused() {
  local label=$1 cell=$2
  d=$WORK/$label; mkdir -p "$d"
  echo; echo "==> $label"
  patch_source "$3" "" "${4:-}" "${5:-}" || { record "$label" "FAIL (harness)"; return; }
  drive "$cell" "$d"
  grep -E '^(coverage|REFUSED|REJECT|container)|^ +(new member|a patch)' "$d/cli.log" | sed 's/^/  /' || true
  if [ "$CLI_EXIT" -ne 0 ] && ! grep -q '^OUT=' "$d/cli.log" && grep -qF -- "$6" "$d/cli.log"; then
    record "$label" PASS
  else record "$label" "FAIL (exit $CLI_EXIT, wanted a refusal containing: $6)"; tail -8 "$d/cli.log" | sed 's/^/  ! /'; fi
}

arm control "$CELL_NEW" "'NEW-a'" "" "" "" NEW-a OLD-b
arm public_helper "$CELL_NEW" "rbAdded()" "" "String rbAdded() => $NOW ? 'NEW-HELPER' : 'X';" "" NEW-HELPER OLD-b
arm private_helper "$CELL_NEW" "_rbAdded()" "" "String _rbAdded() => $NOW ? 'NEW-PRIV' : 'X';" "" NEW-PRIV OLD-b
arm helper_getter "$CELL_NEW" "rbGot" "" "String get rbGot => $NOW ? 'NEW-GET' : 'X';" "" NEW-GET OLD-b
arm helper_args "$CELL_NEW" "rbPick('L', 'R', 1)" "" "String rbPick(String a, String b, int n) => n == 0 ? a : b;" "" R OLD-b
arm helper_closure "$CELL_NEW" "rbApply((x) => x == 'C' ? 'CLOSED' : 'X', 'C')" "" "String rbApply(String Function(String) f, String s) => f(s);" "" CLOSED OLD-b
arm helper_chain "$CELL_NEW" "rbOuter()" "" "String rbOuter() => rbInner(); String rbInner() => 'IN';" "" IN OLD-b
arm helper_calls_release "$CELL_NEW" "rbVia()" "" "String rbVia() => beta();" "" OLD-b OLD-b
arm shared_by_two "$CELL_NEW" "rbTag('a')" "rbTag('b')" "String rbTag(String s) => $NOW ? 'T-\$s' : 'X';" "" T-a T-b
arm unused_helper "$CELL_NEW" "'NEW-a'" "" "String rbNobody() => 'N';" "" NEW-a OLD-b
if grep -q rbNobody "$WORK/unused_helper/cli/replacement_0.dart"; then record unused_helper_not_shipped "FAIL (shipped)"; else record unused_helper_not_shipped PASS; fi
# method <label> <show body> <text> <want box>: patch RbBox.show, a method
# target, with a helper. Its accesses are public, so private names resolve in
# the replacement library and a private helper is allowed.
method() {
  local label=$1
  d=$WORK/$label; mkdir -p "$d"
  echo; echo "==> $label"
  cp release_source.dart lib/container_target.dart
  sed -i '' "s|^  String show() => .*|  String show() => $2;|" lib/container_target.dart
  printf '\n%s\n' "$3" >> lib/container_target.dart
  "$DART" "$GEN_KERNEL" --platform "$PLAT" --aot --packages .dart_tool/package_config.json --dynamic-interface di.yaml -o patched.dill "$URI" >"$d/gen_kernel.log" 2>&1 \
    || { sed 's/^/  ! /' "$d/gen_kernel.log" | head; record "$label" "FAIL (harness)"; return; }
  drive "$CELL_NEW" "$d"
  grep -E '^(coverage|helpers|REFUSED|container|  target)' "$d/cli.log" | sed 's/^/  /' || true
  if [ -f "$d/cli/replacement_0.dart" ]; then sed 's/^/  | /' "$d/cli/replacement_0.dart" | sed -n '/entry-point/,$p'; fi
  local c; c=$(sed -n 's/^OUT=//p' "$d/cli.log")
  if [ -z "$c" ]; then tail -12 "$d/cli.log" | sed 's/^/  ! /'; record "$label" "FAIL (no container)"; return; fi
  "$OUT/dartaotruntime" app.aot "$c" > "$d/run.log" 2>&1 || true
  grep -E '^(APPLY|after)' "$d/run.log" | sed 's/^/  /'
  local got; got=$(sed -n 's/^after .*box=\([^ ]*\).*/\1/p' "$d/run.log")
  if [ "$got" = "$4" ]; then record "$label" PASS; else record "$label" "FAIL got box=${got:-none} want $4"; fi
}
method method_private_helper "_rbBox(tag)" "String _rbBox(String t) => t == 'BOX' ? 'NEW-BOX' : 'X';" NEW-BOX
method method_public_helper "rbBox()" "String rbBox() => 'PUB-BOX';" PUB-BOX

refused refused_static_member "$CELL_NEW" "ApplyResult.rbS()" "" "static String rbS() => 'S';" "static member"
refused refused_instance_member "$CELL_NEW" "ApplyResult(true, '', const []).rbI()" "" "String rbI() => 'I';" "another receiver"
refused refused_tear_off "$CELL_NEW" "rbApply(rbShout, 'x')" "String rbShout(String s) => 'X'; String rbApply(String Function(String) f, String s) => f(s);" "" "torn off"
refused refused_const_tear_off "$CELL_NEW" "rbFirst(const [rbShout2])" "String rbShout2() => 'X'; String rbFirst(List<String Function()> fs) => fs[0]();" "" "torn off"
refused refused_entry_point_helper "$CELL_NEW" "rbMarked()" "@pragma('dyn-module:entry-point') String rbMarked() => 'M';" "" "entry point"
refused refused_release_private_in_helper "$CELL_NEW" "rbUsesState()" "String rbUsesState() { _state('x'); return 'S'; }" "" "not a new function this patch carries"
refused refused_setter "$CELL_NEW" "(rbSet = 'v')" "set rbSet(String v) {}" "" "setter"
refused back_compat_old_cell "$CELL_OLD" "rbAdded()" "String rbAdded() => $NOW ? 'NEW-HELPER' : 'X';" "" "cannot introduce members"

echo; echo "== SUMMARY"
for r in "${RESULTS[@]}"; do printf '  %-28s %s\n' "${r%%|*}" "${r#*|}"; done
[ "$FAILS" -eq 0 ] && echo "ALL PASS" || { echo "$FAILS FAILED"; exit 1; }
