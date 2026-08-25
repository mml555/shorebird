#!/usr/bin/env bash
# cspell:words dartaotruntime prepass callsite CALLSITES unmutated localcell nogate
#
# p41_producer_end_to_end.sh -- P4.1 through the ACTUAL PRODUCER.
#
# Everything before this proved the instrument. This proves the PRODUCT: the
# CLI's own coverage analyzer, its own survival oracle running the cell's real
# `route_b_release_probe.aot`, and `RouteBProducer.produce` making the
# publication decision. A refusal printed here is the refusal a user would see.
#
# The specimen set is the same three functions, and the point is unchanged: the
# runtime cannot tell them apart. All three attach and report `applied 1/1
# targets`; only a static fact separates them.
#
# PRECOMMIT -- fixed before running.
#
#   | patched target | gate | expected                                        |
#   |----------------|------|-------------------------------------------------|
#   | foldOpaque     | on   | PUBLISHED                                       |
#   | deadBranch     | on   | PUBLISHED  <- permanent control, never executed |
#   | foldConst      | on   | REFUSED, "no surviving call site"               |
#   | foldConst      | OFF  | PUBLISHED  <- the mutation: gate is load-bearing|
#   | foldOpaque     | on, wrong artifact digest | REFUSED, UNKNOWN, and NOT |
#   |                |      | worded as absence                               |
#
#   STOP/INVALID: if the foldConst-with-gate-OFF arm REFUSES, then something
#   other than the gate is refusing and every row above is uninterpretable.
#   If deadBranch is refused, the instrument has been re-worded as reachability
#   and the claim is no longer the one the evidence supports.
#
# Host only. No device, no mint -- the cell zip is staged locally from
# $OUT/zip_archives, which is a real 8-file cell that simply was not published.
#
#   probes/p41_producer_end_to_end.sh
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
HERE=${HERE:-"$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"}
RB=${RB:-"$(cd "$HERE/.." >/dev/null 2>&1 && pwd)"}
REPO=${REPO:-"$(cd "$RB/../../.." >/dev/null 2>&1 && pwd)"}
WORK=${WORK:-$(mktemp -d)}

if [ "${SELF_SNAPSHOT:-}" != "1" ]; then
  SNAP=$(mktemp); cat "${BASH_SOURCE[0]}" > "$SNAP"
  SELF_SNAPSHOT=1 WORK="$WORK" RB="$RB" REPO="$REPO" HERE="$HERE" \
    exec bash "$SNAP" "$@"
fi

DART_TREE=$SRC/flutter/third_party/dart
DART=$OUT/dart-sdk/bin/dart
KERNEL_PKGS="--packages=$DART_TREE/.dart_tool/package_config.json"
GEN_KERNEL=$DART_TREE/pkg/vm/bin/gen_kernel.dart
GEN_SNAPSHOT=$OUT/gen_snapshot
PKGS_DIR=$DART_TREE/third_party/pkg/core/pkgs
ZIPS=$OUT/zip_archives
LIB=package:dynamic_modules/container_target.dart

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1));
  else echo "  FAIL  $1"; echo "        got : $2"; echo "        want: $3"
    fail=$((fail+1)); fi; }

[ -x "$DART" ] || die "no host dart at $DART"
[ -f "$ZIPS/route_b_release_probe.aot" ] \
  || die "no release probe — run build_route_b_release_probe.sh first"
echo "work: $WORK"

# ---- a real 8-file cell, staged locally ------------------------------------
note "staging a local cell (the 8 real artifacts, unpublished)"
STAGE="$WORK/cell"; mkdir -p "$STAGE"
cp "$ZIPS/dart2bytecode_aot.snapshot" "$STAGE/dart2bytecode.aot"
cp "$OUT/dartaotruntime" "$STAGE/dartaotruntime"
cp "$OUT/vm_platform.dill" "$STAGE/vm_platform.dill"
cp "$ZIPS/route_b_analyze.aot" "$STAGE/route_b_analyze.aot"
cp "$ZIPS/route_b_gen_kernel.aot" "$STAGE/route_b_gen_kernel.aot"
cp "$ZIPS/route_b_gen_dynamic_interface.aot" \
   "$STAGE/route_b_gen_dynamic_interface.aot"
