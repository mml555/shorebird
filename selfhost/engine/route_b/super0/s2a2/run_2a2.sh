#!/usr/bin/env bash
# cspell:words dartaotruntime dynmod
#
# run_2a2.sh -- D-SUPER-2A.2 execution leg.
#
# The intrinsic transports ONLY a source-level site description (origin class +
# member). dart2bytecode resolves the target with the IMPORT kernel's own
# hierarchy -- the same machinery ordinary `super` compilation already trusts --
# so no AOT-side synthetic identity crosses the boundary. That is the design
# D-SUPER-2A's stop pointed at, and this run is where it either works or does not.
#
# Throwaway compiler change, restored from a checksummed backup by a trap.
# dart2bytecode is run from SOURCE; no cell artifact is touched.
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
WORK="${WORK:-$(mktemp -d)}"
WHICH="${WHICH:-mixGo}"
MUTATE_VIRTUAL="${MUTATE_VIRTUAL:-0}"

DART_TREE="$SRC/flutter/third_party/dart"
DART="$OUT/dart-sdk/bin/dart"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
DART2BC="$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart"
GENERATOR="$DART_TREE/pkg/dart2bytecode/lib/bytecode_generator.dart"
GEN_SNAPSHOT="$OUT/gen_snapshot"
AOT_RUNTIME="$OUT/dartaotruntime"
TARGET_URI="package:dynamic_modules/target_2a2.dart"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }
mkdir -p "$WORK"

BACKUP="$(mktemp)"; cp "$GENERATOR" "$BACKUP"
before=$(shasum -a 256 "$GENERATOR" | cut -d' ' -f1)
restore() {
  cp "$BACKUP" "$GENERATOR"
  after=$(shasum -a 256 "$GENERATOR" | cut -d' ' -f1); rm -f "$BACKUP"
  [ "$after" = "$before" ] || { echo "FATAL: generator not restored" >&2; exit 3; }
  echo "dart2bytecode source restored, sha256 $after"
}
trap restore EXIT

note "injecting the LOCAL-RESOLUTION intrinsic (mutate=$MUTATE_VIRTUAL)"
python3 - "$GENERATOR" "$MUTATE_VIRTUAL" <<'PY'
import io, sys
path, mutate = sys.argv[1], sys.argv[2] == '1'
s = io.open(path, encoding='utf-8').read()
anchor = """    Arguments args = node.arguments;
    final target = node.target;
"""
assert s.count(anchor) == 1, 'anchor not found -- refusing to patch blindly'
emit = ("""      _genInstanceCall(node, InvocationKind.method, null,
          Name(memberName), args.positional[0], 1,
          objectTable.getArgDescHandle(1));"""
        if mutate else
        """      _genDirectCallWithArgs(resolved, noArgs,
          hasReceiver: true, isUnchecked: true, node: node);""")
inject = """    // D-SUPER-2A.2 THROWAWAY EXPERIMENT -- not a product feature.
    // Transports NO target identity. It receives the origin class and the member
    // name, and resolves the target with THIS kernel's own hierarchy.
    if (target.name.text == 'shorebirdSuperCall') {
      final libUri = (args.positional[1] as StringLiteral).value;
      final originName = (args.positional[2] as StringLiteral).value;
      final memberName = (args.positional[3] as StringLiteral).value;
      final lib =
          allLibraries.firstWhere((l) => l.importUri.toString() == libUri);
      final origin = lib.classes.firstWhere((c) => c.name == originName);
      final sup = origin.superclass;
      if (sup == null) {
        throw 'D-SUPER-2A.2: origin class has no superclass';
      }
      final resolvedMember = hierarchy.getDispatchTarget(
          sup, Name(memberName, memberName.startsWith('_') ? lib : null));
      if (resolvedMember is! Procedure) {
        // No virtual fallback, on purpose: a fallback turns a failed experiment
        // into a plausible pass.
        throw 'D-SUPER-2A.2: no dispatch target for ' + memberName;
      }
      final resolved = resolvedMember;
      final noArgs = Arguments(const <Expression>[])..parent = node;
      _genArguments(args.positional[0], noArgs);
%s
      return;
    }
""" % emit
io.open(path, 'w', encoding='utf-8').write(s.replace(anchor, anchor + inject, 1))
print('    injected')
PY

mkdir -p "$WORK/lib" "$WORK/.dart_tool"
cp "$HERE/target_2a2.dart" "$WORK/lib/target_2a2.dart"
cp "$HERE/replacement_$WHICH.dart" "$WORK/replacement.dart"
cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$WORK/",
    "packageUri": "lib/", "languageVersion": "3.9" } ] }
JSON
cd "$WORK"

note "release kernel + AOT snapshot"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o discover.dill "$TARGET_URI" >/dev/null
"$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
  "$HERE/../../gen_dynamic_interface.dart" --dill discover.dill --out di.yaml >/dev/null
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json \
  --dynamic-interface di.yaml -o target.dill "$TARGET_URI" >/dev/null
"$GEN_SNAPSHOT" --patchable_static_calls \
  --snapshot_kind=app-aot-elf --elf=target.aot target.dill

note "replacement bytecode, through the PATCHED compiler source"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
  --no-aot --no-link-platform \
  --packages .dart_tool/package_config.json -o host_import.dill "$TARGET_URI" >/dev/null
set +e
"$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" \
  --import-dill host_import.dill -o replacement.bytecode replacement.dart 2>&1 | tee compile.log
bc_rc=${PIPESTATUS[0]}
set -e
[ "$bc_rc" -eq 0 ] || { echo "RESULT: compiler refused the replacement (exit $bc_rc)"; exit 1; }

note "run"
echo "--------------------------------------------------"
set +e
"$AOT_RUNTIME" target.aot replacement.bytecode "$WHICH" "$TARGET_URI" 2>&1 | tee run.log
set -e
echo "--------------------------------------------------"

key=$([ "$WHICH" = "mixGo" ] && echo mix || echo deep)
baseline=$(grep -E "^unpatched $key super" run.log | sed 's/.*: //')
virtual=$(grep -E "^virtual $key" run.log | sed 's/.*: //')
patched=$(grep -E '^patched' run.log | sed 's/.*: //')
echo
echo "  unpatched super call : ${baseline:-<none>}"
echo "  virtual dispatch     : ${virtual:-<none>}"
echo "  patched replacement  : ${patched:-<none>}"
echo
if [ -z "$patched" ]; then
  echo "VERDICT: FAIL — no patched result."
elif [ "$patched" = "$baseline" ]; then
  echo "VERDICT: PASS — locally re-derived target reproduces the UNPATCHED"
  echo "  super call exactly, on the app's own stateful receiver, with no"
  echo "  target identity transported across the kernel boundary."
elif [ "$patched" = "$virtual" ]; then
  echo "VERDICT: FAIL — virtual dispatch; the override ran."
else
  echo "VERDICT: FAIL — $patched is neither the unpatched super result nor"
  echo "  the virtual one."
fi
echo
echo "work dir kept: $WORK"
