#!/usr/bin/env bash
# cspell:words dartaotruntime dynmod
#
# run_1b.sh -- D-SUPER-1B. Can a DirectCall carry the app object as receiver and
# invoke an EXACT instance Procedure of the release?
#
# This is the B/C boundary. 1A proved a dynamic module can reference an app
# Procedure; it did not prove such a reference can take a receiver, which is a
# separate fact.
#
# A THROWAWAY compiler change is applied to the engine tree's dart2bytecode
# SOURCE (never to the cell, never to a published artifact) and restored from a
# checksummed backup by a trap. dart2bytecode is run from source here, exactly as
# ../../verify_binding.sh does, so no cell artifact is involved at any point.
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
WORK="${WORK:-$(mktemp -d)}"
MUTATE_VIRTUAL="${MUTATE_VIRTUAL:-0}"

DART_TREE="$SRC/flutter/third_party/dart"
DART="$OUT/dart-sdk/bin/dart"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
DART2BC="$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart"
GENERATOR="$DART_TREE/pkg/dart2bytecode/lib/bytecode_generator.dart"
GEN_SNAPSHOT="$OUT/gen_snapshot"
AOT_RUNTIME="$OUT/dartaotruntime"
TARGET_URI="package:dynamic_modules/target_1b.dart"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }

grep -q 'dart_dynamic_modules = true' "$OUT/args.gn" 2>/dev/null \
  || die "dart_dynamic_modules is not true in $OUT/args.gn"

BACKUP="$(mktemp)"
cp "$GENERATOR" "$BACKUP"
before=$(shasum -a 256 "$GENERATOR" | cut -d' ' -f1)
restore() {
  cp "$BACKUP" "$GENERATOR"
  after=$(shasum -a 256 "$GENERATOR" | cut -d' ' -f1)
  rm -f "$BACKUP"
  [ "$after" = "$before" ] || { echo "FATAL: generator not restored" >&2; exit 3; }
  echo "dart2bytecode source restored, sha256 $after"
}
trap restore EXIT

note "applying the THROWAWAY direct-call intrinsic to dart2bytecode source"
python3 - "$GENERATOR" "$MUTATE_VIRTUAL" <<'PY'
import io, sys
path, mutate = sys.argv[1], sys.argv[2] == '1'
s = io.open(path, encoding='utf-8').read()
# Inserted AFTER these two declarations: the first attempt put the block in
# front of them and every reference to `args`/`target` failed to resolve. The
# trailing comment line is deliberately NOT part of the anchor, so the injected
# block lands between the declarations and it.
anchor = """    Arguments args = node.arguments;
    final target = node.target;
"""
assert s.count(anchor) == 1, 'anchor not found -- refusing to patch blindly'

# MUTATION ARM: emit an ordinary VIRTUAL call instead of the direct one. The
# probe must then report C:APP-STATE. If it still reports P:APP-STATE, the
# result was never coming from the direct call and the experiment proves nothing.
# A WELL-FORMED virtual call, not malformed bytecode. The first mutation pushed
# no receiver and declared two arguments; it segfaulted, which discriminates but
# only proves the direct call is load-bearing. A correct virtual call must return
# C:APP-STATE -- the specific failure mode this specimen exists to name.
call = ("""      _genInstanceCall(node, InvocationKind.method, null,
          Name(memberName), args.positional[0], 1,
          objectTable.getArgDescHandle(1));"""
        if mutate else
        """      _genDirectCallWithArgs(exact, noArgs,
          hasReceiver: true, isUnchecked: true, node: node);""")
pre = """      _genArguments(args.positional[0], noArgs);"""

inject = """    // D-SUPER-1B THROWAWAY EXPERIMENT -- not a product feature. Removed by the
    // harness from a checksummed backup.
    if (target.name.text == 'shorebirdDirectCall') {
      final libUri = (args.positional[1] as StringLiteral).value;
      final clsName = (args.positional[2] as StringLiteral).value;
      final memberName = (args.positional[3] as StringLiteral).value;
      final lib = allLibraries
          .firstWhere((l) => l.importUri.toString() == libUri);
      final cls = lib.classes.firstWhere((c) => c.name == clsName);
      final exact =
          cls.procedures.firstWhere((p) => p.name.text == memberName);
      final noArgs = Arguments(const <Expression>[])..parent = node;
%s
%s
      return;
    }
""" % (pre, call)
io.open(path, 'w', encoding='utf-8').write(s.replace(anchor, anchor + inject, 1))
print('    intrinsic injected%s' % ('  [MUTATION: virtual call]' if mutate else ''))
PY

mkdir -p "$WORK/lib" "$WORK/.dart_tool"
cp "$HERE/target_1b.dart" "$WORK/lib/target_1b.dart"
cp "$HERE/replacement_1b.dart" "$WORK/replacement.dart"
cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$WORK/",
    "packageUri": "lib/", "languageVersion": "3.9" } ] }
JSON
cd "$WORK"

note "1/5 discovery kernel"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o discover.dill "$TARGET_URI" >/dev/null

note "2/5 dynamic interface"
"$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
  "$HERE/../../gen_dynamic_interface.dart" --dill discover.dill --out di.yaml >/dev/null
sed 's/^/    /' di.yaml | grep -v '^    #' | head -12

note "3/5 release kernel + AOT snapshot"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json \
  --dynamic-interface di.yaml -o target.dill "$TARGET_URI" >/dev/null
"$GEN_SNAPSHOT" --patchable_static_calls \
  --snapshot_kind=app-aot-elf --elf=target.aot target.dill

note "4/5 replacement bytecode, through the PATCHED compiler source"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
  --no-aot --no-link-platform \
  --packages .dart_tool/package_config.json -o host_import.dill "$TARGET_URI" >/dev/null
set +e
"$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" \
  --import-dill host_import.dill -o replacement.bytecode replacement.dart \
  2>&1 | tee compile.log
bc_rc=${PIPESTATUS[0]}
set -e
[ "$bc_rc" -eq 0 ] || { echo "RESULT: the compiler refused the replacement (exit $bc_rc)"; exit 1; }
echo "    payload: $(wc -c < replacement.bytecode | tr -d ' ') bytes"

note "5/5 run"
echo "--------------------------------------------------"
set +e
"$AOT_RUNTIME" target.aot replacement.bytecode "$TARGET_URI" 2>&1 | tee run.log
set -e
echo "--------------------------------------------------"

echo
got=$(grep -oE '(P|C):[A-Z-]+' run.log | sed -n '2p' || true)
got=$(grep -E '^after  direct' run.log | sed 's/.*: //' || true)
echo "direct-call result : ${got:-<none>}"
case "$got" in
  P:APP-STATE)
    echo "VERDICT: PASS — exact Parent.read AND the app's own Child receiver."
    echo "  Not virtual dispatch (that is C:APP-STATE) and not a lookalike"
    echo "  instance (that is P:UNSET)." ;;
  C:APP-STATE)
    echo "VERDICT: FAIL — virtual dispatch. The override ran." ;;
  P:UNSET)
    echo "VERDICT: FAIL — correct target, WRONG receiver." ;;
  *)
    echo "VERDICT: FAIL — no usable result; see run.log above." ;;
esac
echo
echo "work dir kept: $WORK"
