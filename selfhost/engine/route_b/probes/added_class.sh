#!/usr/bin/env bash
# cspell:words dartaotruntime prepass sbrbptch untabled noext SDKM rror FPLAT fgen frel Widgett nomember
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
#                  (an absence check; it does not compare against the old generator)
#   flag_on        with it, both sections, naming RbBase
#   fl_*           the same questions against REAL Flutter classes (StatelessWidget,
#                  StatefulWidget, State), against the Flutter platform dill. What
#                  this can and cannot show is stated at the arms below: the host
#                  has no runtime that runs a Flutter-platform AOT snapshot, so
#                  these arms build and compile but do not run the module
#
# Host, not device. Do not run against a device.
#
#   OUT=$HOME/shorebird-engine/flutter/engine/src/out/host_release_arm64_ddm \
#   CLI_PKGS=<package_config.json that resolves package:shorebird_cli> \
#     added_class.sh <route_b dir> <cell zip, with dart2bytecode.aot>
set -euo pipefail
SRC=${SRC:-$HOME/shorebird-engine/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64_ddm}
[ $# -eq 2 ] || { echo "usage: added_class.sh <route_b dir> <cell zip>" >&2; exit 2; }
# Absolute BEFORE any cd: both are used after `cd "$WORK"`.
RB=$(cd "$1" && pwd)
CELL=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
[ -f "$CELL" ] || { echo "ERROR: no cell zip at $2" >&2; exit 2; }
REPO=$(cd "$RB/../../.." && pwd)
WORK=${WORK:-$REPO/../tmp/added_class_work}
# rm -rf only a directory this script made: a caller-supplied WORK (say $HOME or
# `.`) must not be emptied. The sentinel is written after the first mkdir.
if [ -e "$WORK" ]; then
  [ -f "$WORK/.added_class_probe" ] || { echo "ERROR: $WORK exists and is not a directory this probe made (no .added_class_probe); remove it or pick another WORK" >&2; exit 2; }
  rm -rf "$WORK"
fi
mkdir -p "$WORK/lib" "$WORK/.dart_tool" "$WORK/cell"
WORK=$(cd "$WORK" && pwd)
touch "$WORK/.added_class_probe"
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
  "$DART" "$KERNEL_PKGS" "$RB/gen_dynamic_interface.dart" --dill prepass.dill --private-dill import.dill --policy p2 \
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
# compile <arm> <source text> [platform dill] [import dill] [packages] [target]
compile() {
  printf '%s\n' "import 'package:dynamic_modules/container_target.dart';" "$2" > "man/$1.dart"
  "$WORK/cell/dartaotruntime" "$WORK/cell/dart2bytecode.aot" --platform "${3:-$PLAT}" ${6:+--target "$6"} --import-dill "${4:-import.dill}" \
    --packages "${5:-.dart_tool/package_config.json}" -o "man/$1.bytecode" "man/$1.dart" >"man/$1.compile.log" 2>&1 \
    || { echo "  ! replacement did not compile"; sed 's/^/  ! /' "man/$1.compile.log" | head; record "$1_compile" "FAIL (replacement did not compile)"; return 1; }
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
    if [ $rc -eq 134 ] && grep -q 'object.cc: 24128: error: unreachable code' "man/$name.log"; then record "$name" PASS
    else record "$name" "FAIL (wanted exit 134 and object.cc:24128 unreachable code, got exit $rc)"; fi
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

# ---------------------------------------------------------------------------
# fl_*: REAL Flutter classes. A module declares `class MW extends StatelessWidget
# { const MW({super.key}); build => SizedBox }` and a StatefulWidget + State,
# against the Flutter platform dill.
#
# WHAT THIS EXERCISES: the generator's --extendable on the real framework
# classes (and its refusals); the dynamic-interface annotator and gen_kernel
# --tfa accepting the interface; gen_snapshot building the release; the cell's
# dart2bytecode compiling the module classes (super.key, build, createState).
#
# WHAT IT DOES NOT: it never runs the module. The host has no runtime that runs
# a Flutter-platform AOT snapshot: dartaotruntime needs dart:_builtin, which the
# Flutter platform lacks (fl_no_host_runtime records the abort), and an engine or
# device is out of scope. So whether `super.key` (a call to StatelessWidget's
# constructor) and `build` dispatch work at run time with and without
# `extendable` is NOT shown by these arms; the toy RbBase arms are the only
# run-time evidence. Set SKIP_FLUTTER=1 to skip (EXPECTED_RESULTS drops to 10).
if [ "${SKIP_FLUTTER:-0}" != 1 ] && want fl_; then
  echo; echo "==> fl_* (real Flutter classes; build and compile only, nothing runs)"
  command -v flutter >/dev/null || { echo "ERROR: flutter not on PATH (SKIP_FLUTTER=1 to skip)"; exit 1; }
  FPLAT=$OUT/flutter_patched_sdk/platform_strong.dill
  [ -f "$FPLAT" ] || { echo "ERROR: no $FPLAT"; exit 1; }
  FW=package:flutter/src/widgets/framework.dart
  FD=$WORK/fl; mkdir -p "$FD/lib" "$FD/man"
  cd "$FD"
  cat > pubspec.yaml <<'YAML'
name: dynamic_modules
publish_to: none
environment:
  sdk: ">=3.6.0 <4.0.0"
dependencies:
  flutter:
    sdk: flutter
  crypto: any
YAML
  flutter pub get --offline > pubget.log 2>&1 || { tail -5 pubget.log; echo "ERROR: flutter pub get --offline failed"; exit 1; }
  cp "$RB/packaging/container_target.dart" lib/container_target.dart
  python3 - lib/container_target.dart <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace("import 'dart:io';", "import 'dart:io';\nimport 'package:flutter/widgets.dart';", 1)
s += """
class RbBox {
  String tag = 'BOX';
  @pragma('vm:never-inline')
  String show() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-box' : 'X';
}
class _RbCtx implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation i) => null;
}
BuildContext rbCtx() => _RbCtx();
class RbW extends StatelessWidget {
  const RbW({super.key});
  @override
  Widget build(BuildContext c) => const SizedBox();
}
class RbSW extends StatefulWidget {
  const RbSW({super.key});
  @override
  State<RbSW> createState() => _RbS();
}
class _RbS extends State<RbSW> {
  @override
  Widget build(BuildContext c) => const SizedBox();
}
"""
old = "void _state(String when) => print('$when alpha=${alpha()} beta=${beta()}');"
assert old in s
s = s.replace(old, "void _state(String when) => print('$when alpha=${alpha()} beta=${beta()} box=${RbBox().show()} fw=${RbW().build(rbCtx()).runtimeType},${RbSW().createState().build(rbCtx()).runtimeType}');")
p.write_text(s)
PY
  FK=(--platform "$FPLAT" --target flutter --packages .dart_tool/package_config.json)
  "$DART" "$GEN_KERNEL" "${FK[@]}" --aot --tfa -o prepass.dill "$URI" >fk1.log 2>&1 || { head -5 fk1.log; echo "ERROR: flutter prepass kernel"; exit 1; }
  "$DART" "$GEN_KERNEL" "${FK[@]}" --no-aot --no-link-platform -o import.dill "$URI" >fk2.log 2>&1 || { head -5 fk2.log; echo "ERROR: flutter non-AOT kernel"; exit 1; }
  fgen() { # <out yaml> [flags]  -> exit status of the generator
    local o=$1; shift
    "$DART" "$KERNEL_PKGS" "$RB/gen_dynamic_interface.dart" --dill prepass.dill --private-dill import.dill --platform "$FPLAT" \
      --include package:dynamic_modules/ --policy p2 --out "$o" --manifest "$o.manifest.json" --sdk-members "$SDKM" "$@" >"$o.log" 2>&1
  }
  EXT3=(--extendable "$FW#StatelessWidget" --extendable "$FW#StatefulWidget" --extendable "$FW#State")
  if fgen di_plain.yaml && ! grep -qE '^(extendable|can-be-overridden):' di_plain.yaml; then record fl_iface_plain PASS; else record fl_iface_plain FAIL; fi
  if fgen di_ext.yaml "${EXT3[@]}" && grep -q "class: \['State', 'StatefulWidget', 'StatelessWidget'\]" di_ext.yaml \
     && python3 -c "
import json
m=json.load(open('di_ext.yaml.manifest.json'))
assert m['counts']['extendable']==3 and m['counts']['canBeOverridden']==3, m['counts']
assert {e['class'] for e in m['extendable']}=={'State','StatefulWidget','StatelessWidget'}"; then
    record fl_iface_ext PASS; else record fl_iface_ext "FAIL (sections or manifest entries missing)"; fi
  # Refusals: a typo'd class, a member the class does not declare, an inherited member.
  rc1=0; fgen di_typo.yaml --extendable "$FW#StatelessWidgett" || rc1=$?
  rc2=0; fgen di_nomember.yaml --extendable "$FW#StatelessWidget.nope" || rc2=$?
  rc3=0; fgen di_inherited.yaml --extendable "$FW#StatelessWidget.key" || rc3=$?
  if [ "$rc1" = 2 ] && [ ! -e di_typo.yaml ] && grep -q 'no class StatelessWidgett' di_typo.yaml.log; then record fl_refuse_class PASS; else record fl_refuse_class "FAIL (exit $rc1)"; fi
  if [ "$rc2" = 2 ] && [ "$rc3" = 2 ] && grep -q "declares no public instance member 'nope'" di_nomember.yaml.log && grep -q "'key'" di_inherited.yaml.log; then record fl_refuse_member PASS; else record fl_refuse_member "FAIL (exit $rc2/$rc3)"; fi

  frel() { # <name> <di>
    "$DART" "$GEN_KERNEL" "${FK[@]}" --aot --tfa --dynamic-interface "$2" -o "base_$1.dill" "$URI" >"base_$1.log" 2>&1 || return 1
    "$OUT/gen_snapshot" --deterministic --patchable_static_calls --print_instructions_sizes_to="sizes_$1.json" \
      --snapshot_kind=app-aot-elf --elf="app_$1.aot" "base_$1.dill" >/dev/null 2>&1
  }
  if frel plain di_plain.yaml && frel ext di_ext.yaml; then
    record fl_release PASS
    echo "    snapshot bytes: plain $(wc -c < app_plain.aot | tr -d ' ')  ext $(wc -c < app_ext.aot | tr -d ' ')"
    python3 - <<'PY'
import json
for v in ('plain', 'ext'):
    d = json.load(open('sizes_%s.json' % v))
    ours = {'RbW', 'RbSW', '_RbS'}
    fw = sorted(e['n'].replace('[Optimized] ', '') for e in d
                if e.get('c') in ('StatelessWidget', 'StatefulWidget', 'State'))
    mine = sorted(e['n'].replace('[Optimized] ', '') for e in d if e.get('c') in ours)
    print('    %-5s functions of StatelessWidget/StatefulWidget/State in the snapshot: %s' % (v, fw or 'none'))
    print('    %-5s functions of the release widgets RbW/RbSW/_RbS: %s' % (v, mine))
PY
  else record fl_release "FAIL (a release build was refused)"; head -5 base_plain.log base_ext.log 2>/dev/null | sed 's/^/    /'; fi

  compile fl_mod "
import 'package:flutter/widgets.dart';
class MW extends StatelessWidget {
  const MW({super.key});
  @override
  Widget build(BuildContext c) => const SizedBox();
}
class MSW extends StatefulWidget {
  const MSW({super.key});
  @override
  State<MSW> createState() => _MS();
}
class _MS extends State<MSW> {
  int n = 3;
  @override
  Widget build(BuildContext c) => const SizedBox();
}
@pragma('dyn-module:entry-point')
@pragma('vm:never-inline')
String show(RbBox self) => '\${MW().build(rbCtx()).runtimeType},\${MSW().createState().build(rbCtx()).runtimeType}';" \
    "$WORK/cell/flutter_platform_strong.dill" import.dill .dart_tool/package_config.json flutter && record fl_module_compile PASS

  # The host cannot run it: record the abort that proves it.
  set +e; "$OUT/dartaotruntime" app_ext.aot > host_run.log 2>&1; frc=$?; set -e
  if [ $frc -ne 0 ] && grep -q "library 'dart:_builtin' not found" host_run.log; then
    record fl_no_host_runtime PASS
  else record fl_no_host_runtime "FAIL (the Flutter snapshot ran or failed otherwise, exit $frc)"; fi
  cd "$WORK"
fi

if [ "${SKIP_FLUTTER:-0}" = 1 ]; then EXPECTED=${EXPECTED_RESULTS:-10}; else EXPECTED=${EXPECTED_RESULTS:-17}; fi
[ -n "${ONLY:-}" ] || [ "${#RESULTS[@]}" -eq "$EXPECTED" ] || { echo "FAIL: ${#RESULTS[@]} results recorded, expected $EXPECTED (an arm did not run)"; FAILS=$((FAILS+1)); }

echo; echo "== SUMMARY"
for r in ${RESULTS[@]+"${RESULTS[@]}"}; do printf '  %-34s %s\n' "${r%%|*}" "${r#*|}"; done
[ "$FAILS" -eq 0 ] && echo "ALL PASS" || { echo "$FAILS FAILED"; exit 1; }
