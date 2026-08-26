#!/usr/bin/env bash
# cspell:words dartaotruntime prepass CALLSITES nogate APPDIR appdir DBUILD dropref obfusc pdir tgart
#
# p5_build_identity_matrix.sh -- P5's MEASUREMENT, before any build_identity is
# designed.
#
# THE QUESTION, narrower than "does the build command match":
#
#   Can a patch ever be produced against build semantics different from the
#   exact release it targets, while the existing P4 bindings still accept it?
#
# ONE VARIABLE PER ROW. Release A and variant B differ in exactly one input, and
# for each the run records what ALREADY differs before asking whether the
# cross-patch is refused:
#
#   release build id · release kernel digest · artifact digest · dynamic
#   interface digest · capability manifest digest · snapshot profile digest ·
#   the product's own build-config canonical form and fingerprint
#
# WHERE THE CATCH WOULD HAPPEN MATTERS, and this run distinguishes three places
# rather than reporting one verdict:
#
#   COVERAGE  the analyzer refuses, comparing A's kernel to B's
#   PRODUCER  a P4 gate refuses (exercised here through the real producer)
#   CONFIG    RouteBBuildConfig.agreesWith says no -- the G4.1 check that lives
#             in the PATCHER, invoked here directly because this harness drives
#             the producer, not the patcher. Reported as the product's answer,
#             not as something this run observed the patcher do.
#
# NO PRECOMMITTED VERDICTS. This is a measurement: the point is to find out
# whether P5 is one missing gate or mostly existing gates with incomplete
# provenance. The one thing fixed in advance is the SHAPE of the answer -- every
# row reports what differs and where, and a row where NOTHING differs and
# NOTHING refuses is the finding, not a failure of the harness.
#
# THE IDENTICAL CONTROL EARNS ITS PLACE: if A-vs-A refused, every other row
# would be uninterpretable.
#
# Host only. No device, no mint.
#
#   probes/p5_build_identity_matrix.sh
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
AOT_RUNTIME=$OUT/dartaotruntime
PKGS_DIR=$DART_TREE/third_party/pkg/core/pkgs
ZIPS=$OUT/zip_archives

# The shared rule: a tool that fails SILENTLY is the harness, not a refusal.
# shellcheck source=probes/harness_guard.sh
. "$HERE/harness_guard.sh"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }
[ -x "$DART" ] || die "no host dart at $DART"
echo "work: $WORK"

# ---- a local cell, so the producer's P4 gates are the real ones -------------
STAGE="$WORK/cell"; mkdir -p "$STAGE"
cp "$ZIPS/dart2bytecode_aot.snapshot" "$STAGE/dart2bytecode.aot"
cp "$OUT/dartaotruntime" "$STAGE/dartaotruntime"
cp "$OUT/vm_platform.dill" "$STAGE/vm_platform.dill"
cp "$ZIPS/route_b_analyze.aot" "$STAGE/route_b_analyze.aot"
cp "$ZIPS/route_b_gen_kernel.aot" "$STAGE/route_b_gen_kernel.aot"
cp "$ZIPS/route_b_gen_dynamic_interface.aot" \
   "$STAGE/route_b_gen_dynamic_interface.aot"
