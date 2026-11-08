#!/usr/bin/env bash
# cspell:words dynmod killgate dartaotruntime
#
# run_inventory.sh -- which AOT call forms can a Route B patch actually reach?
#
# ROUTE_B.md's design decision is to make ONE call form patchable, prove it, and
# only then "inventory the call forms and expand on purpose". This is that
# inventory, and it exists so the widening is driven by measurement rather than
# by guessing which shapes matter.
#
# For each target it builds a release, patches THAT target, and reports every
# form's outcome. A form is patchable when patching its own target changes it;
# a form that stays `original` while its target was successfully attached is a
# dispatch path the patch cannot reach.
#
# Run:
#   selfhost/engine/route_b/inventory/run_inventory.sh
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
WORK="${WORK:-$(mktemp -d)}"
FLAGS="${GEN_SNAPSHOT_FLAGS:---patchable_static_calls}"

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
cp "$HERE/inventory.dart" "$WORK/lib/inventory.dart"
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

note "release kernel + snapshot (gen_snapshot flags: ${FLAGS:-none})"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o inv.dill "$URI" >/dev/null
# shellcheck disable=SC2086
"$GEN_SNAPSHOT" $FLAGS --snapshot_kind=app-aot-elf --elf=inv.aot inv.dill
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
  --no-aot --no-link-platform \
  --packages .dart_tool/package_config.json -o import.dill "$URI" >/dev/null

# One replacement per target. The bodies differ only in their marker, and each
# must match its target's signature -- the attach swaps a body, not an API.
emit_bytecode() {  # emit_bytecode <file> <fn-name> <marker>
  cat > "$WORK/$1.dart" <<DART
@pragma('dyn-module:entry-point')
String $2() => 'NEW-$3';
DART
  "$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" \
    --import-dill import.dill -o "$WORK/$1.bytecode" "$WORK/$1.dart" \
    >/dev/null 2>&1 || die "dart2bytecode failed for $1"
}

emit_bytecode top      topLevelStatic top
emit_bytecode static_m  staticMethod   static_m
emit_bytecode mono     monomorphic    mono
emit_bytecode getter   getter         getter
emit_bytecode circle   describe       circle

# target name -> which FORM line should flip if that form is patchable
declare -a CASES=(
  "topLevelStatic|top|topLevelStatic"
  "Holder.staticMethod|static_m|staticMethod"
  "Holder.monomorphic|mono|monomorphic"
  # Getters are stored under the VM's own name, "get:<name>" -- asking for
  # "Holder.getter" gets you "member getter not found on Holder", which
  # reads like an unpatchable form and is really a naming mismatch.
  "Holder.get:getter|getter|getter"
  "Circle.describe|circle|polymorphic-first"
  # Same attach, different observation point: if the dynamic call flips
  # while the statically-typed one does not, the gap is dispatch-table
  # specialization and not the patch.
  "Circle.describe|circle|dynamic-instance"
)

printf '\n%-22s  %-20s  %s\n' "target attached" "form under test" "outcome"
printf -- '-%.0s' {1..74}; printf '\n'

for c in "${CASES[@]}"; do
  IFS='|' read -r target bc form <<<"$c"
  log="$WORK/$bc.log"
  set +e
  "$AOT_RUNTIME" inv.aot "$WORK/$bc.bytecode" "$URI" "$target" >"$log" 2>&1
  set -e

  if grep -q "^attach\[$target\]: false" "$log" || grep -q '^ATTACH: .*not found' "$log"; then
    outcome="ATTACH FAILED (harness) -- $(grep -m1 '^ATTACH: .*not found' "$log" || echo 'attach returned false')"
  elif grep -q "^FORM $form: PATCHED" "$log"; then
    outcome="PATCHABLE"
  elif grep -q "^FORM $form: original" "$log"; then
    outcome="not reachable"
  else
    outcome="INCONCLUSIVE (no FORM $form line; see $log)"
  fi
  printf '%-22s  %-20s  %s\n' "$target" "$form" "$outcome"
done

echo
echo "work dir kept: $WORK"
