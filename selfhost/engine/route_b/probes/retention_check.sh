#!/usr/bin/env bash
# cspell:words prepass dartaotruntime rtpriv
#
# retention_check.sh -- a Route B patch is refused, BEFORE anything is uploaded,
# when its bytecode would name an external symbol the RELEASE did not keep
# (analysis version 18 + the CLI's `RouteBRetention`).
#
# Real kernels end to end, host only: a release program is built with
# gen_dynamic_interface.dart (policy p2, so its interface and capability
# manifest are the ones a release publishes), a patched variant is compiled with
# the same interface, the analyzer (this repo's analyze_coverage.dart, run from
# source against the engine tree's package:kernel) writes its coverage document,
# and the CLI's own retention check answers per carried member.
#
# Arms (the target is the top-level `rtTarget`; each is one patched source):
#   sdk_retained          calls DateTime.now, which the release keeps by name
#   app_retained          calls a public app function the release's library item keeps
#   dep_never_called      builds a Uint8Buffer of package:typed_data, a dependency API the
#                         release never called (the patch adds the import)
#   sdk_never_called      calls int.parse, a dart:core member the release never named
#   private_in_manifest   calls a private top-level the manifest granted   (control)
#   private_not_granted   the same call, against a manifest without the grant
#   carried_helper        calls a NEW top-level function the patch carries, whose
#                         own body calls only retained code
#   carried_helper_bad    the same, but the carried helper's body calls int.parse
#   no_interface          no interface at all: refused, never waved through
#   unchanged_release_sweep  the release's own members carried against themselves: all kept
#
#   OUT=$HOME/shorebird-engine/flutter/engine/src/out/host_release_arm64_ddm \
#     retention_check.sh <route_b dir>
set -euo pipefail
SRC=${SRC:-$HOME/shorebird-engine/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64_ddm}
HERE=$(cd "$(dirname "$0")" && pwd)
RB=$1
REPO=$(cd "$RB/../../.." && pwd)
WORK=${WORK:-$REPO/../tmp/retention_check_work}
rm -rf "$WORK"; mkdir -p "$WORK/lib" "$WORK/.dart_tool"
WORK=$(cd "$WORK" && pwd)
DART_TREE=$SRC/flutter/third_party/dart
DART=$OUT/dart-sdk/bin/dart
KERNEL_PKGS="--packages=$DART_TREE/.dart_tool/package_config.json"
GEN_KERNEL=$DART_TREE/pkg/vm/bin/gen_kernel.dart
PKGS_DIR=$DART_TREE/third_party/pkg/core/pkgs
CLI_PKGS=$REPO/.dart_tool/package_config.json
cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$WORK/", "packageUri": "lib/", "languageVersion": "3.9" },
  { "name": "crypto", "rootUri": "file://$PKGS_DIR/crypto", "packageUri": "lib/", "languageVersion": "3.4" },
  { "name": "typed_data", "rootUri": "file://$PKGS_DIR/typed_data", "packageUri": "lib/", "languageVersion": "3.4" } ] }
JSON
URI=package:dynamic_modules/container_target.dart
PLAT=$OUT/vm_platform.dill
cd "$WORK"
cp "$RB/packaging/container_target.dart" lib/container_target.dart
cat >> lib/container_target.dart <<'DART'

// The release's own code for the arms. `rtTarget` is what a patch replaces;
// `rtApp` is public and kept by the app library item; `_rtPriv` is a private
// top-level the manifest grants; the release calls sha256 and DateTime.now but
// never sha512 or int.parse.
@pragma('vm:never-inline')
String rtTarget() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD' : 'X';
@pragma('vm:never-inline')
String rtApp() => 'APP';
@pragma('vm:never-inline')
String _rtPriv() => 'PRIV';
@pragma('vm:never-inline')
String rtSha() => sha256.convert(<int>[1]).toString();
DART
python3 - lib/container_target.dart <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = "void _state(String when) => print('$when alpha=${alpha()} beta=${beta()}');"
assert old in s
s = s.replace(old, "void _state(String when) => print('$when alpha=${alpha()} beta=${beta()} t=${rtTarget()} a=${rtApp()} p=${_rtPriv()} s=${rtSha()}');")
p.write_text(s)
PY
"$DART" "$GEN_KERNEL" --platform "$PLAT" --aot --packages .dart_tool/package_config.json -o prepass.dill "$URI" >/dev/null
"$DART" "$GEN_KERNEL" --platform "$PLAT" --no-aot --no-link-platform --packages .dart_tool/package_config.json -o import.dill "$URI" >/dev/null
"$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill prepass.dill --private-dill import.dill --policy p2 --out di.yaml --manifest manifest.json --sdk-members \
  'dart:core#print,dart:core#DateTime.now,dart:core#DateTime.get:millisecondsSinceEpoch' 2>&1 | sed 's/^/  /'