cp "$ZIPS/route_b_release_probe.aot" "$STAGE/route_b_release_probe.aot"
cp "$OUT/vm_platform.dill" "$STAGE/flutter_platform_strong.dill"
chmod +x "$STAGE/dartaotruntime"
ENGINE_HASH=p5matrix
{
  echo "Route B producer tooling — local cell for the P5 matrix"
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

SDK='dart:core#print,dart:core#DateTime.now,dart:core#DateTime.get:millisecondsSinceEpoch'

# ---- build one configuration -----------------------------------------------
# stage <dir> <entry-basename> <marker-body>
stage_app() {
  local dir=$1 entry=$2 body=$3
  mkdir -p "$dir/lib" "$dir/.dart_tool"
  cp "$RB/packaging/container_target.dart" "$dir/lib/$entry"
  python3 - "$dir/lib/$entry" "$body" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
# A member whose value comes from the BUILD, plus an ordinary one to patch.
s = s.replace("void _state(String when) =>", """const String buildMarker =
    String.fromEnvironment('BUILD_MARKER', defaultValue: 'unset');
const String appFlavor =
    String.fromEnvironment('FLUTTER_APP_FLAVOR', defaultValue: 'unset');

String marker() => %s;

String plain() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'P' : 'X';

void _state(String when) =>""" % sys.argv[2], 1)
s = s.replace("print('$when alpha=${alpha()} beta=${beta()}');",
              "print('$when alpha=${alpha()} beta=${beta()} m=${marker()} p=${plain()}');", 1)
p.write_text(s)
PY
  cat > "$dir/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$dir/", "packageUri": "lib/",
    "languageVersion": "3.9" },
  { "name": "crypto", "rootUri": "file://$PKGS_DIR/crypto", "packageUri": "lib/",
    "languageVersion": "3.4" },
  { "name": "typed_data", "rootUri": "file://$PKGS_DIR/typed_data",
    "packageUri": "lib/", "languageVersion": "3.4" } ] }
JSON
}

# build <name> <dir> <entry-basename> <defines...> -- [--obfuscate]
build_release() {
  local name=$1 dir=$2 entry=$3; shift 3
  local defines=() obf=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --obfuscate) obf=1 ;;
      *) defines+=("$1") ;;
    esac
    shift
  done
  local uri="package:dynamic_modules/$entry"
  local o="$WORK/$name"; mkdir -p "$o"
  ( cd "$dir"
    # shellcheck disable=SC2086
    "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
      ${defines[@]+"${defines[@]}"} --packages .dart_tool/package_config.json \
      -o "$o/prepass.dill" "$uri" >/dev/null
    "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot \
      --no-link-platform ${defines[@]+"${defines[@]}"} \
      --packages .dart_tool/package_config.json \
      -o "$o/import.dill" "$uri" >/dev/null
    "$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" \
      --dill "$o/prepass.dill" --private-dill "$o/import.dill" --policy p2 \
      --out "$o/di.yaml" --manifest "$o/m.json" --sdk-members "$SDK" \
      >"$o/di.log" 2>&1 || { sed -n 1,4p "$o/di.log" >&2; \
        die "$name: gen_dynamic_interface failed (see $o/di.log)"; }
    "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
      ${defines[@]+"${defines[@]}"} --packages .dart_tool/package_config.json \
      --dynamic-interface "$o/di.yaml" -o "$o/base.dill" "$uri" >/dev/null )
  # `${arr[@]}` on an EMPTY array is an unbound variable under `set -u`, which
  # killed the run at the first non-obfuscated build.
  echo "$dir" > "$o/APPDIR"
  local obfArgs=()
  [ "$obf" = 1 ] && obfArgs=(--obfuscate --save-obfuscation-map="$o/obf.json")
  "$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
    --elf="$o/app.aot" ${obfArgs[@]+"${obfArgs[@]}"} \
    --write-v8-snapshot-profile-to="$o/profile.json" "$o/base.dill"
  echo "$o"
}

# patched <name> <releaseDir> <dir> <entry> <defines...>  -- one body edit
build_patch() {
  local name=$1 rel=$2 dir=$3 entry=$4; shift 4
  local defines=("$@")
  local pdir="$WORK/${name}_src"; rm -rf "$pdir"; cp -R "$dir" "$pdir"
  sed -i '' "s|? 'P' : 'X'|? 'NEW-P' : 'X'|" "$pdir/lib/$entry"
  sed -i '' "s|file://$dir/|file://$pdir/|" "$pdir/.dart_tool/package_config.json"
  local o="$WORK/$name"; mkdir -p "$o"
  # A FAILURE HERE IS A RESULT, not a crash. "the patch cannot even be compiled
  # against this release's interface" is a P5-relevant answer -- it is a refusal
  # at a different stage -- and dying under `set -e` would have thrown it away.
  set +e
  ( cd "$pdir"
    "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
      ${defines[@]+"${defines[@]}"} --packages .dart_tool/package_config.json \
      --dynamic-interface "$rel/di.yaml" -o "$o/patched.dill" \
      "package:dynamic_modules/$entry" ) > "$o/build.log" 2>&1
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ] || [ ! -f "$o/patched.dill" ]; then
    echo "FAILED:$o/build.log"
    return 0
  fi
  echo "$o/patched.dill"
}

