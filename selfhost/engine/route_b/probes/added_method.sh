#!/usr/bin/env bash
# cspell:words dartaotruntime prepass sbrbptch KIDBODY NEWDUP
#
# added_method.sh -- a Route B patch may ADD an instance METHOD to an existing
# class, called from a replaced instance method of the same class (analysis
# version 17, "rung 2" of a patch that may add code).
#
# The shape: a Flutter `State` gains `Widget _buildHeader() => Text(title);` and
# the patched `build` calls `_buildHeader()`. The release has no such method, so
# the producer ships it with the replacement as a top-level function taking the
# receiver first, lowered exactly as an instance target is, and rewrites each
# call `_m(a)` / `this._m(a)` to `_m(self, a)`.
#
# Drives the CLI's own analyzer and producer over REAL patched source, with a
# release built under --policy p2 so a release-private field can be granted by
# a capability manifest, and runs the container on a runtime that attaches.
#
# Arms (class RbBox, target RbBox.show; each is one patched source):
#   m_private_method    show() calls a new private method that reads a field
#   m_args              ... a new method taking arguments
#   m_chain             ... a new method calling another new method
#   m_calls_existing    ... a new method calling an existing method of RbBox
#   m_explicit_this     ... `this._h()` and a helper reading `this.tag`
#   m_writes_field      ... a new method assigning a field
#   m_private_reads_private  a new private method reading a release-private
#                       field (needs the manifest grant)
#   st_*                a PRIVATE class (_RbState, the Flutter State shape) whose patched
#                       method calls a new private method / private top-level function
#                       while private names resolve against the release
#   refused_other_receiver, refused_tear_off, refused_overrides_super,
#   refused_overridden, refused_static, refused_getter, refused_top_level_clash,
#   refused_super_call, refused_subclass_call
#   refused_public_method, refused_public_unused  a new PUBLIC method (code
#                       outside the library, `jsonEncode`, calls `toJson` by
#                       name), used or not
#   refused_st_other_class_same_name  a new private method named like a private
#                       member of another class of the library
#   refused_local_shadow  a local named like the helper in a calling body
#   refused_st_v16_private_top  a version-16 document keeps rung 1's refusal of
#                       a private top-level helper under a private receiver
#   back_compat_v16     a version-16 analyzer still refuses a new instance method
#   back_compat_v15     the published (version-15) cell too
#
# Host, not device.
#
#   OUT=$HOME/shorebird-engine/flutter/engine/src/out/host_release_arm64_ddm \
#     added_method.sh <route_b dir> <cell zip, analysis 17> <cell zip, analysis 16> <cell zip, older>
set -euo pipefail
SRC=${SRC:-$HOME/shorebird-engine/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64_ddm}
HERE=$(cd "$(dirname "$0")" && pwd)
RB=$1
CELL_NEW=$2
CELL_16=$3
CELL_OLD=$4
REPO=$(cd "$RB/../../.." && pwd)
WORK=${WORK:-$REPO/../tmp/added_method_work}
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
python3 - lib/container_target.dart <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s += '''
// The classes under test. `show` is the method a patch replaces; `other` is an
// existing method a new method may call; `_secret` is a private field the
// release never reads (retained only because the manifest grants it).
class RbBox {
  String tag = 'BOX';
  String _secret = 'S3';
  @pragma('vm:never-inline')
  String show() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-box' : 'X';
  @pragma('vm:never-inline')
  String other() => 'OTH-' + tag;
}

class RbKid extends RbBox {
  @pragma('vm:never-inline')
  String kidOnly() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'K' : 'X';
}

// The Flutter shape: a PRIVATE class (a State) with a private field the release
// never reads, a patched method, and private top-level functions of the library.
class RbOther {
  @pragma('vm:never-inline')
  String _x() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OX' : 'X';
}

class _RbState {
  String _title = 'TTL';
  @pragma('vm:never-inline')
  String build() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-st' : 'X';
}

@pragma('vm:never-inline')
String _rbRel() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'REL' : 'X';

@pragma('vm:never-inline')
String _rbDup() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'DUP' : 'X';

@pragma('vm:never-inline')
String rbClash() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'T' : 'X';
'''
old = "void _state(String when) => print('$when alpha=${alpha()} beta=${beta()}');"
assert old in s
s = s.replace(old, "void _state(String when) => print('$when alpha=${alpha()} beta=${beta()} box=${RbBox().show()} oth=${RbBox().other()} kid=${RbKid().kidOnly()} clash=${rbClash()} st=${_RbState().build()} rel=${_rbRel()} dup=${_rbDup()} ox=${RbOther()._x()}');")
p.write_text(s)
PY
"$DART" "$GEN_KERNEL" --platform "$PLAT" --aot --packages .dart_tool/package_config.json -o prepass.dill "$URI" >/dev/null
# The non-AOT kernel supplies the PRIVATE half: the prepass is tree-shaken, so a
# private field the release never reads is gone from it.
"$DART" "$GEN_KERNEL" --platform "$PLAT" --no-aot --no-link-platform --packages .dart_tool/package_config.json -o import.dill "$URI" >/dev/null
"$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill prepass.dill --private-dill import.dill --policy p2 --out di.yaml --manifest manifest.json --sdk-members \
  'dart:core#print,dart:core#DateTime.now,dart:core#DateTime.get:millisecondsSinceEpoch' 2>&1 | sed 's/^/  /'
