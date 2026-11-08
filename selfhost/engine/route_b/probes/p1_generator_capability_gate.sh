#!/usr/bin/env bash
# cspell:words dartaotruntime prepass ungranted redirecting sbrb
#
# p1_generator_capability_gate.sh -- does the interface the REAL generator emits
# carry the intended authority, and only that?
#
# The two sibling probes worked on interfaces this repo post-processed by hand:
# they established the MECHANISM (`p1_dead_allocatability.sh`) and its PRICE
# (`p1_retention_price.sh`). Neither ran `gen_dynamic_interface.dart` itself. This
# one does, and it is the gate that would catch the generator regressing.
#
# THE POLICY UNDER TEST, decided on that evidence:
#
#     class identity  !=  member invocation  !=  construction authority
#
# A private class is represented by EXACT MEMBER GRANTS -- including the public
# methods a patch may target, which used to arrive free inside a bare `class:`
# item along with construction. Construction is granted one constructor at a
# time, via `--grant-constructor`, and never by default.
#
# PRECOMMIT -- fixed before running.
#
#   INTERFACE, negative (default emission)
#     G1a  no bare private `class:` item                    count == 0
#     G1b  no unnamed-constructor grant (`member: ''`)       count == 0
#     G1c  no private named constructor (`_mk`) granted      absent
#     G1d  no factory (`made`) granted                       absent
#   INTERFACE, positive (default emission)
#     G2a  the patch TARGET (`build`, public method of a private class) granted
#     G2b  private field `_count` granted, named BARE
#     G2c  private getter granted as `get:_value`
#     G2d  private method `_helper` granted
#   MANIFEST
#     G3a  implicitlyConstructible is EMPTY
#     G3b  privateClassesConstructible == the explicit grants (none by default)
#     G3c  constructionWithheld names `_Dead.new`, `_Dead._mk`, `_Dead.made`
#   END TO END
#     G4   patch `_FooState.build` reading all three privates      PASS
#     G5   patch constructing `_Dead()`                            REFUSE
#     G6   same patch, after --grant-constructor '..._Dead.new'    PASS
#     G6b  and that interface has exactly ONE `member: ''`, on _Dead
#
#   STOP/INVALID rows, scored as "no result":
#     * G4 does not PASS -- then the emission is not usable and every negative
#       below it is uninformative
#     * the fixture's constructor identities do not come back from
#       `dump_private_members.dart` (a name cannot say whether `_mk` is a
#       constructor or a method, so the kernel is asked)
#
# Host only. No device, no mint, no cell.
#
#   probes/p1_generator_capability_gate.sh
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
RB="$(cd "$HERE/.." >/dev/null 2>&1 && pwd)"
WORK=${WORK:-$(mktemp -d)}

DART_TREE=$SRC/flutter/third_party/dart
DART=$OUT/dart-sdk/bin/dart
KERNEL_PKGS="--packages=$DART_TREE/.dart_tool/package_config.json"
GEN_KERNEL=$DART_TREE/pkg/vm/bin/gen_kernel.dart
DART2BC=$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart
GEN_SNAPSHOT=$OUT/gen_snapshot
AOT_RUNTIME=$OUT/dartaotruntime
PKGS_DIR=$DART_TREE/third_party/pkg/core/pkgs

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }
pass=0; fail=0; invalid=0
check() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1));
  else echo "  FAIL  $1"; echo "        got : $2"; echo "        want: $3"
    fail=$((fail+1)); fi; }
invalidate() { echo "  INVALID  $1"; invalid=$((invalid+1)); }

[ -x "$DART" ] || die "no host dart at $DART"
echo "work: $WORK"
mkdir -p "$WORK/lib" "$WORK/.dart_tool"

cp "$RB/packaging/container_target.dart" "$WORK/lib/container_target.dart"
python3 - "$WORK/lib/container_target.dart" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace(
    "void _state(String when) =>",
    """// The idiomatic Flutter shape: a private State class whose PUBLIC method is
// the patch target, with private members the replacement body consumes.
class _FooState {
  final String _count =
      DateTime.now().millisecondsSinceEpoch >= 0 ? '1' : 'X';

  String get _value =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'v' : 'X';

  @pragma('vm:never-inline')
  String _helper() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'h' : 'X';

  @pragma('vm:never-inline')
  String build() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD' : 'X';
}

final _foo = _FooState();

// Never constructed by the release: every constructor below is granted or not
// purely as a function of the interface.
class _Dead {
  final String tag;
  _Dead() : tag = 'CTOR';
  _Dead._mk() : tag = 'NAMED';
  factory _Dead.made() => _Dead._mk();
}

_Dead? _slot;

@pragma('vm:never-inline')
String _slotState() => _slot == null ? 'empty' : 'full';

void _state(String when) =>""",
    1,
)
s = s.replace(
    "print('$when alpha=${alpha()} beta=${beta()}');",
    "print('$when alpha=${alpha()} beta=${beta()} "
    "foo=${_foo.build()} slot=${_slotState()}');",
    1,
)
p.write_text(s)
PY

cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$WORK/", "packageUri": "lib/",
    "languageVersion": "3.9" },
  { "name": "crypto", "rootUri": "file://$PKGS_DIR/crypto", "packageUri": "lib/",
    "languageVersion": "3.4" },
  { "name": "typed_data", "rootUri": "file://$PKGS_DIR/typed_data",
    "packageUri": "lib/", "languageVersion": "3.4" } ] }
JSON
URI=package:dynamic_modules/container_target.dart
SDK='dart:core#print,dart:core#DateTime.now,dart:core#DateTime.get:millisecondsSinceEpoch'
cd "$WORK"

note "kernels, then the REAL generator (no hand-editing of the interface)"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o prepass.dill "$URI" >/dev/null
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot \
  --no-link-platform --packages .dart_tool/package_config.json \
  -o import.dill "$URI" >/dev/null
# shellcheck disable=SC2086
"$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill prepass.dill \
  --private-dill import.dill --policy p2 --out di.yaml --manifest m.json \
  --sdk-members "$SDK" 2>&1 | sed -n 's/^/    /p'
# shellcheck disable=SC2086
"$DART" $KERNEL_PKGS "$RB/dump_private_members.dart" import.dill \
  package:dynamic_modules > members.txt

# The kernel's own word on which of _Dead's members are construction edges.
ctors=$(awk -F'|' '$2=="_Dead" && $3=="ctor" {print ($4==""?"new":$4)}' members.txt | sort | tr '\n' ' ')
echo "    _Dead construction edges, per the kernel: $ctors"
[ -n "$ctors" ] || invalidate "the kernel reported no constructors for _Dead"

note "G1/G2 -- what the emitted interface says"
bare=$(python3 - di.yaml <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
print(sum(1 for i, l in enumerate(lines)
          if re.match(r"\s*class: '_", l)
          and not re.match(r'\s*member:', lines[i + 1] if i + 1 < len(lines) else '')))
PY
)
check "G1a no bare private class item" "$bare" "0"
check "G1b no unnamed-constructor grant" \
  "$(grep -cE "^ +member: ''\$" di.yaml || true)" "0"
check "G1c no private named constructor granted" "$(grep -c "member: '_mk'" di.yaml || true)" "0"
check "G1d no factory granted" "$(grep -c "member: 'made'" di.yaml || true)" "0"

granted() { # <class> <member>
  python3 - di.yaml "$1" "$2" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
cls, mem = sys.argv[2], sys.argv[3]
found = 0
for i, l in enumerate(lines):
    if re.match(rf"\s*class: '{re.escape(cls)}'\s*$", l):
        nxt = lines[i + 1] if i + 1 < len(lines) else ''
        m = re.match(r"\s*member: '(.*)'\s*$", nxt)
        if m and m.group(1) == mem:
            found = 1
print(found)
PY
}
check "G2a the patch target build is granted" "$(granted _FooState build)" "1"
check "G2b private field _count granted, named bare" "$(granted _FooState _count)" "1"
check "G2c private getter granted as get:_value" "$(granted _FooState get:_value)" "1"
check "G2d private method _helper granted" "$(granted _FooState _helper)" "1"

note "G3 -- what the manifest says"
python3 - m.json > manifest_report.txt <<'PY'
import json
m = json.load(open('m.json'))
print(len(m['implicitlyConstructible']))
print(len(m['privateClassesConstructible']))
print(sum(1 for e in m['constructionWithheld'] if '#_Dead.' in e))
PY
# `mapfile` is bash 4; this rig's /bin/bash is 3.2.
implicit=$(sed -n 1p manifest_report.txt)
constructible=$(sed -n 2p manifest_report.txt)
withheld=$(sed -n 3p manifest_report.txt)
check "G3a implicitlyConstructible is empty" "$implicit" "0"
check "G3b privateClassesConstructible is empty by default" "$constructible" "0"
check "G3c constructionWithheld names all three _Dead edges" "$withheld" "3"

