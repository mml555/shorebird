#!/usr/bin/env bash
# cspell:words dartaotruntime sbrb prepass precommitted constructibility pathlib splitlines
#
# p3_usability.sh -- is P3 a real middle ground, or does it only look like one?
#
# THE ONE QUESTION. P3 names private INSTANCE members but emits no `class:` item for
# their private class, which the manifest showed withholds constructibility (119 classes
# and 119 implicit constructors, gone). The measurements then say:
#
#   P1 -> P3   +82 KB   buys the capability shape Phase 0 says users need
#   P3 -> P2  +142 KB   buys constructibility, with no demonstrated demand
#
# So the whole policy choice turns on whether P3's 340 granted members are USABLE, and
# that is an inference until this probe runs. The manifest can only say they were named.
#
# THE REAL PRODUCT SHAPE, not a synthetic one:
#
#   class _Thing {
#     String _secret() => 'NEW';
#     String value()   => 'OLD';    // <- the patch target
#   }
#
# The APP allocates `_Thing`; the patch replaces `value()` and reaches `_secret` through
# the receiver the lowering supplies. The patch constructs nothing. That is exactly
# `_FooState` reading `_controller`, which is the shape Phase 0 found dominating.
#
# TWO THINGS ARE UNDER TEST, and the second is invisible in the manifest:
#
#   1 does `self._secret()` BIND?  -- the granted member actually reachable
#   2 can the patch ATTACH AT ALL? -- the target is a PUBLIC METHOD OF A PRIVATE CLASS,
#     and under P3 that class has no `class:` item while a `library:` item covers only
#     public classes. So attach may fail for reasons unrelated to `_secret`.
#
# Both failures mean "class capability is required", but they fail in different places,
# so the probe reports WHICH.
#
# PRECOMMITTED INTERPRETATION (PARITY.md §3, recorded before this file existed):
#
#   passes                          P3 is real, and the strongest default candidate
#   fails, class capability needed   P3 collapses toward P1; P2 becomes the only policy
#                                    buying the reach Phase 0 showed is needed
#   fails, unrelated mechanism       choose NO policy until it is classified
#
#   p3_usability.sh            # runs the P3 arm
#   POLICY=p2 p3_usability.sh  # the control: same probe, class capability granted
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
RB="$(cd "$HERE/.." >/dev/null 2>&1 && pwd)"
WORK=${WORK:-$(mktemp -d)}
POLICY=${POLICY:-p3}

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