cp "$ZIPS/route_b_release_probe.aot" "$STAGE/route_b_release_probe.aot"
# The harness redirects the Flutter platform to the VM one (declared deviation),
# but the file must exist for the cell to resolve at all.
cp "$OUT/vm_platform.dill" "$STAGE/flutter_platform_strong.dill"
chmod +x "$STAGE/dartaotruntime"
ENGINE_HASH=localcell$(date -u +%s 2>/dev/null || echo 0)
{
  echo "Route B producer tooling — local cell for $0"
  echo "engine revision  : $ENGINE_HASH"
  echo "dart revision    : local"
  for f in dart2bytecode.aot dartaotruntime vm_platform.dill \
           route_b_analyze.aot route_b_gen_kernel.aot \
           route_b_gen_dynamic_interface.aot route_b_release_probe.aot \
           flutter_platform_strong.dill; do
    echo "$f : $(shasum -a 256 "$STAGE/$f" | cut -d' ' -f1)"
  done
} > "$STAGE/PROVENANCE.txt"
CELL_ZIP="$WORK/cell.zip"
(cd "$STAGE" && zip -q -r -y "$CELL_ZIP" .)
echo "    cell: $(unzip -l "$CELL_ZIP" | tail -1)"

# ---- the release ----------------------------------------------------------
APP="$WORK/app"; mkdir -p "$APP/lib" "$APP/.dart_tool"
cp "$RB/packaging/container_target.dart" "$APP/lib/container_target.dart"
python3 - "$APP/lib/container_target.dart" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace("void _state(String when) =>", """String foldConst() => 1 > 0 ? 'CST' : 'X';

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

void _state(String when) =>""", 1)
s = s.replace("print('$when alpha=${alpha()} beta=${beta()}');",
              "print('$when alpha=${alpha()} beta=${beta()} spec=${_specimenLine()}');", 1)
p.write_text(s)
PY
cat > "$APP/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$APP/", "packageUri": "lib/",
    "languageVersion": "3.9" },
  { "name": "crypto", "rootUri": "file://$PKGS_DIR/crypto", "packageUri": "lib/",
    "languageVersion": "3.4" },
  { "name": "typed_data", "rootUri": "file://$PKGS_DIR/typed_data",
    "packageUri": "lib/", "languageVersion": "3.4" } ] }
JSON
SDK='dart:core#print,dart:core#DateTime.now,dart:core#DateTime.get:millisecondsSinceEpoch'
cd "$APP"

note "the release, its interface, and its snapshot profile"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o "$WORK/prepass.dill" "$LIB" >/dev/null
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot \
  --no-link-platform --packages .dart_tool/package_config.json \
  -o "$WORK/import.dill" "$LIB" >/dev/null
# shellcheck disable=SC2086
"$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill "$WORK/prepass.dill" \
  --private-dill "$WORK/import.dill" --policy p2 --out "$WORK/di.yaml" \
  --manifest "$WORK/m.json" --sdk-members "$SDK" >/dev/null 2>&1
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json --dynamic-interface "$WORK/di.yaml" \
  -o "$WORK/base.dill" "$LIB" >/dev/null
"$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-assembly \
  --assembly="$WORK/app.S" \
  --write-v8-snapshot-profile-to="$WORK/profile.json" "$WORK/base.dill"
ART=$(shasum -a 256 "$WORK/app.S" | cut -d' ' -f1)
cat > "$WORK/binding.json" <<JSON
{ "profile_format_revision": "v8-snapshot-profile/gen_snapshot",
  "probe_revision": 1,
  "cell_id": "$ENGINE_HASH",
  "release_artifact_sha256": "$ART" }
JSON
echo "    artifact $(echo "$ART" | cut -c1-16)"

# ---- one patched kernel per arm -------------------------------------------
patched() { # <name> <sed-from> <sed-to>  -> writes $WORK/patched_<name>.dill
  local name=$1 from=$2 to=$3
  local dir="$WORK/patch_$name"; mkdir -p "$dir/lib" "$dir/.dart_tool"
  python3 - "$APP/lib/container_target.dart" "$dir/lib/container_target.dart" \
    "$from" "$to" <<'PY'
import sys, pathlib
src, dst, a, b = sys.argv[1:5]
s = pathlib.Path(src).read_text()
if a not in s: raise SystemExit(f'patch anchor missing: {a}')
pathlib.Path(dst).write_text(s.replace(a, b, 1))
PY
  sed "s|file://$APP/|file://$dir/|" "$APP/.dart_tool/package_config.json" \
    > "$dir/.dart_tool/package_config.json"
  (cd "$dir" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
    --packages .dart_tool/package_config.json \
    --dynamic-interface "$WORK/di.yaml" \
    -o "$WORK/patched_$name.dill" "$LIB" >/dev/null)
}

