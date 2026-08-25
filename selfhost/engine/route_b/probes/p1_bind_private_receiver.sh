#!/usr/bin/env bash
# cspell:words dartaotruntime prepass NONAOT ungranted sbrb
# cspell:words dispatchable devirtualize devirtualization
# cspell:words PUBH FLDF GETG MTHM
#
# p1_bind_private_receiver.sh -- P1 bind-time qualification for the IDIOMATIC
# FLUTTER SHAPE: a patch to a method of a conventionally PRIVATE State class,
# whose new body consumes that class's private members.
#
# WHY THIS EXISTS AND WHY IT IS NOT A COMPILE-LEVEL PROBE. The producer lowers a
# private receiver class to `dynamic`, because the private class name cannot be
# written in a synthetic library. The front end accepts ANY member name on a
# dynamic receiver with no privacy test -- so for this shape `self._x` compiles
# with or without `--resolve-private-names-in-library`, and compile success is
# NOT evidence. Privacy correctness only becomes observable when the bytecode
# BINDS against the release. Everything below is therefore scored on the running
# program, not on the compiler's exit code.
#
# `probes/p1_private_scope_controls.sh` is the compile-side companion, valid for
# a TYPED receiver. Neither replaces the other.
#
# PRECOMMIT -- fixed before running. Deviation is a finding, not a retune.
#
#   | arm | replacement body reaches            | expect                     |
#   |-----|-------------------------------------|----------------------------|
#   | B0  | a PUBLIC member of the private class| PASS  (control)            |
#   | B1  | a granted private FIELD             | PASS                       |
#   | B2  | a granted private GETTER            | PASS                       |
#   | B3  | a granted private METHOD            | PASS                       |
#   | B4  | a private member the interface does | REFUSE                     |
#   |     | NOT name                            |                            |
#   | B4b | a private member the interface does | REFUSE                     |
#   |     | NOT name and that TFA MUST keep as  | -- if this BINDS it is a   |
#   |     | a dispatchable member (the release  |    CAPABILITY LEAK         |
#   |     | calls it through a dynamic receiver)|                            |
#   | B5  | a private member of a SECOND library | REFUSE                    |
#   | B6  | a member that does not exist at all | REFUSE (vacuity control)   |
#
#   Every arm is scored into exactly one of:
#     PASS          -- the marker the replacement writes is displayed
#     COMPILE       -- refused by the compiler; never reached bind
#     ATTACH        -- container refused / did not attach
#     BIND          -- attached, then failed at run time
#     SILENT-OLD    -- attached, no error, and the value did NOT change.
#                      Scored on its own because it is the failure mode this
#                      project has been bitten by: success reported, nothing done.
#
#   STOP/INVALID rows, scored as "no result" rather than as a pass:
#     * B0 does not PASS            -> the harness cannot patch this shape at all,
#                                      and every refusal below is unattributable
#     * B6 does not fail            -> bind failures are undetectable here
#     * the interface still names the withheld member (B4's premise)
#     * the interface does NOT name a granted member (B1-B3's premise)
#
# ONE HARNESS ARTIFACT, DOCUMENTED SO NOBODY CHASES IT. `attachBytecodeToFunction`
# smoke-invokes the freshly attached function from C++ with a NULL receiver, so
# EVERY arm whose body touches `self` prints
#
#   ATTACH: C++ invoke error: ... NoSuchMethodError: ... Receiver: null
#
# including the arms that PASS. It is benign and it is not evidence of anything.
# The real call is the program's own, and it is the one AFTER the `APPLY` line --
# which is where this probe reads both the value and any exception. A refusal arm
# additionally has to show a REAL receiver (`Instance of '_FooState'`), or it is
# scored INVALID: a null-receiver failure would refuse every body ever written and
# would say nothing about capability.
#
# WRITES ARE DELIBERATELY OUT OF SCOPE. Phase 0 saw compound writes zero times;
# reads, getters and method calls answer whether idiomatic private State objects
# are viable.
#
# Host only. No device, no mint, no cell.
#
#   probes/p1_bind_private_receiver.sh
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
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1));
  else echo "  FAIL  $1"; echo "        got : $2"; echo "        want: $3";
    fail=$((fail+1)); fi
}
invalidate() { echo "  INVALID  $1"; invalid=$((invalid+1)); }

[ -x "$DART" ] || die "no host dart at $DART"
echo "work: $WORK"
mkdir -p "$WORK/lib" "$WORK/.dart_tool"