"$DART" "$GEN_KERNEL" --platform "$PLAT" --aot --packages .dart_tool/package_config.json --dynamic-interface di.yaml -o base.dill "$URI" >/dev/null
python3 - <<PY
import json
m = json.load(open('manifest.json'))
k = '$URI#_rtPriv'
assert k in m['privateTopLevelCallable'], 'the release must grant _rtPriv'
m['privateTopLevelCallable'] = [x for x in m['privateTopLevelCallable'] if x != k]
json.dump(m, open('manifest_without_rtpriv.json', 'w'))
PY
cp lib/container_target.dart release_source.dart

FAILS=0
RESULTS=()
want() { [ -z "${ONLY:-}" ] || [[ $1 =~ $ONLY ]]; }
record() { RESULTS+=("$1|$2"); echo "  RESULT $1: $2"; [ "$2" = PASS ] || FAILS=$((FAILS+1)); }

# analyze <label> <rtTarget body> <extra top-level text> <extra import line>
analyze() {
  cp release_source.dart lib/container_target.dart
  BODY="$2" TOP="${3:-}" IMPORT="${4:-}" python3 - lib/container_target.dart <<'PY'
import os, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = "String rtTarget() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD' : 'X';"
assert old in s
s = s.replace(old, "String rtTarget() => %s;" % os.environ['BODY'])
s += "\n" + os.environ['TOP'] + "\n"
if os.environ['IMPORT']:
    s = s.replace("import 'dart:io';", "import 'dart:io';\n" + os.environ['IMPORT'], 1)
p.write_text(s)
PY
  "$DART" "$GEN_KERNEL" --platform "$PLAT" --aot --packages .dart_tool/package_config.json --dynamic-interface di.yaml -o "$d/patched.dill" "$URI" >"$d/gen_kernel.log" 2>&1 \
    || { echo "  ! patched source did not compile"; head "$d/gen_kernel.log" | sed 's/^/  ! /'; return 1; }
  "$DART" $KERNEL_PKGS "$RB/coverage/analyze_coverage.dart" --base-dill base.dill --patched-dill "$d/patched.dill" --out "$d/coverage.json"
}

# arm <label> <ok|refused> <phrase> <body> <top> <import> [<interface or -> [<manifest>]]
arm() {
  local label=$1 want=$2 phrase=$3
  want "$label" || return 0
  d=$WORK/$label; mkdir -p "$d"
  echo; echo "==> $label"
  analyze "$label" "$4" "${5:-}" "${6:-}" || { record "$label" "FAIL (harness)"; return; }
  local iface=${7:-di.yaml}; [ "$iface" = - ] && iface=
  "$DART" --packages="$CLI_PKGS" "$HERE/cli_retention.dart" "$d/coverage.json" "$iface" "${8:-manifest.json}" > "$d/verdict.log" 2>&1 || true
  sed 's/^/  /' "$d/verdict.log"
  local ours; ours=$(grep -F "$URI#rtTarget" "$d/verdict.log" || true)
  if [ "$want" = ok ]; then
    if [[ $ours == OK* ]] && ! grep -q '^REFUSED' "$d/verdict.log"; then record "$label" PASS
    else record "$label" "FAIL (wanted every carried member kept)"; fi
  else
    if [[ $ours == REFUSED* ]] && grep -qF -- "$phrase" <<<"$ours" && grep -qF 'new release' <<<"$ours"; then record "$label" PASS
    else record "$label" "FAIL (wanted a refusal naming: $phrase)"; fi
  fi
}