# The app allocates `_Thing` and calls `value()`. `_secret` is never called by the
# release, so it survives only because the interface names it -- which is the condition
# the policy is being judged on.
cp "$RB/packaging/container_target.dart" "$WORK/lib/container_target.dart"
python3 - "$WORK/lib/container_target.dart" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace(
    "void _state(String when) =>",
    """class _Thing {
  // Never called by the release. Routed through DateTime.now() so a literal is not
  // constant-folded, which would let a broken mechanism report the right answer.
  @pragma('vm:never-inline')
  String _secret() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'NEW' : 'X';

  // THE PATCH TARGET: a PUBLIC method of a PRIVATE class.
  @pragma('vm:never-inline')
  String value() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD' : 'X';
}

// The APP allocates it. The patch never constructs anything.
final _thing = _Thing();

void _state(String when) =>""",
    1,
)
s = s.replace(
    "print('$when alpha=${alpha()} beta=${beta()}');",
    "print('$when alpha=${alpha()} beta=${beta()} thing=${_thing.value()}');",
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

note "release under --policy $POLICY"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o prepass.dill "$URI" >/dev/null
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot \
  --no-link-platform --packages .dart_tool/package_config.json \
  -o import.dill "$URI" >/dev/null
# shellcheck disable=SC2086
"$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill prepass.dill \
  --private-dill import.dill --policy "$POLICY" \
  --out di.yaml --manifest manifest.json --sdk-members "$SDK_MEMBERS" 2>&1 \
  | sed -n 's/^/    /p'

# THE POLICY'S OWN PRECONDITIONS, asserted rather than assumed. If P3 stopped
# withholding class capability the probe would pass for the wrong reason.
secretNamed=$(grep -c "member: '_secret'" di.yaml || true)
# A BARE class item, not any line mentioning the class. A member entry is
#   - library: X / class: '_Thing' / member: '_secret'
# so `grep -c "class: '_Thing'"` counts the member entry too and reported 1 for a
# policy that grants no class capability at all. What matters is a `class:` line with
# NO `member:` after it -- that is the item that grants the class and its implicit
# constructor.
classNamed=$(python3 - di.yaml <<'PY'
import sys, re
lines = open(sys.argv[1]).read().splitlines()
bare = 0
for i, line in enumerate(lines):
    if not re.match(r"\s*class: '_Thing'\s*$", line):
        continue
    nxt = lines[i + 1] if i + 1 < len(lines) else ''
    if not re.match(r'\s*member:', nxt):
        bare += 1
print(bare)
PY
)
echo "    _secret named: $secretNamed    _Thing class item: $classNamed"
check "the policy names _secret" "$secretNamed" "1"
if [ "$POLICY" = p3 ]; then
  check "the policy withholds the _Thing class item" "$classNamed" "0"
fi

"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
  -o release.dill "$URI" >/dev/null
"$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
  --elf=app.aot release.dill
BUILD_ID=$("$AOT_RUNTIME" app.aot | sed -n 's/^BUILD_ID //p')
[ -n "$BUILD_ID" ] || die "no release build id"
echo "    release: $BUILD_ID"
echo "    before : $("$AOT_RUNTIME" app.aot | sed -n 's/^before //p' | tail -1)"

note "patch: value() lowered to the receiver form, reaching a granted private member"
# Exactly the lowering the producer emits for a private receiver class: `dynamic self`,
# because the private class name cannot be written in the synthetic library (G3.6c).
cat > repl.dart <<EOF
import '$URI';

@pragma('dyn-module:entry-point')
String value(dynamic self) => self._secret();
EOF
sed 's/^/    | /' repl.dart

set +e
"$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" \
  --import-dill import.dill --resolve-private-names-in-library "$URI" \
  --packages .dart_tool/package_config.json \
  -o repl.bytecode repl.dart > compile.log 2>&1
compiled=$?
set -e

if [ "$compiled" -ne 0 ]; then
  echo "    OUTCOME: fails at COMPILE"
  { grep -m2 -iE "error|isn't defined" compile.log || true; } | sed 's/^/      /'
  check "the app reads the patched value" '<did not compile>' 'NEW'
else
  "$DART" "$RB/packaging/pack_patch.dart" --release-build-id "$BUILD_ID" \
    --out patch.sbrb --target "$URI#_Thing.value=$WORK/repl.bytecode" \
    >/dev/null 2>&1
  set +e
  "$AOT_RUNTIME" app.aot patch.sbrb > run.log 2>&1
  set -e
  grep -q '^APPLY' run.log && echo "    $(grep -m1 '^APPLY' run.log)"
  got=$(sed -n 's/^after .*thing=\([^ ]*\).*/\1/p' run.log | tail -1)
  got=${got:-'<no value>'}
  echo "    thing = $got"

  # WHICH failure, if it failed. Attach and bind fail in different places and mean
  # different things for the policy: attach failing says the CLASS capability was
  # needed; bind failing says the granted MEMBER was not reachable.
  if grep -qE "did not attach|refused" run.log; then
    echo "    OUTCOME: fails at ATTACH -- the target is a public method of a PRIVATE"
    echo "             class, and this policy grants no class capability"
  elif grep -q "Unable to find" run.log; then
    echo "    OUTCOME: fails at BIND -- $(grep -m1 'Unable to find' run.log | sed 's/^.*error: //')"
  elif [ "$got" = 'NEW' ]; then
    echo "    OUTCOME: PASSES -- a granted private member was reached through the"
    echo "             receiver, with no class capability"
  else
    echo "    OUTCOME: fails for an UNRELATED mechanism -- classify before choosing"
    sed 's/^/      /' run.log | head -6
  fi
  check "the app reads the patched value" "$got" 'NEW'
fi

echo
echo "--------------------------------------------------"
echo "p3_usability (--policy $POLICY): $pass passed, $fail failed"
echo "work dir kept: $WORK"
[ "$fail" -eq 0 ] || exit 1
