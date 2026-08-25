#!/usr/bin/env bash
# cspell:words dartaotruntime prepass NONAOT nonexistent GrowableList
#
# p1_private_scope_controls.sh -- P1.1: does --resolve-private-names-in-library
# restore ONE target library's legitimate privacy scope, or does it widen name
# resolution further than that?
#
# The mechanism (patch 0005) is already shipped and already wired into the real
# producer. What has never been measured is the NEGATIVE side: what the flag
# refuses. Every arm below is a refusal the design claims; an arm that passes for
# the wrong reason is worse than a missing arm, so each one names the error it
# must produce.
#
# PRECOMMIT -- fixed before running. Deviation is a finding, not a retune.
#
#   | arm | flag                     | body references                | expect |
#   |-----|--------------------------|--------------------------------|--------|
#   | A1  | none                     | app private, typed receiver    | REFUSE |
#   | A2  | target library           | app private, typed receiver    | COMPILE|
#   | A3  | a DIFFERENT app library  | app private, typed receiver    | REFUSE |
#   | A4  | target library           | a SECOND app library's private | REFUSE |
#   | A5  | dart:core                | a dart:core private TYPE       | REFUSE |
#   | A6  | a library not in the dill| app private, typed receiver    | REFUSE, LOUDLY |
#
#   STOP/INVALID rows, scored as "no result" rather than as a pass:
#     * A2 does not compile            -> the fixture or toolchain is wrong, and
#                                         every refusal below is unattributable
#     * a REFUSE arm exits non-zero without its named error string
#     * A5's dart:core private type does not exist in this platform dill
#
# WHY THE RECEIVER IS TYPED IN A1-A4, and why that is not the shape the product
# uses: with a `dynamic` receiver the front end accepts any member name with no
# privacy test, so `self._x` compiles WITH OR WITHOUT the flag and fails later at
# BIND. A compile-level table cannot discriminate there -- PARITY.md says so in
# as many words ("`self._secret` on a `dynamic` receiver compiles either way").
# The product's lowering uses `dynamic` precisely when the receiver class is
# private. So:
#
#   * this probe scores the flag's NAME-RESOLUTION boundary, on a typed receiver;
#   * the private-RECEIVER-class case (the idiomatic Flutter `_FooState`) is a
#     BIND-time question and needs the AOT runtime arm -- p3_usability.sh is the
#     existing example, and P1.1's Flutter-shaped half is tracked separately.
#
# Host only. No device, no mint, no cell.
#
#   probes/p1_private_scope_controls.sh
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
RB="$(cd "$HERE/.." >/dev/null 2>&1 && pwd)"
WORK=${WORK:-$(mktemp -d)}

DART_TREE=$SRC/flutter/third_party/dart
DART=$OUT/dart-sdk/bin/dart
GEN_KERNEL=$DART_TREE/pkg/vm/bin/gen_kernel.dart
DART2BC=$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart

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

# ---------------------------------------------------------------- the fixture
# TWO app libraries, because "one library's scope" is only testable against a
# second one that must stay closed.

cat > "$WORK/lib/app_main.dart" <<'DART'
// The target library. Shapes both cases on purpose:
//   PublicHolder  -- public class, private member: a TYPED receiver, so the
//                    compile-time privacy test applies and is measurable here.
//   _WidgetState  -- the idiomatic Flutter shape, private class. Kept in the
//                    fixture so the two are visibly different problems, but it
//                    is NOT what this probe scores (see the header).
import 'package:p1app/app_second.dart';

class PublicHolder {
  int _hidden = 5;
  @pragma('vm:never-inline')
  String publicValue() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-pub' : 'X';
}

class _WidgetState {
  int _count = 3;
  @pragma('vm:never-inline')
  String _privateMethod() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'P' : 'X';
  @pragma('vm:never-inline')
  String buildValue() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD' : 'X';
}

final holder = PublicHolder();
final _state = _WidgetState();

// References the second library so it is really part of the program, which is
// what makes A3/A4 a test of SCOPE rather than of absence.
String render() => '${holder.publicValue()}${_state.buildValue()}${second.read()}';

// gen_kernel compiles a PROGRAM, so the fixture needs an entry point. It also
// keeps every member above reachable, which is what stops this from becoming a
// test against code the compiler already dropped.
void main() => print('render=${render()}');
DART

cat > "$WORK/lib/app_second.dart" <<'DART'
// A SECOND app library. Its private member must stay unreachable even when the
// flag has granted the first library's scope.
class SecondHolder {
  int _secondHidden = 9;
  @pragma('vm:never-inline')
  String read() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? '$_secondHidden' : 'X';
}

final second = SecondHolder();
DART

cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "p1app", "rootUri": "file://$WORK/", "packageUri": "lib/",
    "languageVersion": "3.9" } ] }
JSON

MAIN=package:p1app/app_main.dart
SECOND=package:p1app/app_second.dart
cd "$WORK"

note "import kernel (--no-aot, so private members survive in the dill namespace)"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot \
  --no-link-platform --packages .dart_tool/package_config.json \
  -o import.dill "$MAIN" >/dev/null
ls -l import.dill | awk '{print "    import.dill " $5 " bytes"}'

