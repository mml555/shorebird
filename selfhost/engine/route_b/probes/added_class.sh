#!/usr/bin/env bash
# cspell:words dartaotruntime prepass sbrbptch untabled noext SDKM rror
#
# added_class.sh -- can a Route B patch module declare a NEW class? (the rung
# after added_method.sh and added_helper.sh). See ROUTE_B.md, "New class".
#
# HAND-BUILT, NOT PRODUCED. Unlike added_method.sh and added_helper.sh this does
# NOT drive the CLI's analyzer and producer over patched source: the analyzer
# refuses a new class header, constructor and member (analyze_coverage.dart,
# "this class is not in the release"), and the producer ships one top-level
# function per target and cannot slice a class. So each arm hand-writes the
# replacement library, compiles it with the cell's own dart2bytecode (without
# --validate, as the producer does), packs it with the CLI's own container
# writer, and runs it on a runtime that attaches. This measures what the
# VM and the release interface allow, which is the question the analyzer and
# producer work is waiting on. It says nothing about whether they can emit it.
#
# What the experiment found (new_class_feasibility.md section 6): a module
# class that extends an AOT class works only if the release's dynamic interface
# declares the base `extendable` and its overridden member `can-be-overridden`.
# Without them it aborts (tabled calls) or runs the WRONG override (untabled).
# The release interface here comes from gen_dynamic_interface.dart, with
# `--extendable` for the "with" arms and without it for the "without" arms.
#
# Arms (class RbBase, subclass RbBase2 in the release, target RbBox.show):
#   plain_*        a private class extending Object, with a field and a const
#                  constructor                       (tabled and untabled)
#   ext_*          a module class extending RbBase, release declares RbBase
#                  extendable + RbBase.name can-be-overridden  (tabled, untabled)
#   noext_*        the same class, release does NOT declare them. EXPECTED
#                  FAILURES, recorded as passes when they fail the known way:
#                    tabled    process abort, object.cc "unreachable code"
#                    untabled  runs RbBase2.name (wrong override), not the module's
#   ident_*        two equal const instances of a module class, in one function
#                  and across two module functions: identical? Asked with `==`
#                  (no `operator ==` declared, so it is Object's: identity),
#                  because `identical` is not in the release's interface (the
#                  first run aborted: "Unable to find function identical")
#   flag_off       the generated interface without --extendable has neither section
#   flag_on        with it, both sections, naming RbBase
#
# Host, not device. Do not run against a device.
#
#   OUT=$HOME/shorebird-engine/flutter/engine/src/out/host_release_arm64_ddm \
#   CLI_PKGS=<package_config.json that resolves package:shorebird_cli> \
#     added_class.sh <route_b dir> <cell zip, with dart2bytecode.aot>
set -euo pipefail
SRC=${SRC:-$HOME/shorebird-engine/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64_ddm}
RB=$1
CELL=$2
REPO=$(cd "$RB/../../.." && pwd)
WORK=${WORK:-$REPO/../tmp/added_class_work}
rm -rf "$WORK"; mkdir -p "$WORK/lib" "$WORK/.dart_tool" "$WORK/cell"
WORK=$(cd "$WORK" && pwd)
DART_TREE=$SRC/flutter/third_party/dart
DART=$OUT/dart-sdk/bin/dart
KERNEL_PKGS="--packages=$DART_TREE/.dart_tool/package_config.json"
GEN_KERNEL=$DART_TREE/pkg/vm/bin/gen_kernel.dart
PKGS_DIR=$DART_TREE/third_party/pkg/core/pkgs
CLI_PKGS=${CLI_PKGS:-$REPO/.dart_tool/package_config.json}
[ -f "$CLI_PKGS" ] || { echo "ERROR: CLI_PKGS $CLI_PKGS does not exist (run scripts/bootstrap.sh or point CLI_PKGS at a resolved package_config.json)"; exit 1; }
cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$WORK/", "packageUri": "lib/", "languageVersion": "3.9" },
  { "name": "crypto", "rootUri": "file://$PKGS_DIR/crypto", "packageUri": "lib/", "languageVersion": "3.4" },
  { "name": "typed_data", "rootUri": "file://$PKGS_DIR/typed_data", "packageUri": "lib/", "languageVersion": "3.4" } ] }