# ------------------------------------------------------------------ the fixture
# The release, shaped like idiomatic Flutter: the State class is PRIVATE and the
# patch target is one of its methods.
cp "$RB/packaging/container_target.dart" "$WORK/lib/container_target.dart"
python3 - "$WORK/lib/container_target.dart" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace(
    "void _state(String when) =>",
    """// THE IDIOMATIC FLUTTER SHAPE: a conventionally private State class.
//
// Every body routes through DateTime.now(). A literal is constant-folded by TFA
// even under vm:never-inline, which once made a working mechanism report OLD.
class _FooState {
  // Granted privates. Their retention comes from the interface naming them --
  // the release does NOT call them, which is the production shape.
  final String _secret =
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'F' : 'X';

  String get _privateGetter =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'G' : 'X';

  @pragma('vm:never-inline')
  String _privateMethod() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'M' : 'X';

  // WITHHELD from the interface. B4's target.
  @pragma('vm:never-inline')
  String _ungranted() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'U' : 'X';

  // ALSO WITHHELD, but the release calls it through a DYNAMIC receiver, so TFA
  // cannot devirtualize or inline it away and must keep it as a dispatchable
  // member. B4b's target, and the sharp form of the capability question:
  // present in the class, absent from the interface.
  @pragma('vm:never-inline')
  String _ungrantedKept() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'K' : 'X';

  // A PUBLIC member of the private class: B0's control.
  @pragma('vm:never-inline')
  String publicHelper() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'H' : 'X';

  // THE PATCH TARGET.
  @pragma('vm:never-inline')
  String build() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD' : 'X';
}

final _foo = _FooState();

// The release's own uses. Neither grants anything -- they only decide whether
// the MEMBER survives, which is the variable B4 and B4b differ on.
@pragma('vm:never-inline')
String _releaseUsesUngranted() => _foo._ungranted();

// Dynamic on purpose: the compiler cannot prove the target, so the member has to
// stay dispatchable by name.
@pragma('vm:never-inline')
String _releaseKeepsMember() {
  final dynamic d = _foo;
  return d._ungrantedKept() as String;
}

void _state(String when) =>""",
    1,
)
s = s.replace(
    "print('$when alpha=${alpha()} beta=${beta()}');",
    "print('$when alpha=${alpha()} beta=${beta()} "
    "foo=${_foo.build()} live=${_releaseUsesUngranted()} "
    "kept=${_releaseKeepsMember()}');",
    1,
)
p.write_text(s)
PY

# A SECOND app library, for B5.
cat > "$WORK/lib/second.dart" <<'DART'
class SecondHolder {
  final String _secondSecret =
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'S' : 'X';
  @pragma('vm:never-inline')
  String read() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'r' : 'X';
}

final second = SecondHolder();
DART

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
SECOND=package:dynamic_modules/second.dart
SDK_MEMBERS='dart:core#print,dart:core#DateTime.now,dart:core#DateTime.get:millisecondsSinceEpoch'
cd "$WORK"

note "release: interface under --policy p2, then _ungranted WITHHELD by hand"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o prepass.dill "$URI" >/dev/null
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot \
  --no-link-platform --packages .dart_tool/package_config.json \
  -o import.dill "$URI" >/dev/null
# shellcheck disable=SC2086
"$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill prepass.dill \
  --private-dill import.dill --policy p2 \
  --out di.yaml --manifest manifest.json --sdk-members "$SDK_MEMBERS" 2>&1 \
  | sed -n 's/^/    /p'

# WITHHOLDING, and it has to be surgical: drop only the `member: '_ungranted'`
# entry and leave everything else byte-identical, so B4 differs from B1-B3 in
# exactly one grant.
python3 - di.yaml <<'PY'
import pathlib, re, sys
p = pathlib.Path('di.yaml'); lines = p.read_text().splitlines()
out, dropped, i = [], 0, 0
while i < len(lines):
    if re.match(r"\s*member: '_ungranted(Kept)?'\s*$", lines[i]):
        # An entry is `- library: X` / `class: 'C'` / `member: 'm'`; drop the
        # member line and the class line it belongs to only if that class line
        # exists solely for it. Simplest correct move: drop this member line and
        # let the class/library lines stand -- a bare class item is a DIFFERENT
        # grant (constructibility), which this arm must not silently change.
        dropped += 1; i += 1; continue
    out.append(lines[i]); i += 1