release() { # <yaml> <tag>
  "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
    --packages .dart_tool/package_config.json --dynamic-interface "$1" \
    -o "rel_$2.dill" "$URI" >/dev/null 2>&1 || die "$2: gen_kernel refused $1"
  "$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
    --elf="app_$2.aot" "rel_$2.dill"
  BUILD_ID=$("$AOT_RUNTIME" "app_$2.aot" | sed -n 's/^BUILD_ID //p')
  [ -n "$BUILD_ID" ] || die "$2: no build id"
}

run_arm() { # <tag> <target> <probe field> <body>
  local tag=$1 target=$2 field=$3 body=$4
  cat > "repl_$tag.dart" <<EOF
import '$URI';

@pragma('dyn-module:entry-point')
$body
EOF
  set +e
  "$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" --import-dill import.dill \
    --resolve-private-names-in-library "$URI" \
    --packages .dart_tool/package_config.json \
    -o "repl_$tag.bytecode" "repl_$tag.dart" > "compile_$tag.log" 2>&1
  local crc=$?
  set -e
  if [ "$crc" -ne 0 ]; then ARM=COMPILE; return; fi
  "$DART" "$RB/packaging/pack_patch.dart" --release-build-id "$BUILD_ID" \
    --out "patch_$tag.sbrb" --target "$URI#$target=$WORK/repl_$tag.bytecode" \
    >/dev/null 2>&1
  set +e
  "$AOT_RUNTIME" "app_$tag.aot" "patch_$tag.sbrb" > "run_$tag.log" 2>&1
  set -e
  local got
  got=$(sed -n "s/^after  *.*$field=\\([^ ]*\\).*/\\1/p" "run_$tag.log" | tail -1)
  echo "      $(grep -m1 '^APPLY' "run_$tag.log" || echo 'APPLY <none>')"
  echo "      $field = ${got:-<no value>}"
  if grep -m1 -q 'refused' <<<"$(grep -m1 '^APPLY' "run_$tag.log" || true)"; then
    ARM=ATTACH
  elif [ -z "$got" ]; then
    ARM=BIND
    sed -n '/^APPLY/,$p' "run_$tag.log" | grep -m1 -iE "error|exception" \
      | sed 's/^/        /' || true
  elif [ "$got" = OLD ]; then ARM=SILENT-OLD
  else ARM=PASS; fi
}

note "G4 -- patch the private State's public method, consuming all three privates"
cp di.yaml di_G4.yaml; release di_G4.yaml G4
run_arm G4 "_FooState.build" foo \
  "String build(dynamic self) => 'NEW\${self._count}\${self._value}\${self._helper()}';"
check "G4 target attaches and reads privates" "$ARM" "PASS"
[ "$ARM" != PASS ] && invalidate "G4 is the STOP row: the default emission is not usable"

note "G5 -- the same release, a patch that CONSTRUCTS _Dead"
cp di.yaml di_G5.yaml; release di_G5.yaml G5
run_arm G5 alpha alpha "String alpha() { _Dead(); return 'NEW-CTOR'; }"
check "G5 construction is refused" "$([ "$ARM" = PASS ] && echo PASS || echo refused)" "refused"
echo "      refused at: $ARM"

note "G6 -- regenerate with an EXPLICIT grant for _Dead's unnamed constructor"
# shellcheck disable=SC2086
"$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill prepass.dill \
  --private-dill import.dill --policy p2 \
  --grant-constructor "$URI#_Dead.new" \
  --out di_G6.yaml --manifest m_G6.json --sdk-members "$SDK" 2>&1 \
  | sed -n 's/^/    /p'
check "G6b exactly one unnamed-constructor grant" \
  "$(grep -cE "^ +member: ''\$" di_G6.yaml || true)" "1"
check "G6c and the manifest records it" \
  "$(python3 -c "import json;print(len(json.load(open('m_G6.json'))['privateClassesConstructible']))")" "1"
release di_G6.yaml G6
run_arm G6 alpha alpha "String alpha() { _Dead(); return 'NEW-CTOR'; }"
check "G6 construction now succeeds" "$ARM" "PASS"

note "RESULT"
echo "  pass=$pass fail=$fail invalid=$invalid"
echo "  work dir kept: $WORK"
[ "$invalid" -gt 0 ] && { echo "  VERDICT: INVALID"; exit 3; }
[ "$fail" -gt 0 ] && { echo "  VERDICT: RED"; exit 1; }
echo "  VERDICT: GREEN -- identity, member invocation and construction are separate"