facts() { # <label> <releaseDir>
  local label=$1 o=$2
  printf '    %-22s buildId=%s kernel=%s artifact=%s di=%s manifest=%s profile=%s\n' \
    "$label" \
    "$("$AOT_RUNTIME" "$o/app.aot" | sed -n 's/^BUILD_ID //p' | cut -c1-12)" \
    "$(shasum -a 256 "$o/base.dill" | cut -c1-12)" \
    "$(shasum -a 256 "$o/app.aot" | cut -c1-12)" \
    "$(shasum -a 256 "$o/di.yaml" | cut -c1-12)" \
    "$(shasum -a 256 "$o/m.json" | cut -c1-12)" \
    "$(shasum -a 256 "$o/profile.json" | cut -c1-12)"
}

cross() { # <releaseDir> <patched.dill> -> prints the producer's verdict
  local rel=$1 dill=$2 out="$WORK/cross_$$_$RANDOM.txt"
  if [ "${dill#FAILED:}" != "$dill" ]; then
    # The patch kernel could not be produced at all. Report WHERE, and quote the
    # compiler, because "refused by the frontend" and "refused by a gate" are
    # different findings with different remediations.
    echo "PATCH_BUILD_FAILED|$(sed -n '1,2p' "${dill#FAILED:}" | tr '\n' ' ' | cut -c1-70)"
    return 0
  fi
  local art; art=$(shasum -a 256 "$rel/app.aot" | cut -d' ' -f1)
  cat > "$rel/binding.json" <<JSON
{ "profile_format_revision": "v8-snapshot-profile/gen_snapshot",
  "probe_revision": 1, "cell_id": "$ENGINE_HASH",
  "release_artifact_sha256": "$art" }
JSON
  # The PROJECT ROOT is the app source, not the release output directory: the
  # producer passes <projectRoot>/.dart_tool/package_config.json to the bytecode
  # compiler, and a missing one fails with a bare exit 254 and no stderr --
  # indistinguishable, in the log, from a semantic refusal.
  local appdir; appdir=$(cat "$rel/APPDIR")
  set +e
  "$DART" --packages="$REPO/.dart_tool/package_config.json" \
    "$HERE/cli_survival.dart" "$CELL_ZIP" "$rel/base.dill" "$dill" \
    "$rel/import.dill" deadbeef "$WORK/w_$RANDOM" "$appdir" \
    "$OUT/vm_platform.dill" "$ENGINE_HASH" "$rel/profile.json" \
    "$rel/binding.json" "$art" --bound > "$out" 2>&1
  set -e
  local v; v=$(grep -o 'VERDICT  : [A-Z_]*' "$out" | head -1 | sed 's/VERDICT  : //')
  local why=""
  if [ "$v" = REFUSED ]; then
    why=$(sed -n 's/^  reason : //p' "$out" | head -1 | cut -c1-70)
    # A tool failure with no diagnostic output is the harness, not a refusal.
    # See probes/harness_guard.sh for why this is a shared rule.
    if [ "$(classify_tool_failure 1 "$out")" = HARNESS_FAILURE ]; then
      v=HARNESS_FAILURE
      why="the tool failed and said nothing — suspect the probe, not a gate"
    fi
  elif [ "$v" = COVERAGE_REJECTED ]; then
    why="the analyzer rejected the change set"
  elif [ -z "$v" ]; then
    v=HARNESS_ERROR; why=$(head -3 "$out" | tr '\n' ' ' | cut -c1-70)
  fi
  echo "$v|$why"
}

config_says() { # <argsA> <argsB> [flavorA] [flavorB]
  "$DART" --packages="$REPO/.dart_tool/package_config.json" \
    "$HERE/cli_build_identity.dart" "$1" "$2" "${3:-}" "${4:-}" 2>&1
}

row() { # <dimension> <verdict|why> <configOutput>
  local dim=$1 res=$2 cfg=$3
  local v=${res%%|*} why=${res#*|}
  local agree; agree=$(echo "$cfg" | sed -n 's/^agree        : //p')
  printf '  %-14s cross-patch=%-18s config-agrees=%-6s %s\n' \
    "$dim" "$v" "$agree" "$why"
}

# ---- ROW 0: the identical control ------------------------------------------
note "ROW 0 -- IDENTICAL (the control: if this refuses, nothing else means anything)"
stage_app "$WORK/a" container_target.dart "buildMarker"
A=$(build_release a "$WORK/a" container_target.dart -DBUILD_MARKER=A)
facts "release A" "$A"
PA=$(build_patch pa "$A" "$WORK/a" container_target.dart -DBUILD_MARKER=A)
R0=$(cross "$A" "$PA")
C0=$(config_says "--dart-define=BUILD_MARKER=A" "--dart-define=BUILD_MARKER=A")
row "identical" "$R0" "$C0"

# ---- ROW 1: Dart define ----------------------------------------------------
note "ROW 1 -- DART DEFINE  BUILD_MARKER=A vs =B"
PB=$(build_patch pb "$A" "$WORK/a" container_target.dart -DBUILD_MARKER=B)
R1=$(cross "$A" "$PB")
C1=$(config_says "--dart-define=BUILD_MARKER=A" "--dart-define=BUILD_MARKER=B")
row "dart_define" "$R1" "$C1"
echo "$C1" | sed 's/^/      /'

# ---- ROW 2: target ---------------------------------------------------------
note "ROW 2 -- TARGET  container_target.dart vs alt_target.dart"
stage_app "$WORK/alt" alt_target.dart "buildMarker"
PT=$(build_patch pt "$A" "$WORK/alt" alt_target.dart -DBUILD_MARKER=A)
R2=$(cross "$A" "$PT")
C2=$(config_says "--target=lib/container_target.dart" "--target=lib/alt_target.dart")
row "target" "$R2" "$C2"
echo "$C2" | sed 's/^/      /'

# ---- ROW 2b: TARGET, sharpened --------------------------------------------
#
# Row 2 failed to build for an INCIDENTAL reason (an interface naming a library
# the alternate entry does not compile), which says nothing about whether the
# mismatch would be caught. The real hazard behind `--target` is not the flag:
# it is that the patch is compiled inside a DIFFERENT PROGRAM, so its
# replacement body can reference a member the release never retained.
#
# Two entries over one shared library. `helperOnlyB` is reachable from entry B
# and tree-shaken out of entry A, and the patch -- built from B -- rewrites a
# member that DOES exist in A so that its body calls it.
note "ROW 2b -- TARGET, sharpened: a body referencing what the release dropped"
TG="$WORK/tg"; mkdir -p "$TG/lib" "$TG/.dart_tool"
cp "$RB/packaging/container_target.dart" "$TG/lib/shared.dart"
python3 - "$TG/lib/shared.dart" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace("void _state(String when) =>", """String plain() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'P' : 'X';

// Reachable only from entry B. Entry A never calls it, so A's release is
// tree-shaken without it.
String helperOnlyB() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'H' : 'X';

void _state(String when) =>""", 1)
s = s.replace("print('$when alpha=${alpha()} beta=${beta()}');",
              "print('$when alpha=${alpha()} beta=${beta()} p=${plain()}');", 1)
p.write_text(s)
PY
cat > "$TG/lib/main_a.dart" <<'DART'
import 'shared.dart' as shared;

void main(List<String> args) => shared.main(args);
DART
cat > "$TG/lib/main_b.dart" <<'DART'
import 'shared.dart' as shared;

void main(List<String> args) {
  shared.main(args);
  // The only difference: entry B keeps helperOnlyB alive.
  print(shared.helperOnlyB());
}
DART
cat > "$TG/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$TG/", "packageUri": "lib/",
    "languageVersion": "3.9" },
  { "name": "crypto", "rootUri": "file://$PKGS_DIR/crypto", "packageUri": "lib/",
    "languageVersion": "3.4" },
  { "name": "typed_data", "rootUri": "file://$PKGS_DIR/typed_data",
    "packageUri": "lib/", "languageVersion": "3.4" } ] }
