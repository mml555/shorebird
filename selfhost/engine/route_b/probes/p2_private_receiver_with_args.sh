#!/usr/bin/env bash
# cspell:words dartaotruntime prepass ungranted sbrb
#
# p2_private_receiver_with_args.sh -- P2's untested combination: a replacement for
# a method of a PRIVATE class that declares the target's OWN PARAMETERS.
#
# WHY THIS ARM EXISTS. The two halves are each proven and neither implies the
# other:
#
#   P1  (p1_bind_private_receiver.sh, 8/8)  a private RECEIVER class, lowered to
#       `dynamic self`, reading private members -- with NO arguments.
#   G3.7 (g37_param_abi.sh, 4/4)            required positional ARGUMENTS arriving
#       in order and by type -- on a PUBLIC receiver, `Params`.
#
# The combination is what a real Flutter patch looks like -- `_FooState.build`
# takes a BuildContext -- and it is exactly where the two lowerings meet: the
# producer prepends `dynamic self` to a verbatim-copied parameter list, so the
# receiver becomes argument 0 and the source's own parameters shift by one. If
# that shift is off by one, or if `dynamic` weakens the argument binding, this is
# where it shows.
#
# PRECOMMIT -- fixed before running.
#
#   | arm | replacement for a method of a PRIVATE class          | expect  |
#   |-----|------------------------------------------------------|---------|
#   | D0  | takes (String, int), body uses BOTH arguments        | PASS    |
#   | D1  | takes (String, int) AND reads a granted private field| PASS    |
#   | D2  | ORDER/TYPE: swapping the two arguments must change    | PASS    |
#   |     | the rendered value -- arity alone must not satisfy it |         |
#   | D3  | takes a NAMED parameter                              | REFUSE  |
#
#   STOP/INVALID rows, scored as "no result":
#     * D0 does not PASS -- the combination does not work and D1/D2 say nothing
#     * D2 renders the same string as D0 -- then the test cannot see order at
#       all and its PASS is vacuous
#
# Host only. No device, no mint, no cell change.
#
#   probes/p2_private_receiver_with_args.sh
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
    """// A PRIVATE class whose patch target takes ITS OWN PARAMETERS. Both halves of
// P2's combination in one declaration.
class _ArgState {
  final String _hidden =
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'H' : 'X';

  // THE TARGET: a public method of a private class, with two required
  // positionals. The release body ignores them so the OLD value cannot depend on
  // argument binding -- only the replacement's does.
  @pragma('vm:never-inline')
  String render(String label, int count) =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD' : 'X';

  // Refused shape, for D3.
  @pragma('vm:never-inline')
  String named({String label = 'n'}) =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-n' : 'X';
}

final _argState = _ArgState();

void _state(String when) =>""",
    1,
)
s = s.replace(
    "print('$when alpha=${alpha()} beta=${beta()}');",
    "print('$when alpha=${alpha()} beta=${beta()} "
    "arg=${_argState.render('L', 7)}');",
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

note "release, and the interface the current generator emits"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o prepass.dill "$URI" >/dev/null
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot \
  --no-link-platform --packages .dart_tool/package_config.json \
  -o import.dill "$URI" >/dev/null
# shellcheck disable=SC2086
"$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill prepass.dill \
  --private-dill import.dill --policy p2 --out di.yaml --manifest m.json \
  --sdk-members "$SDK" 2>&1 | sed -n 's/^/    /p'
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
  -o release.dill "$URI" >/dev/null
"$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
  --elf=app.aot release.dill
BUILD_ID=$("$AOT_RUNTIME" app.aot | sed -n 's/^BUILD_ID //p')
[ -n "$BUILD_ID" ] || die "no release build id"
echo "    release: $BUILD_ID"

arm() { # <name> <expect PASS|REFUSE> <target> <body>
  local name=$1 expect=$2 target=$3 body=$4
  note "$name -- expect $expect"
  cat > "repl_$name.dart" <<EOF
import '$URI';

@pragma('dyn-module:entry-point')
$body
EOF
  echo "    | $(grep -m1 -E 'String (render|named)' "repl_$name.dart")"
  set +e
  "$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" --import-dill import.dill \
    --resolve-private-names-in-library "$URI" \
    --packages .dart_tool/package_config.json \
    -o "repl_$name.bytecode" "repl_$name.dart" > "compile_$name.log" 2>&1
  local crc=$?
  set -e
  local outcome
  if [ "$crc" -ne 0 ]; then
    outcome=COMPILE
    grep -m1 -iE "error|entry point" "compile_$name.log" | sed 's/^/      /' || true
  else
    "$DART" "$RB/packaging/pack_patch.dart" --release-build-id "$BUILD_ID" \
      --out "patch_$name.sbrb" \
      --target "$URI#$target=$WORK/repl_$name.bytecode" >/dev/null 2>&1
    set +e
    "$AOT_RUNTIME" app.aot "patch_$name.sbrb" > "run_$name.log" 2>&1
    set -e
    local got
    got=$(sed -n 's/^after  *.*arg=\([^ ]*\).*/\1/p' "run_$name.log" | tail -1)
    echo "      $(grep -m1 '^APPLY' "run_$name.log" || echo 'APPLY <none>')"
    echo "      arg = ${got:-<no value>}"
    if grep -m1 '^APPLY' "run_$name.log" | grep -q refused; then outcome=ATTACH
    elif [ -z "$got" ]; then
      outcome=BIND
      sed -n '/^APPLY/,$p' "run_$name.log" | grep -m1 -iE "error|exception" \
        | sed 's/^/        /' || true
    elif [ "$got" = OLD ]; then outcome=SILENT-OLD
    else outcome=PASS; RENDERED=$got; fi
  fi
  echo "    OUTCOME: $outcome"
  if [ "$expect" = PASS ]; then check "$name binds arguments and runs" "$outcome" "PASS"
  else check "$name is refused" "$([ "$outcome" = PASS ] && echo PASS || echo refused)" "refused"
       echo "      refused at: $outcome"; fi
  ARM=$outcome
}

arm D0 PASS "_ArgState.render" \
  "String render(dynamic self, String label, int count) => 'A-\$label-\$count';"
d0=$ARM; d0v=${RENDERED:-}
[ "$d0" != PASS ] && invalidate "D0 is the STOP row: the combination does not work"

arm D1 PASS "_ArgState.render" \
  "String render(dynamic self, String label, int count) => 'B-\$label-\$count-\${self._hidden}';"

# ORDER AND TYPE, not arity: the two arguments are rendered in the OPPOSITE order,
# so a lowering that merely got the count right cannot produce this string.
arm D2 PASS "_ArgState.render" \
  "String render(dynamic self, String label, int count) => 'A-\$count-\$label';"
d2v=${RENDERED:-}
if [ -n "$d0v" ] && [ "$d0v" = "$d2v" ]; then
  invalidate "D2 rendered the same string as D0 ($d0v) -- this arm cannot see argument order"
else
  echo "    D0 rendered $d0v ; D2 rendered $d2v  (order is observable)"
fi

arm D3 REFUSE "_ArgState.named" \
  "String named(dynamic self, {String label = 'n'}) => 'C-\$label';"

note "RESULT"
echo "  pass=$pass fail=$fail invalid=$invalid"
echo "  work dir kept: $WORK"
[ "$invalid" -gt 0 ] && { echo "  VERDICT: INVALID"; exit 3; }
[ "$fail" -gt 0 ] && { echo "  VERDICT: RED"; exit 1; }
echo "  VERDICT: GREEN -- a private receiver and the target's own arguments compose"