note "patched kernels, one changed function each"
patched opaque "? 'OPQ' : 'X'" "? 'NEW-OPQ' : 'X'"
patched const  "? 'CST' : 'X'" "? 'NEW-CST' : 'X'"
patched dead   "? 'DBR-\$x' : 'X'" "? 'NEW-DBR-\$x' : 'X'"

# ---- drive the real producer ---------------------------------------------
run_arm() { # <name> <patched.dill> <artifact-sha> [--no-gate]
  local name=$1 dill=$2 art=$3; shift 3
  local out="$WORK/out_$name.txt"
  set +e
  "$DART" --packages="$REPO/.dart_tool/package_config.json" \
    "$HERE/cli_survival.dart" "$CELL_ZIP" "$WORK/base.dill" "$dill" \
    "$WORK/import.dill" deadbeef "$WORK/work_$name" "$APP" \
    "$OUT/vm_platform.dill" "$ENGINE_HASH" "$WORK/profile.json" \
    "$WORK/binding.json" "$art" "$@" > "$out" 2>&1
  local rc=$?
  set -e
  sed -n '1,12p' "$out" | sed 's/^/      /'
  echo "$rc"
}

verdict() { grep -o 'VERDICT  : [A-Z_]*' "$WORK/out_$1.txt" | head -1 \
  | sed 's/VERDICT  : //'; }

note "ARM 1 -- foldOpaque, gate on"
run_arm opaque "$WORK/patched_opaque.dill" "$ART" >/dev/null
check "foldOpaque publishes" "$(verdict opaque)" PUBLISHED

note "ARM 2 -- deadBranch, gate on (the permanent control)"
run_arm dead "$WORK/patched_dead.dill" "$ART" >/dev/null
check "deadBranch publishes: a surviving call site that never runs" \
  "$(verdict dead)" PUBLISHED

note "ARM 3 -- foldConst, gate on"
run_arm const "$WORK/patched_const.dill" "$ART" >/dev/null
check "foldConst is REFUSED" "$(verdict const)" REFUSED
check "  ...and names the release as the cause" \
  "$([ "$(grep -c 'no surviving call site' "$WORK/out_const.txt" || true)" \
      -ge 1 ] && echo named || echo absent)" named
check "  ...and tells the operator what would fix it" \
  "$([ "$(grep -c 'remediation is a new release' "$WORK/out_const.txt" || true)" \
      -ge 1 ] && echo told || echo silent)" told

note "ARM 4 -- foldConst with the GATE REMOVED (the mutation)"
run_arm const_nogate "$WORK/patched_const.dill" "$ART" --no-gate >/dev/null
check "the inert patch publishes once the gate is gone" \
  "$(verdict const_nogate)" PUBLISHED

note "ARM 5 -- foldOpaque against a profile bound to another artifact"
run_arm mismatch "$WORK/patched_opaque.dill" "$(printf '0%.0s' {1..64})" >/dev/null
check "binding mismatch is REFUSED" "$(verdict mismatch)" REFUSED
# Was written as grep -c compared to itself, which cannot fail and certified
# nothing. The refusal must NAME the instrument result, so require at least one.
check "  ...as UNKNOWN, naming the instrument result" \
  "$([ "$(grep -c 'ARTIFACT_BINDING_MISMATCH' "$WORK/out_mismatch.txt" || true)" \
      -ge 1 ] && echo named || echo absent)" named
check "  ...and NOT as absence" \
  "$(grep -c 'attach and change nothing' "$WORK/out_mismatch.txt" || true)" 0
check "  ...saying explicitly that it is not a finding of absence" \
  "$([ "$(grep -c 'NOT a finding that the call site is absent' \
      "$WORK/out_mismatch.txt" || true)" -ge 1 ] && echo said || echo silent)" said

note "PASS=$pass FAIL=$fail"
echo "work dir kept: $WORK"
[ "$fail" -eq 0 ]
