#!/usr/bin/env bash
# cspell:words dartaotruntime sbrb dynmod prepass NONAOT unretained Wonderous discriminable pathlib
#
# dead_body.sh -- is a retained private member's BODY still there?
#
# THREE FAILURE MODES, and this probe exists because the third one is silent.
# PARITY.md §3 records them; only the first two have ever been observed:
#
#   1 VISIBILITY  the replacement cannot name the member
#                 -> compile error, "the getter '_x' isn't defined"
#   2 RETENTION   the member is not in the release
#                 -> load error, bytecode_reader.cc:1172 "Unable to find function"
#   3 DEAD BODY   the member is retained and its body is NOT
#                 -> nothing. The name resolves and the call enters a stub.
#
# Mode 3 was found by reading TFA, not by running anything, and probe D cannot
# see it: probe D's target is a private TOP-LEVEL function, which becomes a raw
# DirectSelector, so TFA analyses and retains its body. A private INSTANCE member
# whose enclosing class is never ALLOCATED becomes an InterfaceSelector over that
# class's cone type; with nothing allocated in the cone the body never becomes
# reachable, and TFA pass 2 keeps the declaration while replacing the body
# (transformer.dart:2348-2360 _makeUnreachableBody, or isAbstract with a null
# body at :2294-2302). gen_snapshot then records a retain reason and emits no
# code (precompiler.cc:1667-1675).
#
# So EXISTENCE IN THE AOT KERNEL DOES NOT IMPLY AN EXECUTABLE BODY. That is the
# claim under test, and the reason "live-instance" is refused as a retention
# policy category until liveness is mechanically provable.
#
# WHAT THIS PROBE DOES NOT DO. It does not assume mode 3 occurs. If the class is
# never allocated then the release has no instance, so the replacement must
# obtain one -- and the constructor may itself be unretained, which is mode 2
# arriving first and hiding mode 3 entirely. So the dead arm CLASSIFIES what
# actually happens rather than asserting a guessed signature, and says loudly
# when it observed mode 2 instead: that would mean mode 3 is real but NOT
# isolable by this construction, which is a different and equally useful result.
#
# DELIBERATELY NOT IN SCOPE, so the answer stays attributable: no --private-dill,
# no analyzer relaxation (G3.6b), no Wonderous measurement, no cell mint. This
# probe answers one question -- is mode 3 reproducible and discriminable?
#
# THE ANSWER, 2026-08-12: NOT UNDER THE CURRENT RETENTION POLICY. 1 passed,
# 1 failed, and the failure is the POSITIVE CONTROL, which is the diagnostic.
#
#   _secret entries in interface: 0        for BOTH classes
#   live arm  -> mode 2: "Unable to find function _secret@17057535 in
#                Library:'...container_target.dart' Class: _Live@17057535"
#   dead arm  -> mode 2, identically
#
# Privacy resolution worked: the name is correctly keyed to the app library AND
# the enclosing class, so mode 1 is genuinely closed. What failed is retention,
# for both arms, because the generator reads the --aot prepass and TFA had already
# dropped `_secret` -- nothing in the release calls it. The interface names both
# CLASSES, but a `class:` item retains only PUBLIC members, so a private member
# still needs its own `member:` entry and there was nothing to emit one from.
#
# MODE 2 THEREFORE MASKS MODE 3 UNIVERSALLY, and the masking is structural rather
# than a fixture accident:
#
#   to name `_secret` in the interface, the release must reference it;
#   referencing `_Dead()._secret()` allocates _Dead;
#   so "named in the interface but never allocated" is NOT CONSTRUCTIBLE while
#   private enumeration reads the post-TFA prepass.
#
# CONSEQUENCE FOR SEQUENCING, which is the useful part: mode 3 is a hazard
# INTRODUCED BY --private-dill, not a pre-existing one. Non-AOT enumeration is
# what first makes it possible to name a member TFA dropped, and only then can a
# retained-but-never-allocated member exist. So this probe belongs INSIDE step 2
# of the §3 gate, not before it -- and it is left RED on purpose: the control is a
# pending gate, not a broken test, exactly as probe D's question (1) is.
#
#   dead_body.sh
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
GEN_SNAPSHOT=$OUT/gen_snapshot
AOT_RUNTIME=$OUT/dartaotruntime
DART2BC=$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart
PKGS_DIR=$DART_TREE/third_party/pkg/core/pkgs

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }
pass=0; fail=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1));
  else echo "  FAIL  $1"; echo "        got : $2"; echo "        want: $3";
    fail=$((fail+1)); fi
}