JSON
URI=package:dynamic_modules/container_target.dart
PLAT=$OUT/vm_platform.dill
cd "$WORK"
unzip -q "$CELL" -d "$WORK/cell"
cp "$RB/packaging/container_target.dart" lib/container_target.dart
python3 - lib/container_target.dart <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s += '''
class RbBase {
  @pragma('vm:never-inline')
  String name() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'BASE' : 'X';
}
class RbBase2 extends RbBase {
  @override
  @pragma('vm:never-inline')
  String name() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'B2' : 'X';
}
@pragma('vm:never-inline')
String viaBase(RbBase b) => b.name();
class RbBox {
  String tag = 'BOX';
  @pragma('vm:never-inline')
  String show() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-box' : 'X';
}
'''
old = "void _state(String when) => print('$when alpha=${alpha()} beta=${beta()}');"
assert old in s
s = s.replace(old, "void _state(String when) => print('$when alpha=${alpha()} beta=${beta()} box=${RbBox().show()} base=${viaBase(RbBase())},${viaBase(RbBase2())}');")
p.write_text(s)
PY
SDKM='dart:core#print,dart:core#DateTime.now,dart:core#DateTime.get:millisecondsSinceEpoch'
"$DART" "$GEN_KERNEL" --platform "$PLAT" --aot --packages .dart_tool/package_config.json -o prepass.dill "$URI" >/dev/null
"$DART" "$GEN_KERNEL" --platform "$PLAT" --no-aot --no-link-platform --packages .dart_tool/package_config.json -o import.dill "$URI" >/dev/null
gen() { # <out yaml> [extra flags]
  local o=$1; shift
  "$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill prepass.dill --private-dill import.dill --policy p2 \
    --out "$o" --manifest "$o.manifest.json" --sdk-members "$SDKM" "$@" >/dev/null 2>&1
}
gen di_plain.yaml
gen di_ext.yaml --extendable "$URI#RbBase.name"
echo "== interface sections, without / with --extendable"
echo "  without: $(grep -E '^[a-z-]+:' di_plain.yaml | tr -d '\n')"
echo "  with   : $(grep -E '^[a-z-]+:' di_ext.yaml | tr -d '\n')"

FAILS=0
RESULTS=()
record() { RESULTS+=("$1|$2"); echo "  RESULT $1: $2"; [ "$2" = PASS ] || FAILS=$((FAILS+1)); }
want() { [ -z "${ONLY:-}" ] || [[ $1 =~ $ONLY ]]; }

if want flag_off; then
  echo; echo "==> flag_off"
  if ! grep -qE '^(extendable|can-be-overridden):' di_plain.yaml; then record flag_off PASS; else record flag_off "FAIL (sections present with the flag off)"; fi
fi
if want flag_on; then
  echo; echo "==> flag_on"
  if grep -qE '^extendable:' di_ext.yaml && grep -qE '^can-be-overridden:' di_ext.yaml && grep -q "class: 'RbBase'" di_ext.yaml && grep -q "member: 'name'" di_ext.yaml; then
    record flag_on PASS; else record flag_on "FAIL (sections missing)"; fi
fi

# release <name> <di> <extra gen_snapshot flag>  -> sets REL_ID
release() {
  "$DART" "$GEN_KERNEL" --platform "$PLAT" --aot --packages .dart_tool/package_config.json --dynamic-interface "$2" -o "base_$1.dill" "$URI" >/dev/null
  "$OUT/gen_snapshot" --patchable_static_calls ${3:-} --snapshot_kind=app-aot-elf --elf="app_$1.aot" "base_$1.dill" >/dev/null
  REL_ID=$("$OUT/dartaotruntime" "app_$1.aot" | sed -n 's/^BUILD_ID //p')
  [ -n "$REL_ID" ] || { echo "ERROR: release $1 printed no BUILD_ID"; exit 1; }
}
mkdir -p man
cat > man/pack.dart <<'DART'
import 'dart:io';
import 'package:shorebird_cli/src/route_b_container.dart';
void main(List<String> a) {
  File(a[2]).writeAsBytesSync(writeRouteBContainer(releaseBuildId: a[0], targets: [
    RouteBPatchTarget(library: 'package:dynamic_modules/container_target.dart', selector: 'RbBox.show', bytecode: File(a[1]).readAsBytesSync()),
  ]));
}
DART
# replace <arm> <replacement source> -> man/<arm>.sbrbptch is made per release below
compile() { # <arm> <source text>
  printf '%s\n' "import 'package:dynamic_modules/container_target.dart';" "$2" > "man/$1.dart"
  "$WORK/cell/dartaotruntime" "$WORK/cell/dart2bytecode.aot" --platform "$PLAT" --import-dill import.dill \
    --packages .dart_tool/package_config.json -o "man/$1.bytecode" "man/$1.dart" >"man/$1.compile.log" 2>&1 \
    || { echo "  ! replacement did not compile"; sed 's/^/  ! /' "man/$1.compile.log" | head; return 1; }
}
# run <arm> <release tag> <expect> -- expect is `box=<value>` or `abort`
# Records PASS when the observed outcome is the expected one.
run() {
  local arm=$1 rel=$2 expect=$3 name=$1_$2
  "$DART" --packages="$CLI_PKGS" man/pack.dart "$REL_ID" "man/$arm.bytecode" "man/$name.sbrbptch"
  set +e
  "$OUT/dartaotruntime" "app_$rel.aot" "man/$name.sbrbptch" > "man/$name.log" 2>&1
  local rc=$?
  set -e
  grep -E '^(APPLY|before|after)|Unable|rror|FATAL|unreachable' "man/$name.log" | cut -c1-240 | sed 's/^/    /'
  echo "    exit $rc"
  local got
  if [ "$expect" = abort ]; then
    if [ $rc -ne 0 ] && grep -q 'unreachable code' "man/$name.log"; then record "$name" PASS
    else record "$name" "FAIL (wanted abort 'unreachable code', exit $rc)"; fi
  else
    got=$(sed -n 's/^after .*box=\([^ ]*\).*/\1/p' "man/$name.log")
    if [ $rc -eq 0 ] && [ "$got" = "${expect#box=}" ]; then record "$name" PASS
    else record "$name" "FAIL (exit $rc, got box=${got:-none}, want ${expect#box=})"; fi
  fi
}