"$DART" "$GEN_KERNEL" --platform "$PLAT" --aot --packages .dart_tool/package_config.json --dynamic-interface di.yaml -o base.dill "$URI" >/dev/null
"$OUT/gen_snapshot" --patchable_static_calls --snapshot_kind=app-aot-elf --elf=app.aot base.dill
BUILD_ID=$("$OUT/dartaotruntime" app.aot | sed -n 's/^BUILD_ID //p')
echo "release $BUILD_ID"
python3 -c "
import json
m=json.load(open('manifest.json'))
k='$URI#RbBox#_secret'
print('manifest grants RbBox._secret:', k in m['privateInstanceCallable'])
assert k in m['privateInstanceCallable']"
cp lib/container_target.dart release_source.dart

FAILS=0
RESULTS=()
drive() { # <cell> <outdir>
  set +e
  "$DART" --packages="$CLI_PKGS" "$HERE/cli_lower.dart" "$1" base.dill patched.dill import.dill "$BUILD_ID" "$2/cli" "$WORK" "$PLAT" "$ENGINE" "$WORK/manifest.json" > "$2/cli.log" 2>&1
  CLI_EXIT=$?
  set -e
}
# ONLY=<regex> runs just the arms whose label matches.
want() { [ -z "${ONLY:-}" ] || [[ $1 =~ $ONLY ]]; }
record() { RESULTS+=("$1|$2"); echo "  RESULT $1: $2"; [ "$2" = PASS ] || FAILS=$((FAILS+1)); }

# patch <show body> <members for RbBox> <members for RbKid> <top-level text> <kid body or empty>
patch() {
  cp release_source.dart lib/container_target.dart
  SHOW="$1" BOX="${2:-}" KID="${3:-}" TOP="${4:-}" KIDBODY="${5:-}" python3 - lib/container_target.dart <<'PY'
import os, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
def sub(old, new):
    global s
    assert old in s, old
    s = s.replace(old, new, 1)
sub("  String show() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-box' : 'X';",
    "  String show() => %s;\n%s" % (os.environ['SHOW'], os.environ['BOX']))
if os.environ['KID']:
    sub("class RbKid extends RbBox {\n", "class RbKid extends RbBox {\n" + os.environ['KID'] + "\n")
if os.environ['KIDBODY']:
    sub("  String kidOnly() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'K' : 'X';",
        "  String kidOnly() => %s;" % os.environ['KIDBODY'])
s += "\n" + os.environ['TOP'] + "\n"
p.write_text(s)
PY
  "$DART" "$GEN_KERNEL" --platform "$PLAT" --aot --packages .dart_tool/package_config.json --dynamic-interface di.yaml -o patched.dill "$URI" >"$d/gen_kernel.log" 2>&1 \
    || { echo "  ! patched source did not compile"; sed 's/^/  ! /' "$d/gen_kernel.log" | head; return 1; }
}

show_cli() {
  grep -E '^(coverage|helpers|unused|REFUSED|REJECT|container)|^ +(new member|a patch)|UNSUPPORTED|^           ' "$d/cli.log" | sed 's/^/  /' || true
  for f in "$d"/cli/replacement_*.dart; do
    [ -f "$f" ] && sed 's/^/  | /' "$f" | sed -n '/entry-point/,$p'
  done
}