[ -x "$DART" ] || die "no host dart at $DART"
mkdir -p "$WORK/lib" "$WORK/.dart_tool"

# THE FIXTURE. Two classes with the SAME private-member shape, differing only in
# whether the release allocates them -- which is the discriminator the whole
# question turns on.
#
#   _Live   ALLOCATED by the release, and used, but `_secret` is never called.
#           So `_secret` is retained by the interface alone, exactly like the
#           dead case, and the only difference is allocation. That is what makes
#           this a control rather than a second experiment.
#   _Dead   never allocated. Referenced only as a TYPE, so the class survives
#           into the prepass kernel and the generator can name its members --
#           without that, the class is gone and there is nothing to retain,
#           which would be mode 2 rather than mode 3.
cp "$RB/packaging/container_target.dart" "$WORK/lib/container_target.dart"
python3 - "$WORK/lib/container_target.dart" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace(
    "void _state(String when) =>",
    """class _Live {
  // Never called by the release. Retained only because the interface names it.
  // Routed through DateTime.now() so a literal is not constant-folded, which
  // would let a broken mechanism report the right answer.
  @pragma('vm:never-inline')
  String _secret() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'NEW-LIVE' : 'X';

  @pragma('vm:never-inline')
  String alive() => 'live';
}

class _Dead {
  @pragma('vm:never-inline')
  String _secret() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'NEW-DEAD' : 'X';
}

// ALLOCATED. This is the only difference between the two classes.
final _liveInstance = _Live();

// _Dead is named as a TYPE and never constructed, so the class survives TFA
// while nothing enters its cone.
_Dead? _deadRef;
@pragma('vm:never-inline')
String _deadTypePresent() => _deadRef == null ? 'unallocated' : 'allocated';

void _state(String when) =>""",
    1,
)
s = s.replace(
    "print('$when alpha=${alpha()} beta=${beta()}');",
    "print('$when alpha=${alpha()} beta=${beta()} "
    "live=${_liveInstance.alive()} dead=${_deadTypePresent()}');",
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
SDK_MEMBERS='dart:core#print,dart:core#DateTime.now,dart:core#DateTime.get:millisecondsSinceEpoch'
cd "$WORK"

note "release: prepass -> interface -> release -> snapshot"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o prepass.dill "$URI" >/dev/null
# NO --private-dill. The prepass is read exactly as the product reads it today,
# so whatever this probe finds is a property of the shipping policy.
"$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill prepass.dill \
  --out di.yaml --sdk-members "$SDK_MEMBERS" 2>&1 | sed -n 's/^/    /p'
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
  -o release.dill "$URI" >/dev/null
"$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
  --elf=app.aot release.dill
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot \
  --no-link-platform --packages .dart_tool/package_config.json \
  -o import.dill "$URI" >/dev/null
BUILD_ID=$("$AOT_RUNTIME" app.aot | sed -n 's/^BUILD_ID //p')
[ -n "$BUILD_ID" ] || die "no release build id"
echo "    release: $BUILD_ID"

note "what did the interface retain, and what did the release keep?"
for c in _Live _Dead; do
  printf '    %-6s in interface: %s\n' "$c" \
    "$(grep -c "class: '$c'" di.yaml || true)"
done
printf '    _secret entries in interface: %s\n' \
  "$(grep -c "member: '_secret'" di.yaml || true)"
# The app's own report: is _Dead allocated in the shipped release?
printf '    release reports _Dead as: %s\n' \
  "$("$AOT_RUNTIME" app.aot | sed -n 's/^before .*dead=\([^ ]*\).*/\1/p' | tail -1)"

# CLASSIFY, do not assume. Each arm reports WHICH of the three modes it observed,
# so a result that is not mode 3 is still an answer rather than a confusing FAIL.
arm() { # <label> <replacement body> <expected value, or NOT-EXECUTED>
  local label="$1" body="$2" want="$3"
  local dir="$WORK/$label"; mkdir -p "$dir"
  note "$label -- $(printf '%s' "$body" | tr -s ' \n' ' ')"
  printf "import '%s';\n\n%s\n" "$URI" "$body" > "$dir/repl.dart"

  local mode='(unclassified)'
  set +e
  "$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" \
    --import-dill import.dill \
    --resolve-private-names-in-library "$URI" \
    --packages .dart_tool/package_config.json \
    -o "$dir/repl.bytecode" "$dir/repl.dart" > "$dir/compile.log" 2>&1
  local compiled=$?
  set -e

  if [ "$compiled" -ne 0 ]; then
    mode='1 VISIBILITY (compile error)'
    echo "    mode: $mode"
    { grep -m2 -iE "error|isn't defined" "$dir/compile.log" || true; } \
      | sed 's/^/      /'
    check "$label: reached the patched value" '<did not compile>' "$want"
    echo "$mode" > "$dir/MODE"
    return
  fi

  "$DART" "$RB/packaging/pack_patch.dart" --release-build-id "$BUILD_ID" \
    --out "$dir/patch.sbrb" \
    --target "$URI#alpha=$dir/repl.bytecode" >/dev/null 2>&1
  set +e
  "$AOT_RUNTIME" app.aot "$dir/patch.sbrb" > "$dir/run.log" 2>&1
  set -e

  local got
  got=$(sed -n 's/^after  alpha=\([^ ]*\).*/\1/p' "$dir/run.log" | tail -1)
  got=${got:-'<no value>'}

  if grep -q "Unable to find" "$dir/run.log"; then
    mode='2 RETENTION (bytecode_reader.cc:1172, symbol not found)'
    grep -m1 "Unable to find" "$dir/run.log" | sed 's/^.*error: /      /'
  elif [ "$got" = "$want" ]; then
    mode='0 EXECUTED (the body ran)'
  else
    # Resolved -- no lookup failure -- and yet did not produce the value. That is
    # the mode 3 signature. Whatever the stub does is recorded verbatim rather
    # than matched against a guess.
    mode='3 DEAD BODY (resolved, body did not produce the value)'
    { grep -m3 -iE "unreachable|Null check|NoSuchMethod|abstract|error|Unhandled" \
        "$dir/run.log" || true; } | sed 's/^/      /'
  fi
  echo "    mode: $mode"
  echo "$mode" > "$dir/MODE"
  grep -q '^APPLY' "$dir/run.log" \
    && echo "    $(grep -m1 '^APPLY' "$dir/run.log")"
  echo "    alpha = $got"

  if [ "$want" = 'NOT-EXECUTED' ]; then
    if [ "$got" = 'NEW-DEAD' ]; then
      check "$label: the dead body did NOT execute" 'executed' 'not executed'
    else
      check "$label: the dead body did NOT execute" 'not executed' 'not executed'
    fi
  else
    check "$label: reached the patched value" "$got" "$want"
  fi
}

# POSITIVE CONTROL. Same private-member shape, class ALLOCATED by the release,
# `_secret` never called by it. If this fails, nothing about the dead arm can be
# attributed to allocation.
arm live \
  "@pragma('dyn-module:entry-point')
String alpha() => _liveInstance._secret();" \
  'NEW-LIVE'

# THE DEAD ARM. Same shape, class never allocated. The replacement must obtain a
# receiver itself, so this also tests whether the constructor is reachable -- and
# if THAT fails first, the arm reports mode 2 and says mode 3 was not isolated.
arm dead \
  "@pragma('dyn-module:entry-point')
String alpha() => _Dead()._secret();" \
  'NOT-EXECUTED'

echo
echo "--------------------------------------------------"
echo "observed modes:"
for a in live dead; do
  printf '  %-5s %s\n' "$a" "$(cat "$WORK/$a/MODE" 2>/dev/null || echo '(none)')"
done
if [ -f "$WORK/dead/MODE" ] && grep -q '^2 ' "$WORK/dead/MODE"; then
  cat <<'NOTE'

  READ THIS BEFORE RECORDING A RESULT. The dead arm observed mode 2, not mode 3.
  Mode 3 may still be real -- it was derived from TFA source -- but this
  construction cannot isolate it, because the unretained constructor fails before
  the member's body is ever reached. Retaining private CONSTRUCTORS (the generator
  emits none today) would be needed to separate them.
NOTE
fi
echo
echo "dead_body: $pass passed, $fail failed"
echo "work dir kept: $WORK"
[ "$fail" -eq 0 ] || exit 1