echo; echo "== releases"
release plain_t di_plain.yaml "";                          ID_PT=$REL_ID
release plain_u di_plain.yaml "--route_b_untabled_overrides"; ID_PU=$REL_ID
release ext_t   di_ext.yaml   "";                          ID_ET=$REL_ID
release ext_u   di_ext.yaml   "--route_b_untabled_overrides"; ID_EU=$REL_ID
echo "  built 4 releases (plain/ext x tabled/untabled)"
# $REL_ID is read by run(); set it per release.
use() { REL_ID=$1; }

# ---- plain: a private class extending Object, a field, a const constructor.
if want plain; then
  echo; echo "==> plain (class _Pt extends Object, field x, const constructor)"
  compile plain "
class _Pt {
  final int x;
  const _Pt(this.x);
  String s() => 'PT\$x';
}
@pragma('dyn-module:entry-point')
@pragma('vm:never-inline')
String show(RbBox self) => _Pt(7).s();" && {
    use "$ID_PT"; run plain plain_t box=PT7
    use "$ID_PU"; run plain plain_u box=PT7
  }
fi

# ---- ext / noext: a module class extending an AOT class.
SUBCLASS="
class RbFresh extends RbBase {
  String f = 'FLD';
  @override
  String name() => f;
}
@pragma('dyn-module:entry-point')
@pragma('vm:never-inline')
String show(RbBox self) => viaBase(RbFresh());"
if want 'ext|noext'; then
  echo; echo "==> RbFresh extends RbBase (a field, one override)"
  compile ext "$SUBCLASS" && {
    use "$ID_ET"; run ext ext_t box=FLD
    use "$ID_EU"; run ext ext_u box=FLD
    # Without extendable/can-be-overridden. The known failures:
    use "$ID_PT"; run ext plain_t abort
    use "$ID_PU"; run ext plain_u box=B2
  }
fi

# ---- identity of two equal const instances of a module class.
if want ident; then
  echo; echo "==> ident (const _Pt(1) twice: one function; two module functions)"
  compile ident "
class _Pt {
  final int x;
  const _Pt(this.x);
}
_Pt _a() => const _Pt(1);
_Pt _b() => const _Pt(1);
@pragma('dyn-module:entry-point')
@pragma('vm:never-inline')
String show(RbBox self) =>
    'same=\${const _Pt(1) == const _Pt(1)},across=\${_a() == _b()},diff=\${const _Pt(1) == const _Pt(2)}';" && {
    use "$ID_PT"; run ident plain_t box=same=true,across=true,diff=false
    use "$ID_PU"; run ident plain_u box=same=true,across=true,diff=false
  }
fi

echo; echo "== SUMMARY"
for r in "${RESULTS[@]}"; do printf '  %-34s %s\n' "${r%%|*}" "${r#*|}"; done
[ "$FAILS" -eq 0 ] && echo "ALL PASS" || { echo "$FAILS FAILED"; exit 1; }
