#!/usr/bin/env bash
# cspell:words dynmod killgate dartaotruntime
#
# probe_retention_lookup.sh -- does step 2's retention already give step 3 its
# runtime half?
#
# THE QUESTION. Every harness so far has pinned its targets with
# @pragma('vm:entry-point'), because AOT drops library dictionaries and the
# attach native resolves targets by name. That pragma is scaffolding: a release
# cannot ask app authors to annotate every function a future patch might touch.
#
# But step 2 retains whole app libraries through the dynamic interface, and
# gen_kernel's annotator lowers each entry to @pragma('dyn-module:callable'),
# which the VM treats identically to vm:entry-point (object.cc
# FindEntryPointPragma). So retention may ALREADY make every app function
# resolvable by name -- in which case step 3 is a naming and manifest problem,
# not a runtime lookup problem.
#
# This asks it directly: strip every vm:entry-point from the inventory program,
# build it with the generated dynamic interface, and try to attach by name.
#
#   attach succeeds -> retention subsumes the pragma; step 3 is naming + manifest
#   attach fails    -> the release needs its own target table, which is real work
#
# Either answer is worth having before designing anything.
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
RB="$(cd "$HERE/.." >/dev/null 2>&1 && pwd)"
WORK="${WORK:-$(mktemp -d)}"

DART_TREE="$SRC/flutter/third_party/dart"
DART="$OUT/dart-sdk/bin/dart"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
DART2BC="$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart"
GEN_SNAPSHOT="$OUT/gen_snapshot"
AOT_RUNTIME="$OUT/dartaotruntime"
URI="package:dynamic_modules/inventory.dart"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

[ -d "$OUT" ] || die "no build at $OUT"

mkdir -p "$WORK/lib" "$WORK/.dart_tool"
# Strip the pragma, keep everything else. vm:never-inline stays -- that controls
# for inlining, which is a different question and would confound this one.
grep -v "@pragma('vm:entry-point')" "$RB/inventory/inventory.dart" \
  > "$WORK/lib/inventory.dart"
# Count the PRAGMA, not the string: inventory.dart also discusses vm:entry-point
# in prose, and matching that made this guard fire on a correct strip.
stripped=$(grep -c "@pragma('vm:entry-point')" "$RB/inventory/inventory.dart")
remaining=$(grep -c "@pragma('vm:entry-point')" "$WORK/lib/inventory.dart" || true)
note "stripped $stripped vm:entry-point pragmas ($remaining remain)"
[[ "$remaining" -eq 0 ]] || die "pragmas survived the strip -- the probe would prove nothing"

cat > "$WORK/.dart_tool/package_config.json" <<JSON
{
  "configVersion": 2,
  "packages": [
    {
      "name": "dynamic_modules",
      "rootUri": "file://$WORK/",
      "packageUri": "lib/",
      "languageVersion": "3.9"
    }
  ]
}
JSON

cd "$WORK"

note "discovery kernel -> dynamic interface -> release kernel"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o discover.dill "$URI" >/dev/null
"$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
  "$RB/gen_dynamic_interface.dart" --dill discover.dill --out di.yaml
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json \
  --dynamic-interface di.yaml -o inv.dill "$URI" >/dev/null
"$GEN_SNAPSHOT" --patchable_static_calls \
  --snapshot_kind=app-aot-elf --elf=inv.aot inv.dill
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
  --no-aot --no-link-platform \
  --packages .dart_tool/package_config.json -o import.dill "$URI" >/dev/null

emit() {  # emit <file> <fn> <marker>
  cat > "$WORK/$1.dart" <<DART
@pragma('dyn-module:entry-point')
String $2() => 'NEW-$3';
DART
  "$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" \
    --import-dill import.dill -o "$WORK/$1.bytecode" "$WORK/$1.dart" \
    >/dev/null 2>&1 || die "dart2bytecode failed for $1"
}
emit top     topLevelStatic top
emit static_m staticMethod  static_m
emit mono    monomorphic    mono
emit circle  describe       circle
# A PRIVATE top-level function. This is the case that separates "retained" from
# "retained and reachable": pkg/vm's spec says a `library:` item covers public
# members only, so before the generator emitted explicit entries for private
# members this failed with "function _report not found" while its own library
# was retained whole. Real apps are mostly private code, so this case decides
# whether the coverage number means anything.
emit private _report       private

printf '\n%-24s  %-18s  %s\n' "target" "form" "outcome"
printf -- '-%.0s' {1..66}; printf '\n'

fails=0
for c in "topLevelStatic|top|topLevelStatic" \
         "Holder.staticMethod|static_m|staticMethod" \
         "Holder.monomorphic|mono|monomorphic" \
         "Circle.describe|circle|dynamic-instance" \
         "_report|private|"; do
  IFS='|' read -r target bc form <<<"$c"
  log="$WORK/$bc.log"
  set +e
  "$AOT_RUNTIME" inv.aot "$WORK/$bc.bytecode" "$URI" "$target" >"$log" 2>&1
  set -e
  if grep -q '^ATTACH: .*not found' "$log"; then
    outcome="LOOKUP FAILED -- $(grep -m1 '^ATTACH: .*not found' "$log")"
    fails=$((fails + 1))
  elif [[ -z "$form" ]]; then
    # _report is the reporter itself: patching it replaces every FORM line
    # rather than flipping one, so resolution is what is being measured here.
    if grep -q "^attach\[$target\]: true" "$log"; then
      outcome="resolved (private name)"
    else
      outcome="attach returned false"; fails=$((fails + 1))
    fi
  elif grep -q "^FORM $form: PATCHED" "$log"; then
    outcome="resolved and patched"
  else
    outcome="resolved, but $form did not flip (see $log)"
  fi
  printf '%-24s  %-18s  %s\n' "$target" "$form" "$outcome"
done

echo
if [[ "$fails" -eq 0 ]]; then
  echo "ANSWER: retention SUBSUMES the pragma."
  echo "  Whole-library dynamic-interface retention leaves app functions"
  echo "  resolvable by name at run time, with no vm:entry-point anywhere."
  echo "  Step 3 is therefore a NAMING + MANIFEST problem, not a runtime"
  echo "  lookup problem -- do not build a bespoke target table."
else
  echo "ANSWER: retention does NOT subsume the pragma ($fails lookup failures)."
  echo "  The release needs to carry its own target table, and that is real"
  echo "  work rather than a naming convention."
fi

echo
echo "work dir kept: $WORK"