# patch_st <build body> <members for _RbState> <top-level text>
patch_st() {
  cp release_source.dart lib/container_target.dart
  SHOW="$1" BOX="${2:-}" TOP="${3:-}" python3 - lib/container_target.dart <<'PY'
import os, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = "  String build() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-st' : 'X';"
assert old in s
s = s.replace(old, "  String build() => %s;\n%s" % (os.environ['SHOW'], os.environ['BOX']))
s += "\n" + os.environ['TOP'] + "\n"
p.write_text(s)
PY
  "$DART" "$GEN_KERNEL" --platform "$PLAT" --aot --packages .dart_tool/package_config.json --dynamic-interface di.yaml -o patched.dill "$URI" >"$d/gen_kernel.log" 2>&1 \
    || { echo "  ! patched source did not compile"; sed 's/^/  ! /' "$d/gen_kernel.log" | head; return 1; }
}

# arm_st <label> <want st> <build body> <members> <top-level>
arm_st() {
  local label=$1 want=$2
  want "$label" || return 0
  d=$WORK/$label; mkdir -p "$d"
  echo; echo "==> $label"
  patch_st "$3" "${4:-}" "${5:-}" || { record "$label" "FAIL (harness)"; return; }
  drive "$CELL_NEW" "$d"
  show_cli
  local c; c=$(sed -n 's/^OUT=//p' "$d/cli.log")
  if [ -z "$c" ]; then tail -12 "$d/cli.log" | sed 's/^/  ! /'; record "$label" "FAIL (no container)"; return; fi
  "$OUT/dartaotruntime" app.aot "$c" > "$d/run.log" 2>&1 || true
  grep -E '^(APPLY|after)|ATTACH: C\+\+|Error' "$d/run.log" | sed 's/^/  /'
  local got; got=$(sed -n 's/^after .* st=\([^ ]*\).*/\1/p' "$d/run.log")
  if [ "$got" = "$want" ]; then record "$label" PASS; else record "$label" "FAIL got st=${got:-none} want $want"; fi
}

# refused_st <label> <phrase> <build body> <members> <top-level> [<cell>]
refused_st() {
  local label=$1 phrase=$2
  want "$label" || return 0
  d=$WORK/$label; mkdir -p "$d"
  echo; echo "==> $label"
  patch_st "$3" "${4:-}" "${5:-}" || { record "$label" "FAIL (harness)"; return; }
  drive "${6:-$CELL_NEW}" "$d"
  grep -E '^(coverage|REFUSED|REJECT|container)|^ +(new member|a patch)|^           ' "$d/cli.log" | sed 's/^/  /' || true
  if [ "$CLI_EXIT" -ne 0 ] && ! grep -q '^OUT=' "$d/cli.log" && grep -qF -- "$phrase" "$d/cli.log"; then
    record "$label" PASS
  else record "$label" "FAIL (exit $CLI_EXIT, wanted a refusal containing: $phrase)"; tail -8 "$d/cli.log" | sed 's/^/  ! /'; fi
}

# arm <label> <cell> <want box> <show> <box members> [<kid members> <top> <kid body>]
arm() {
  local label=$1 cell=$2 want=$3
  want "$label" || return 0
  d=$WORK/$label; mkdir -p "$d"
  echo; echo "==> $label"
  patch "$4" "${5:-}" "${6:-}" "${7:-}" "${8:-}" || { record "$label" "FAIL (harness)"; return; }
  drive "$cell" "$d"
  show_cli
  local c; c=$(sed -n 's/^OUT=//p' "$d/cli.log")
  if [ -z "$c" ]; then tail -12 "$d/cli.log" | sed 's/^/  ! /'; record "$label" "FAIL (no container)"; return; fi
  "$OUT/dartaotruntime" app.aot "$c" > "$d/run.log" 2>&1 || true
  grep -E '^(APPLY|after)' "$d/run.log" | sed 's/^/  /'
  local got; got=$(sed -n 's/^after .*box=\([^ ]*\).*/\1/p' "$d/run.log")
  if [ "$got" = "$want" ]; then record "$label" PASS; else record "$label" "FAIL got box=${got:-none} want $want"; fi
}

# refused <label> <cell> <phrase> <show> <box members> [<kid members> <top> <kid body>]
refused() {
  local label=$1 cell=$2 phrase=$3
  want "$label" || return 0
  d=$WORK/$label; mkdir -p "$d"
  echo; echo "==> $label"
  patch "$4" "${5:-}" "${6:-}" "${7:-}" "${8:-}" || { record "$label" "FAIL (harness)"; return; }
  drive "$cell" "$d"
  grep -E '^(coverage|REFUSED|REJECT|container)|^ +(new member|a patch)|^           ' "$d/cli.log" | sed 's/^/  /' || true
  if [ "$CLI_EXIT" -ne 0 ] && ! grep -q '^OUT=' "$d/cli.log" && grep -qF -- "$phrase" "$d/cli.log"; then
    record "$label" PASS
  else record "$label" "FAIL (exit $CLI_EXIT, wanted a refusal containing: $phrase)"; tail -8 "$d/cli.log" | sed 's/^/  ! /'; fi
}