p.write_text('\n'.join(out) + '\n')
print(f'    withheld {dropped} _ungranted entry/entries')
PY

# THE PREMISES, asserted rather than assumed.
ungrantedNamed=$(grep -c "member: '_ungranted'" di.yaml || true)
keptNamed=$(grep -c "member: '_ungrantedKept'" di.yaml || true)
secretNamed=$(grep -c "member: '_secret'" di.yaml || true)
getterNamed=$(grep -cE "member: '(_privateGetter|get:_privateGetter)'" di.yaml || true)
methodNamed=$(grep -c "member: '_privateMethod'" di.yaml || true)
echo "    interface: _secret=$secretNamed _privateGetter=$getterNamed _privateMethod=$methodNamed _ungranted=$ungrantedNamed _ungrantedKept=$keptNamed"
[ "$ungrantedNamed" -eq 0 ] || invalidate "B4's premise: the interface still names _ungranted"
[ "$keptNamed" -eq 0 ] || invalidate "B4b's premise: the interface still names _ungrantedKept"
[ "$secretNamed" -ge 1 ] || invalidate "B1's premise: the interface does not name _secret"
[ "$getterNamed" -ge 1 ] || invalidate "B2's premise: the interface does not name _privateGetter"
[ "$methodNamed" -ge 1 ] || invalidate "B3's premise: the interface does not name _privateMethod"

"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
  -o release.dill "$URI" >/dev/null
"$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
  --elf=app.aot release.dill
BUILD_ID=$("$AOT_RUNTIME" app.aot | sed -n 's/^BUILD_ID //p')
[ -n "$BUILD_ID" ] || die "no release build id"
echo "    release: $BUILD_ID"
# The baseline is printed by B0's run below: with no patch argument main returns
# after BUILD_ID, so there is no `before` line to read here.

# ------------------------------------------------------------------- the arms
# arm <name> <expect PASS|REFUSE> <flag lib or -> <body>
arm() {
  local name=$1 expect=$2 flagLib=$3 body=$4
  note "$name -- expect $expect"
  cat > "repl_$name.dart" <<EOF
import '$URI';
import '$SECOND';

@pragma('dyn-module:entry-point')
$body
EOF
  echo "    | $(grep -m1 'String build' "repl_$name.dart")"
  local args=(--platform "$OUT/vm_platform.dill" --import-dill import.dill
              --packages .dart_tool/package_config.json
              -o "repl_$name.bytecode" "repl_$name.dart")
  [ "$flagLib" != "-" ] && args=(--platform "$OUT/vm_platform.dill"
              --import-dill import.dill
              --resolve-private-names-in-library "$flagLib"
              --packages .dart_tool/package_config.json
              -o "repl_$name.bytecode" "repl_$name.dart")
  set +e
  "$DART" "$DART2BC" "${args[@]}" > "compile_$name.log" 2>&1
  local crc=$?
  set -e

  local outcome
  if [ "$crc" -ne 0 ]; then
    outcome=COMPILE
    grep -m1 -iE "error" "compile_$name.log" | sed 's/^/      /' || true
  else
    "$DART" "$RB/packaging/pack_patch.dart" --release-build-id "$BUILD_ID" \
      --out "patch_$name.sbrb" \
      --target "$URI#_FooState.build=$WORK/repl_$name.bytecode" >/dev/null 2>&1
    set +e
    "$AOT_RUNTIME" app.aot "patch_$name.sbrb" > "run_$name.log" 2>&1
    set -e
    local applyLine got realFail realReceiver
    applyLine=$(grep -m1 '^APPLY' "run_$name.log" || echo 'APPLY <none>')
    got=$(sed -n 's/^after .*foo=\([^ ]*\).*/\1/p' "run_$name.log" | tail -1)
    got=${got:-'<no value>'}
    # EVERYTHING AFTER THE APPLY LINE, which is the program's own call. The text
    # before it includes the harness's null-receiver smoke invoke, which fires in
    # passing arms too and must never be read as this arm's result.
    sed -n '/^APPLY/,$p' "run_$name.log" > "real_$name.log"
    realFail=$(grep -m1 'NoSuchMethodError' "real_$name.log" || true)
    realReceiver=$(grep -m1 '^Receiver:' "real_$name.log" || true)
    echo "      $applyLine"
    echo "      foo = $got"
    if echo "$applyLine" | grep -q 'refused'; then
      outcome=ATTACH
    elif [ "$got" = 'OLD' ]; then
      outcome=SILENT-OLD
    elif [ "$got" = '<no value>' ]; then
      outcome=BIND
      [ -n "$realFail" ] && echo "      $realFail" | sed 's/^/  /'
      [ -n "$realReceiver" ] && echo "      $realReceiver" | sed 's/^/  /'
      # A null receiver would refuse ANY body and says nothing about capability.
      if echo "$realReceiver" | grep -q 'null'; then
        invalidate "$name failed on a NULL receiver -- unattributable, not a capability result"
      fi
    else
      outcome=PASS
    fi
    # The unrelated control must not move, whatever this arm did.
    local ctl
    ctl=$(sed -n 's/^after .*live=\([^ ]*\).*/\1/p' "run_$name.log" | tail -1)
    [ -n "$ctl" ] && [ "$ctl" != 'U' ] && \
      invalidate "$name moved the unrelated control (live=$ctl, expected U)"
  fi
  echo "    OUTCOME: $outcome"
  if [ "$expect" = PASS ]; then
    check "$name binds and executes" "$outcome" "PASS"
  else
    check "$name is refused" "$([ "$outcome" = PASS ] && echo PASS || echo refused)" "refused"
    echo "      refused at: $outcome"
  fi
  ARM_OUTCOME=$outcome
}