# ---------------------------------------------------------------- the arms
# One compile per arm. `compile <name> <flag-or-empty> <source-file>`.
compile() { # <name> <flag value or -> <source>
  local name=$1 flag=$2 src=$3
  local args=(--platform "$OUT/vm_platform.dill" --import-dill import.dill
              --packages .dart_tool/package_config.json
              -o "$name.bytecode" "$src")
  if [ "$flag" != "-" ]; then
    args=(--platform "$OUT/vm_platform.dill" --import-dill import.dill
          --resolve-private-names-in-library "$flag"
          --packages .dart_tool/package_config.json
          -o "$name.bytecode" "$src")
  fi
  set +e
  "$DART" "$DART2BC" "${args[@]}" > "$name.log" 2>&1
  echo $? > "$name.rc"
  set -e
}

# The body every arm but A4/A5 uses: a TYPED receiver reaching a private member.
cat > repl_typed.dart <<DART
import '$MAIN';

@pragma('dyn-module:entry-point')
String publicValue(PublicHolder self) => '\${self._hidden}';
DART

# A4's body: the flag will name app_main, and this reaches app_second's private.
cat > repl_second.dart <<DART
import '$MAIN';
import '$SECOND';

@pragma('dyn-module:entry-point')
String publicValue(PublicHolder self) => '\${second._secondHidden}';
DART

# A5's body: a dart:core PRIVATE TYPE. Type-name resolution only -- no member
# lookup -- so a pass or fail is unambiguous.
cat > repl_dart_private.dart <<DART
import '$MAIN';

@pragma('dyn-module:entry-point')
String publicValue(PublicHolder self) {
  final _GrowableList<int>? probe = null;
  return '\$probe';
}
DART

note "A2 first -- it is the STOP row: nothing below is attributable without it"
compile a2 "$MAIN" repl_typed.dart
a2rc=$(cat a2.rc)
if [ "$a2rc" -ne 0 ] || [ ! -s a2.bytecode ]; then
  echo "    compile log:"; sed -n 1,12p a2.log | sed 's/^/      /'
  invalidate "A2 target-library scope compiles (STOP row)"
  echo; echo "STOPPED: the fixture or toolchain is wrong. Refusals below would be"
  echo "unattributable, so they were not run."
  exit 2
fi
check "A2 target-library scope COMPILES" "ok" "ok"
ls -l a2.bytecode | awk '{print "    a2.bytecode " $5 " bytes"}'

note "A1 -- no flag at all"
compile a1 - repl_typed.dart
a1rc=$(cat a1.rc)
a1named=$(grep -c "_hidden" a1.log || true)
check "A1 REFUSES without the flag" "$([ "$a1rc" -ne 0 ] && echo refused || echo compiled)" "refused"
if [ "$a1rc" -ne 0 ] && [ "$a1named" -eq 0 ]; then
  invalidate "A1 failed for an unnamed reason (the error does not mention _hidden)"
  sed -n 1,6p a1.log | sed 's/^/      /'
else
  grep -m1 -iE "error" a1.log | sed 's/^/      /' || true
fi

note "A3 -- flag names a DIFFERENT app library"
compile a3 "$SECOND" repl_typed.dart
a3rc=$(cat a3.rc)
a3named=$(grep -c "_hidden" a3.log || true)
check "A3 REFUSES under the wrong library's scope" "$([ "$a3rc" -ne 0 ] && echo refused || echo compiled)" "refused"
[ "$a3rc" -ne 0 ] && [ "$a3named" -eq 0 ] && invalidate "A3 failed without naming _hidden"
grep -m1 -iE "error" a3.log | sed 's/^/      /' || true

note "A4 -- target scope granted, body reaches a SECOND library's private"
compile a4 "$MAIN" repl_second.dart
a4rc=$(cat a4.rc)
a4named=$(grep -c "_secondHidden" a4.log || true)
check "A4 REFUSES the second library's private" "$([ "$a4rc" -ne 0 ] && echo refused || echo compiled)" "refused"
[ "$a4rc" -ne 0 ] && [ "$a4named" -eq 0 ] && invalidate "A4 failed without naming _secondHidden"
grep -m1 -iE "error" a4.log | sed 's/^/      /' || true

note "A5 -- flag names dart:core, body names a dart:core PRIVATE TYPE"
compile a5 "dart:core" repl_dart_private.dart
a5rc=$(cat a5.rc)
check "A5 REFUSES platform privacy widening" "$([ "$a5rc" -ne 0 ] && echo refused || echo compiled)" "refused"
grep -m1 -iE "error" a5.log | sed 's/^/      /' || true
# ANTI-VACUITY for A5: if _GrowableList is not a real dart:core private in this
# platform dill, the refusal proves nothing about widening.
compile a5ctl "$MAIN" repl_dart_private.dart
if [ "$(cat a5ctl.rc)" -eq 0 ]; then
  invalidate "A5's control compiled -- _GrowableList resolved WITHOUT dart:core scope"
fi

note "A6 -- flag names a library that is not in the dill (must fail LOUDLY)"
compile a6 "package:p1app/not_a_library.dart" repl_typed.dart
a6rc=$(cat a6.rc)
a6loud=$(grep -c "no such library is available to this compile" a6.log || true)
check "A6 REFUSES" "$([ "$a6rc" -ne 0 ] && echo refused || echo compiled)" "refused"
check "A6 says WHY, rather than compiling with narrower scope" "$a6loud" "1"
grep -m1 "no such library" a6.log | sed 's/^/      /' || true

note "RESULT"
echo "  pass=$pass fail=$fail invalid=$invalid"
echo "  work dir kept: $WORK"
[ "$invalid" -gt 0 ] && { echo "  VERDICT: INVALID -- at least one arm proves nothing"; exit 3; }
[ "$fail" -gt 0 ] && { echo "  VERDICT: RED"; exit 1; }
echo "  VERDICT: GREEN -- the flag restores one library's scope and refuses the rest"