arm m_private_method "$CELL_NEW" P-BOX "_h()" "  String _h() => 'P-\$tag';"
arm m_args "$CELL_NEW" R "_pick('L', 'R', 1)" "  String _pick(String a, String b, int n) => n == 0 ? a : b;"
arm m_chain "$CELL_NEW" B! "_a()" "  String _a() => '\${_b()}!'; String _b() => 'B';"
arm m_calls_existing "$CELL_NEW" OTH-BOX+ "_viaOther()" "  String _viaOther() => '\${other()}+';"
arm m_explicit_this "$CELL_NEW" BOX "this._h()" "  String _h() => this.tag;"
arm m_writes_field "$CELL_NEW" BOX+ "_bump()" "  String _bump() { tag = '\${tag}+'; return tag; }"
arm m_private_reads_private "$CELL_NEW" S3 "_sec()" "  String _sec() => _secret;"

# THE FLUTTER CASE: a private class, so private names resolve against the
# release (--resolve-private-names-in-library). The private `_title` is granted
# by the manifest; the new private helper must still bind to its own copy.
arm_st st_private_method H-TTL "_rbHeader()" "  String _rbHeader() => 'H-\$_title';"
arm_st st_private_top T-TTL "_rbTop2(_title)" "" "String _rbTop2(String s) => 'T-\$s';"
refused_st refused_st_ungranted_in_method "private identifier this analysis did not resolve" "_rbHeader()" "  String _rbHeader() => _rbRel();"
refused_st refused_st_ungranted_in_top "not a new function this patch carries" "_rbTop3()" "" "String _rbTop3() => _rbRel();"
refused_st refused_st_dynamic_private_in_top "not a new function this patch carries" "_rbPeek(_title)" "" "String _rbPeek(dynamic d) => (d as dynamic)._title;"
refused_st refused_st_same_name_as_release_private "also used by" "_rbDup()" "  String _rbDup() => 'NEWDUP';"
refused_st refused_st_other_class_same_name "also used by" "_x()" "  String _x() => 'NX';"
refused_st refused_st_v16_private_top "names a private identifier" "_rbTop2(_title)" "" "String _rbTop2(String s) => 'T-\$s';" "$CELL_16"

refused refused_public_method "$CELL_NEW" "a PUBLIC method" "toJson()" "  String toJson() => 'J';"
refused refused_public_unused "$CELL_NEW" "a PUBLIC method" "'X1'" "  String toJson() => 'J';"
refused refused_local_shadow "$CELL_NEW" "would capture" "(() { final _h = 1; return '\${this._h()}\$_h'; })()" "  String _h() => 'H';"
refused refused_other_receiver "$CELL_NEW" "another receiver" "RbBox()._h()" "  String _h() => 'H';"
refused refused_tear_off "$CELL_NEW" "torn off" "(() { final f = _h; return f(); })()" "  String _h() => 'H';"
refused refused_overrides_super "$CELL_NEW" "overriding or overridden" "'X1'" "" "  @override String other() => 'KID';"
refused refused_overridden "$CELL_NEW" "overriding or overridden" "kidOnly()" "  String kidOnly() => 'B';"
refused refused_static "$CELL_NEW" "static member" "_s()" "  static String _s() => 'S';"
refused refused_getter "$CELL_NEW" "instance getter" "_g" "  String get _g => 'G';"
refused refused_top_level_clash "$CELL_NEW" "also used by" "_rbRel()" "  String _rbRel() => 'M';"
refused refused_super_call "$CELL_NEW" "through \`super\`" "_h()" "  String _h() => 'H';" "" "" "super._h()"
refused refused_subclass_call "$CELL_NEW" "outside an instance method" "_h()" "  String _h() => 'H';" "" "" "_h()"
refused back_compat_v16 "$CELL_16" "instance member" "_h()" "  String _h() => 'H';"
refused back_compat_v15 "$CELL_OLD" "cannot introduce members" "_h()" "  String _h() => 'H';"

echo; echo "== SUMMARY"
for r in "${RESULTS[@]}"; do printf '  %-34s %s\n' "${r%%|*}" "${r#*|}"; done
[ "$FAILS" -eq 0 ] && echo "ALL PASS" || { echo "$FAILS FAILED"; exit 1; }