arm sdk_retained ok "" "'\${DateTime.now().millisecondsSinceEpoch}'"
arm app_retained ok "" "rtApp()"
arm dep_never_called refused "Uint8Buffer" "(Uint8Buffer()..add(1)).length.toString()" "" "import 'package:typed_data/typed_buffers.dart';"
arm sdk_never_called refused "int.parse" "int.parse('1').toString()"
arm private_in_manifest ok "" "_rtPriv()"
arm private_not_granted refused "_rtPriv" "_rtPriv()" "" "" di.yaml manifest_without_rtpriv.json
arm carried_helper ok "" "_rtNew()" "String _rtNew() => DateTime.now().toString();"
arm carried_helper_bad refused "int.parse" "_rtNew()" "String _rtNew() => int.parse('1').toString();"
arm no_interface refused "no readable dynamic interface" "rtApp()" "" "" -

# unchanged_release_sweep -- an INVARIANT, not a shape. A body the release
# already compiled can only name what the generator retained from it, so the
# release's own members, analyzed as if carried (`--carry`) against themselves,
# must ALL be kept. A collector or matcher drift (a private name spelled
# differently, an export vs the declaring library, a node walked twice or not at
# all) shows up here as a refusal of code that is, by construction, fine.
if want unchanged_release_sweep; then
  echo; echo "==> unchanged_release_sweep"
  d=$WORK/unchanged_release_sweep; mkdir -p "$d"
  carry=()
  for k in main applyPatchContainer revertAll _parse jsonDecodeMap alpha beta _state rtTarget rtApp _rtPriv rtSha; do
    carry+=(--carry "$URI#$k")
  done
  "$DART" $KERNEL_PKGS "$RB/coverage/analyze_coverage.dart" --base-dill base.dill --patched-dill base.dill "${carry[@]}" --out "$d/coverage.json"
  "$DART" --packages="$CLI_PKGS" "$HERE/cli_retention.dart" "$d/coverage.json" di.yaml manifest.json > "$d/verdict.log" 2>&1 || true
  sed 's/^/  /' "$d/verdict.log"
  swept=$(grep -c '^OK' "$d/verdict.log" || true)
  if ! grep -q '^REFUSED\|^NOT-MEASURED' "$d/verdict.log" && [ "$swept" -ge 8 ]; then record unchanged_release_sweep PASS
  else record unchanged_release_sweep "FAIL ($swept kept, or a refusal above)"; fi
fi

# real_release_sweep -- the same invariant over a REAL app's release, when
# REAL_RELEASE names a directory holding its prepass.dill (the release's AOT
# kernel), dynamic_interface.yaml and route_b_capabilities.json (a Route B
# build's `build/route_b`). Every member of the app is carried against itself;
# none may be refused.
if [ -n "${REAL_RELEASE:-}" ] && want real_release_sweep; then
  echo; echo "==> real_release_sweep ($REAL_RELEASE)"
  d=$WORK/real_release_sweep; mkdir -p "$d"
  inc=()
  for pkg in ${REAL_RELEASE_PACKAGES:-}; do inc+=(--include "$pkg"); done
  "$DART" $KERNEL_PKGS "$RB/coverage/analyze_coverage.dart" "${inc[@]}" --base-dill "$REAL_RELEASE/prepass.dill" --patched-dill "$REAL_RELEASE/prepass.dill" --carry-all --out "$d/coverage.json"
  "$DART" --packages="$CLI_PKGS" "$HERE/cli_retention.dart" "$d/coverage.json" "$REAL_RELEASE/dynamic_interface.yaml" "$REAL_RELEASE/route_b_capabilities.json" > "$d/verdict.log" 2>&1 || true
  swept=$(grep -c '^OK' "$d/verdict.log" || true)
  echo "  $swept members kept, $(grep -c '^REFUSED' "$d/verdict.log" || true) refused"
  grep '^REFUSED\|^NOT-MEASURED' "$d/verdict.log" | cut -c1-300 | sed 's/^/  /' || true
  if ! grep -q '^REFUSED\|^NOT-MEASURED' "$d/verdict.log" && [ "$swept" -ge 10 ]; then record real_release_sweep PASS
  else record real_release_sweep "FAIL ($swept kept, or a refusal above)"; fi
fi

echo; echo "== SUMMARY"
for r in "${RESULTS[@]}"; do printf '  %-28s %s\n' "${r%%|*}" "${r#*|}"; done
[ "$FAILS" -eq 0 ] && echo "ALL PASS" || { echo "$FAILS FAILED"; exit 1; }