JSON
TA=$(build_release tg_a "$TG" main_a.dart)
facts "release (entry A)" "$TA"
echo "    does A retain helperOnlyB? $(grep -c helperOnlyB "$TA/di.yaml" || true) mention(s) in its interface"

# The patch: built from entry B, rewriting `plain` so its body calls the member
# only B retains.
PT2SRC="$WORK/tg_b_src"; rm -rf "$PT2SRC"; cp -R "$TG" "$PT2SRC"
sed -i '' "s|? 'P' : 'X'|? helperOnlyB() : 'X'|" "$PT2SRC/lib/shared.dart"
sed -i '' "s|file://$TG/|file://$PT2SRC/|" "$PT2SRC/.dart_tool/package_config.json"
PT2="$WORK/tg_b"; mkdir -p "$PT2"
set +e
( cd "$PT2SRC" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill"    --aot --packages .dart_tool/package_config.json    --dynamic-interface "$TA/di.yaml" -o "$PT2/patched.dill"    package:dynamic_modules/main_b.dart ) > "$PT2/build.log" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  R2B="PATCH_BUILD_FAILED|$(sed -n '1,2p' "$PT2/build.log" | tr '\n' ' ' | cut -c1-70)"
else
  echo "$TG" > "$TA/APPDIR"
  R2B=$(cross "$TA" "$PT2/patched.dill")
fi
# ROW 2c -- the SAME entry, and the only change is that the patched body now
# calls a member the release's program never CALLS. This is what row 2b was
# reaching for: 2b rejected, but only because a new entry file makes
# `main_b.dart#main` an ADDED member, which is incidental to the hazard.
note "ROW 2c -- a body that calls a member with no call sites in the release"
DR="$WORK/dropref"; rm -rf "$DR"; cp -R "$TG" "$DR"
sed -i '' "s|? 'P' : 'X'|? helperOnlyB() : 'X'|" "$DR/lib/shared.dart"
sed -i '' "s|file://$TG/|file://$DR/|" "$DR/.dart_tool/package_config.json"
set +e
( cd "$DR" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
    --packages .dart_tool/package_config.json --dynamic-interface "$TA/di.yaml" \
    -o "$DR/patched.dill" package:dynamic_modules/main_a.dart ) \
  > "$DR/build.log" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  R2C="PATCH_BUILD_FAILED|$(sed -n 1,2p "$DR/build.log" | tr '\n' ' ' | cut -c1-60)"
else
  R2C=$(cross "$TA" "$DR/patched.dill")
fi
row "body-ref" "$R2C" "$C0"
# AND WHY THAT OUTCOME IS SAFE RATHER THAN LUCKY: Route B retains app libraries
# WHOLE, so the member is in the release program even with no call sites. Asked
# of the release probe rather than assumed.
tgart=$(shasum -a 256 "$TA/app.aot" | cut -d' ' -f1)
cat > "$TA/binding.json" <<JSON
{ "profile_format_revision": "v8-snapshot-profile/gen_snapshot",
  "probe_revision": 1, "cell_id": "$ENGINE_HASH",
  "release_artifact_sha256": "$tgart" }
JSON
echo "    is the referenced member IN the release program?"
"$AOT_RUNTIME" "$ZIPS/route_b_release_probe.aot" --profile "$TA/profile.json" \
  --binding "$TA/binding.json" --artifact-sha256 "$tgart" \
  --target 'package:dynamic_modules/shared.dart#helperOnlyB' 2>/dev/null \
  | python3 -c "
import json,sys
t = json.load(sys.stdin)['targets'][0]
print('      helperOnlyB:', t['result'],
      '-- Function nodes =', t['evidence']['target_function_nodes'])
"

C2B=$(config_says "--target=lib/main_a.dart" "--target=lib/main_b.dart")
row "target(shared)" "$R2B" "$C2B"
echo "$C2B" | sed 's/^/      /'

# ---- ROW 3: flavor ---------------------------------------------------------
note "ROW 3 -- FLAVOR  foo vs bar (reaches the compiler as FLUTTER_APP_FLAVOR)"
stage_app "$WORK/fl" container_target.dart "appFlavor"
FA=$(build_release fl_a "$WORK/fl" container_target.dart -DFLUTTER_APP_FLAVOR=foo)
FB_DILL=$(build_patch fl_b "$FA" "$WORK/fl" container_target.dart -DFLUTTER_APP_FLAVOR=bar)
facts "release foo" "$FA"
R3=$(cross "$FA" "$FB_DILL")
C3=$(config_says "" "" foo bar)
row "flavor" "$R3" "$C3"
echo "$C3" | sed 's/^/      /'
echo "    does flavor change the KERNEL when the app never reads it?"
stage_app "$WORK/nf" container_target.dart "'const'"
NA=$(build_release nf_a "$WORK/nf" container_target.dart -DFLUTTER_APP_FLAVOR=foo)
NB=$(build_release nf_b "$WORK/nf" container_target.dart -DFLUTTER_APP_FLAVOR=bar)
printf '      unread flavor: kernel foo=%s bar=%s -> %s\n' \
  "$(shasum -a 256 "$NA/base.dill" | cut -c1-12)" \
  "$(shasum -a 256 "$NB/base.dill" | cut -c1-12)" \
  "$([ "$(shasum -a 256 "$NA/base.dill" | cut -d' ' -f1)" = \
      "$(shasum -a 256 "$NB/base.dill" | cut -d' ' -f1)" ] \
      && echo IDENTICAL || echo DIFFERENT)"

# ---- ROW 4: obfuscation ----------------------------------------------------
note "ROW 4 -- OBFUSCATION  off vs on"
OA=$(build_release ob_a "$WORK/a" container_target.dart -DBUILD_MARKER=A)
OB=$(build_release ob_b "$WORK/a" container_target.dart -DBUILD_MARKER=A --obfuscate)
facts "release plain" "$OA"
facts "release obfusc" "$OB"
R4=$(cross "$OA" "$PA")
C4=$(config_says "--dart-define=BUILD_MARKER=A" "--dart-define=BUILD_MARKER=A --obfuscate")
row "obfuscation" "$R4" "$C4"
echo "$C4" | sed 's/^/      /'
printf '      artifact plain=%s obfuscated=%s -> %s\n' \
  "$(shasum -a 256 "$OA/app.aot" | cut -c1-12)" \
  "$(shasum -a 256 "$OB/app.aot" | cut -c1-12)" \
  "$([ "$(shasum -a 256 "$OA/app.aot" | cut -d' ' -f1)" = \
      "$(shasum -a 256 "$OB/app.aot" | cut -d' ' -f1)" ] \
      && echo IDENTICAL || echo DIFFERENT)"

note "the matrix"
echo "  Read 'cross-patch' as what the REAL producer did with release A's"
echo "  artifacts and a patch kernel built under B. Read 'config-agrees' as"
echo "  what RouteBBuildConfig.agreesWith says -- the G4.1 check that lives in"
echo "  the PATCHER, which this harness does not drive."
row "identical" "$R0" "$C0"
row "dart_define" "$R1" "$C1"
row "target" "$R2" "$C2"
row "target(shared)" "$R2B" "$C2B"
row "body-ref" "$R2C" "$C0"
row "flavor" "$R3" "$C3"
row "obfuscation" "$R4" "$C4"
echo
echo "work dir kept: $WORK"
