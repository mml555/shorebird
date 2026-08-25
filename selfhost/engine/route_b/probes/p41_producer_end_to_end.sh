#!/usr/bin/env bash
# cspell:words dartaotruntime prepass callsite CALLSITES unmutated localcell nogate sigdir nobind
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
#   | foldOpaque     | on, LEGACY release with no profile | REFUSED as UNKNOWN,|
#   |                |      | naming RELEASE_EVIDENCE_ABSENT                  |
#   | foldOpaque, String->Object, --bound | REFUSED, TARGET_SIGNATURE_CHANGED |
#   | the same, binding removed           | PUBLISHED -- P4.4's mutation arm  |
#   | foldOpaque body edit, --bound   | PUBLISHED -- binding on is not a veto |
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

# ---- the cell ---------------------------------------------------------------
# CELL_ZIP lets this run against a PUBLISHED, fetched-back bundle instead of a
# locally staged one. That is the difference between "the source I just built
# behaves" and "the artifact a consumer downloads behaves", and only the second
# qualifies a mint. ENGINE_HASH must then be the hash the bundle records, since
# the resolver refuses a bundle filed under another.
if [ -n "${CELL_ZIP:-}" ]; then
  [ -f "$CELL_ZIP" ] || die "no cell zip at $CELL_ZIP"
  [ -n "${ENGINE_HASH:-}" ] || die "CELL_ZIP needs ENGINE_HASH (the published hash)"
  note "using a PUBLISHED cell: $CELL_ZIP"
  echo "    sha256: $(shasum -a 256 "$CELL_ZIP" | cut -c1-32)"
  echo "    engine: $ENGINE_HASH"
  # The consumer path must exercise the FETCHED probe. Prove it is in there and
  # say which bytes, so a bundle that silently lacks it cannot read as a pass.
  # NOT `unzip -l | grep -q`: grep exits at the first match and closes the pipe,
  # unzip takes SIGPIPE, and `set -o pipefail` turns a SUCCESSFUL match into a
  # failed pipeline. That reported the probe as ABSENT from a bundle the audit
  # had just confirmed contains it.
  [ "$(unzip -l "$CELL_ZIP" | grep -c route_b_release_probe.aot)" -ge 1 ] \
    || die "the published bundle carries no route_b_release_probe.aot"
  PW=$(mktemp -d)
  unzip -q -o "$CELL_ZIP" route_b_release_probe.aot -d "$PW"
  echo "    probe : $(shasum -a 256 "$PW/route_b_release_probe.aot" | cut -c1-32)"
  rm -rf "$PW"
else
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
ENGINE_HASH=${ENGINE_HASH:-localcell$(date -u +%s 2>/dev/null || echo 0)}
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
fi

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

# P4.4. A SHAPE change on one member and nothing else. The release's compiled
# call sites expect the release's return type, and they carry the release's own
# argument descriptor -- so a replacement of a different shape cannot be called
# correctly by them, and no runtime report would say so.
sigdir="$WORK/patch_sig"; mkdir -p "$sigdir/lib" "$sigdir/.dart_tool"
python3 - "$APP/lib/container_target.dart" "$sigdir/lib/container_target.dart" <<'PY'
import sys, pathlib
src, dst = sys.argv[1], sys.argv[2]
s = pathlib.Path(src).read_text()
# RETURN TYPE, not arity. An arity change also breaks the CALLER's replacement
# at compile time -- a real consequence, but it refuses on `_specimenLine`
# first (sorted before `foldOpaque`) and the signature gate never runs. A
# return-type change leaves the caller's source byte-identical, so `foldOpaque`
# is the only changed member and the arm tests exactly one thing.
s = s.replace("String foldOpaque() =>", "Object foldOpaque() =>", 1)
pathlib.Path(dst).write_text(s)
PY
sed "s|file://$APP/|file://$sigdir/|" "$APP/.dart_tool/package_config.json" \
  > "$sigdir/.dart_tool/package_config.json"
(cd "$sigdir" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json --dynamic-interface "$WORK/di.yaml" \
  -o "$WORK/patched_sig.dill" "$LIB" >/dev/null)

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

note "ARM 6 -- a LEGACY release that uploaded no profile at all"
run_arm legacy "$WORK/patched_opaque.dill" "$ART" --no-profile >/dev/null
check "a release with no evidence is REFUSED" "$(verdict legacy)" REFUSED
check "  ...naming the missing sidecar" \
  "$([ "$(grep -c 'RELEASE_EVIDENCE_ABSENT' "$WORK/out_legacy.txt" || true)" \
      -ge 1 ] && echo named || echo absent)" named
check "  ...and NOT as absence of a call site" \
  "$(grep -c 'attach and change nothing' "$WORK/out_legacy.txt" || true)" 0

note "ARM 7 -- P4.4: a SHAPE CHANGE, bound to the release"
run_arm sig "$WORK/patched_sig.dill" "$ART" --bound >/dev/null
check "a changed shape is REFUSED" "$(verdict sig)" REFUSED
check "  ...named as a signature change" \
  "$([ "$(grep -c 'TARGET_SIGNATURE_CHANGED' "$WORK/out_sig.txt" || true)" \
      -ge 1 ] && echo named || echo absent)" named
check "  ...showing both shapes" \
  "$([ "$(grep -c -- '->dart.core::Object' "$WORK/out_sig.txt" \
      || true)" -ge 1 ] && echo shown || echo hidden)" shown

note "ARM 8 -- the same shape change with the BINDING REMOVED (the mutation)"
run_arm sig_nobind "$WORK/patched_sig.dill" "$ART" >/dev/null
check "it publishes once nothing is bound" "$(verdict sig_nobind)" PUBLISHED

note "ARM 9 -- the ordinary body edit is still bound and still publishes"
run_arm opaque_bound "$WORK/patched_opaque.dill" "$ART" --bound >/dev/null
check "an unchanged shape publishes WITH the binding on" \
  "$(verdict opaque_bound)" PUBLISHED

note "PASS=$pass FAIL=$fail"
echo "work dir kept: $WORK"
[ "$fail" -eq 0 ]
