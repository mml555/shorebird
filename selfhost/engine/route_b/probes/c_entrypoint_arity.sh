#!/usr/bin/env bash
# cspell:words dartaotruntime dart2bytecode
#
# c_entrypoint_arity.sh -- the compiler contract, pinned.
#
# Upstream requires `dyn-module:entry-point` to be a static NO-ARGUMENT method.
# The fork has relaxed that twice, and this probe is where each relaxation was
# pinned so the next one cannot happen by accident.
#
#   patch 0004, rung C : zero OR ONE positional -- the receiver needs a slot.
#   G3.7, 2026-08-13   : ANY number of REQUIRED positional -- a target method
#                        with its own parameters lowers to
#                        f(Receiver self, T1 a, ...), and the cap at one is what
#                        made the largest measured slice of real methods
#                        unpatchable (33.2 % structural reach; parameters appear
#                        in 6 of 10 real patches).
#
#   static, 0 positional          allowed
#   static, 1 positional          allowed
#   static, 2 positional          allowed   <- G3.7 flipped this one
#   static, 3 positional          allowed
#   static, OPTIONAL positional   REFUSED   <- the new boundary, and the reason
#                                              the check tests
#                                              requiredParameterCount rather
#                                              than a bare length
#   static, 1 named               REFUSED
#   static, generic               REFUSED
#   instance method               REFUSED
#
# WHY OPTIONAL POSITIONALS STAY REFUSED. Their default values live in the AOT
# function the replacement is standing in for, and nothing carries them across.
# Allowing them would compile and then bind against a caller that never passes
# the argument, which is the silent-on-device failure shape this project is
# organised against.
#
# Compile-only: this says nothing about whether the receiver actually arrives
# in argument 0. That is C0, on a device, and it is deliberately a separate
# question from "does the compiler accept the shape".
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
WORK=${WORK:-$(mktemp -d)}
DART_TREE=$SRC/flutter/third_party/dart
DART=$OUT/dart-sdk/bin/dart
DART2BC=$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart

die() { echo "ERROR: $*" >&2; exit 1; }
pass=0; fail=0
[ -x "$DART" ] || die "no host dart at $DART"
cd "$WORK"

# Compiled against the plain VM platform: the contract is a property of
# dart2bytecode, not of any particular app or platform dill.
arm() { # <label> <expect: allow|refuse> <source>
  local label="$1" expect="$2" src="$3"
  printf '%s\n' "$src" > "$label.dart"
  set +e
  "$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" \
    -o "$label.bytecode" "$label.dart" > "$label.log" 2>&1
  local rc=$?
  set -e

  local got=allow
  [ "$rc" -ne 0 ] && got=refuse

  if [ "$got" = "$expect" ]; then
    echo "  PASS  $label ($got)"
    pass=$((pass+1))
  else
    echo "  FAIL  $label (expected $expect, got $got)"
    { grep -m1 -iE "should be|error" "$label.log" || true; } | sed 's/^/        /'
    fail=$((fail+1))
  fi
  # Show the refusal wording for the arms that define the boundary.
  if [ "$got" = refuse ] && [ "$expect" = refuse ]; then
    { grep -m1 "Dynamic Module Entry Point" "$label.log" || true; } \
      | sed 's/^/        /'
  fi
}

echo "dart2bytecode entry-point contract"
echo

arm zero_args allow "@pragma('dyn-module:entry-point')
String f() => 'ok';"

arm one_positional allow "@pragma('dyn-module:entry-point')
String f(Object self) => 'ok';"

arm two_positional allow "@pragma('dyn-module:entry-point')
String f(Object a, Object b) => 'ok';"

arm three_positional allow "@pragma('dyn-module:entry-point')
String f(Object a, Object b, Object c) => 'ok';"

# The boundary G3.7 introduces. Without this arm the requiredParameterCount test
# is untested, and a later "simplification" to a bare length check would pass.
arm optional_positional refuse "@pragma('dyn-module:entry-point')
String f(Object a, [Object? b]) => 'ok';"

arm one_named refuse "@pragma('dyn-module:entry-point')
String f({Object? a}) => 'ok';"

arm generic refuse "@pragma('dyn-module:entry-point')
String f<T>(T a) => 'ok';"

arm instance_method refuse "class C {
  @pragma('dyn-module:entry-point')
  String f() => 'ok';
}"

echo
echo "--------------------------------------------------"
echo "entry-point contract: $pass passed, $fail failed"
echo "work dir kept: $WORK"
[ "$fail" -eq 0 ] || exit 1
