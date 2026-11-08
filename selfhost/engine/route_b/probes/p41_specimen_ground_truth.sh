#!/usr/bin/env bash
# cspell:words dartaotruntime prepass sbrb foldable
#
# p41_specimen_ground_truth.sh -- P4.1's specimen set, and the runtime truth a
# static probe will have to reproduce.
#
# THREE STATES IN ONE RELEASE, so the only variable is the target:
#
#   foldOpaque   opaque guard, called on the live path
#                -> surviving call site, executes. A patch CHANGES the value.
#   foldConst    FOLDABLE guard: the condition is compile-time true, so the body
#                is a constant and every call site substitutes it
#                -> the G15 shape. A patch attaches and changes NOTHING.
#   deadBranch   opaque, called only from a branch never taken at run time
#                -> call site SURVIVES, runtime never reaches it. A patch
#                   attaches and changes nothing, for a DIFFERENT reason.
#
# THE POINT OF THE SET. `foldConst` and `deadBranch` are indistinguishable from
# their outcome -- both leave the value unchanged -- and the engine reports
# `applied 1/1 targets` for all three. So the runtime report cannot tell any of
# them apart, which is exactly the silent-failure class P4.1 exists to catch, and
# why the eventual probe needs BOTH a `NO_SURVIVING_CALLSITE` result and the
# admission that a surviving call site is not reachability.
#
# THE SHAPE IS NOT ARBITRARY. It matches what `evidence/g15/foldability_verdict.txt`
# isolated: all three are TOP-LEVEL, identically signed, called from one caller on
# adjacent lines, and NONE carries a pragma. An earlier attempt used instance
# methods with `vm:never-inline` and DID NOT FOLD AT ALL -- the pragma and the
# receiver were both confounds, and the fixture reported a patch working where the
# G15 shape reports it inert.
#
# PRECOMMIT -- fixed before running.
#
#   | patch target | expected rendered `spec=` |
#   |--------------|---------------------------|
#   | (none)       | OPQ/CST                   |
#   | foldOpaque   | NEW-OPQ/CST               |
#   | foldConst    | OPQ/CST      (unchanged)  |
#   | deadBranch   | OPQ/CST      (unchanged)  |
#
#   STOP/INVALID: if `foldConst` renders NEW-CST the fixture is not folding and
#   the specimen set is void -- that is what the first attempt did.
#
# Host only. No device, no mint.
#
#   probes/p41_specimen_ground_truth.sh
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
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1));
  else echo "  FAIL  $1"; echo "        got : $2"; echo "        want: $3"
    fail=$((fail+1)); fi; }

[ -x "$DART" ] || die "no host dart at $DART"
echo "work: $WORK"
mkdir -p "$WORK/lib" "$WORK/.dart_tool"
cp "$RB/packaging/container_target.dart" "$WORK/lib/container_target.dart"
python3 - "$WORK/lib/container_target.dart" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace(
    "void _state(String when) =>",
    """// See this probe's header: top-level, identically signed, one caller, NO
// pragmas. The only intended difference is whether the guard is foldable.
String foldConst() => 1 > 0 ? 'CST' : 'X';

String foldOpaque() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OPQ' : 'X';

String deadBranch(String x) =>
    DateTime.now().millisecondsSinceEpoch >= 0 ? 'DBR-$x' : 'X';

String _specimenLine() {
  final live = '${foldOpaque()}/${foldConst()}';
  if (DateTime.now().millisecondsSinceEpoch < 0) {
    return '$live/${deadBranch('never')}';
  }
  return live;
}

void _state(String when) =>""",
    1,
)
s = s.replace(
    "print('$when alpha=${alpha()} beta=${beta()}');",
    "print('$when alpha=${alpha()} beta=${beta()} spec=${_specimenLine()}');",
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

note "release, with a v8 snapshot profile kept for the evidence-channel survey"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o prepass.dill "$URI" >/dev/null
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot \
  --no-link-platform --packages .dart_tool/package_config.json \
  -o import.dill "$URI" >/dev/null
# shellcheck disable=SC2086
"$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill prepass.dill \
  --private-dill import.dill --policy p2 --out di.yaml --manifest m.json \
  --sdk-members "$SDK" >/dev/null 2>&1
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
  -o release.dill "$URI" >/dev/null
"$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
  --elf=app.aot --write-v8-snapshot-profile-to=profile.json release.dill
BUILD_ID=$("$AOT_RUNTIME" app.aot | sed -n 's/^BUILD_ID //p')
[ -n "$BUILD_ID" ] || die "no release build id"
echo "    release: $BUILD_ID"
echo "    artifact sha256: $(shasum -a 256 app.aot | cut -c1-16)"

arm() { # <name> <selector> <expected spec> <body>
  cat > "r_$1.dart" <<EOF
import '$URI';

@pragma('dyn-module:entry-point')
$4
EOF
  "$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" --import-dill import.dill \
    --packages .dart_tool/package_config.json -o "r_$1.bytecode" "r_$1.dart" \
    >/dev/null 2>&1 || die "$1: the replacement did not compile"
  "$DART" "$RB/packaging/pack_patch.dart" --release-build-id "$BUILD_ID" \
    --out "p_$1.sbrb" --target "$URI#$2=$WORK/r_$1.bytecode" >/dev/null 2>&1
  local out got apply
  out=$("$AOT_RUNTIME" app.aot "p_$1.sbrb" 2>&1)
  apply=$(sed -n 's/^APPLY //p' <<<"$out" | head -1)
  got=$(sed -n 's/^after  *.*spec=\([^ ]*\).*/\1/p' <<<"$out" | tail -1)
  echo "    APPLY $apply"
  check "$1 renders $3" "$got" "$3"
}

note "runtime truth -- and note APPLY reports ok for ALL THREE"
arm opaque foldOpaque  'NEW-OPQ/CST' "String foldOpaque() => 'NEW-OPQ';"
arm const  foldConst   'OPQ/CST'     "String foldConst() => 'NEW-CST';"
arm dead   deadBranch  'OPQ/CST'     "String deadBranch(String x) => 'NEW-DBR';"

note "RESULT"
echo "  pass=$pass fail=$fail"
echo "  artifacts kept for the evidence-channel survey: $WORK"
echo "    app.aot, release.dill, profile.json, di.yaml, m.json"
[ "$fail" -gt 0 ] && { echo "  VERDICT: RED -- the specimen set is not valid"; exit 1; }
echo "  VERDICT: GREEN -- three distinct states, one artifact, and the runtime"
echo "           report distinguishes none of them"