arm B0 PASS - \
  "String build(dynamic self) => 'NEW-PUB\${self.publicHelper()}';"
b0=$ARM_OUTCOME
echo "    baseline: $(sed -n 's/^before //p' run_B0.log | tail -1)"

# B4b's PREMISE, asserted rather than assumed: the withheld member must actually
# be dispatchable in the release, or B4b degenerates into B4. `kept=K` is the
# release calling `_ungrantedKept` through a dynamic receiver, which no
# devirtualization or inlining can serve.
keptLive=$(sed -n 's/^before .*kept=\([^ ]*\).*/\1/p' run_B0.log | tail -1)
if [ "$keptLive" != 'K' ]; then
  invalidate "B4b's premise: _ungrantedKept is not dispatchable in the release (kept=$keptLive)"
fi

if [ "$b0" != PASS ]; then
  invalidate "B0 is the STOP row: this harness cannot patch a method of a private class"
  echo; echo "STOPPED. Refusals below would be unattributable, so they were not run."
  echo "  pass=$pass fail=$fail invalid=$invalid"
  exit 2
fi

arm B1 PASS "$URI" \
  "String build(dynamic self) => 'NEW-FLD\${self._secret}';"
arm B2 PASS "$URI" \
  "String build(dynamic self) => 'NEW-GET\${self._privateGetter}';"
arm B3 PASS "$URI" \
  "String build(dynamic self) => 'NEW-MTH\${self._privateMethod()}';"
arm B4 REFUSE "$URI" \
  "String build(dynamic self) => 'NEW-UNG\${self._ungranted()}';"
b4=$ARM_OUTCOME
arm B4b REFUSE "$URI" \
  "String build(dynamic self) => 'NEW-KEPT\${self._ungrantedKept()}';"
b4b=$ARM_OUTCOME
arm B5 REFUSE "$URI" \
  "String build(dynamic self) => 'NEW-SND\${second._secondSecret}';"
arm B6 REFUSE "$URI" \
  "String build(dynamic self) => 'NEW-NOPE\${self._doesNotExistAnywhere()}';"
b6=$ARM_OUTCOME
[ "$b6" = PASS ] && invalidate "B6 bound a member that does not exist -- bind failures are undetectable here"

note "RESULT"
echo "  pass=$pass fail=$fail invalid=$invalid"
if [ "$b4" = PASS ] || [ "$b4b" = PASS ]; then
  echo
  echo "  *** CAPABILITY LEAK: a private member the interface does not name was"
  echo "      reachable from a patch (B4=$b4 B4b=$b4b). B4b is the sharp one: that"
  echo "      member is still dispatchable in the class, so a PASS there means the"
  echo "      interface grant is not what gates reach."
fi
echo "  work dir kept: $WORK"
[ "$invalid" -gt 0 ] && { echo "  VERDICT: INVALID -- at least one arm proves nothing"; exit 3; }
[ "$fail" -gt 0 ] && { echo "  VERDICT: RED"; exit 1; }
echo "  VERDICT: GREEN"
