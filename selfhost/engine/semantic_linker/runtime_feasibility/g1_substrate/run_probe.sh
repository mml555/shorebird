#!/usr/bin/env bash
# cspell:words dartaotruntime dill semantic linker dynmod
# run_probe.sh -- SEMANTIC-LINKER-1 / G1 step 3. Run the SAME probe against both
# substrates and record, per arm, what each of the three module natives did.
#
# PREDICTIONS ARE IN PRECOMMIT.md AND WERE WRITTEN BEFORE THE BUILDS FINISHED.
# This script does not check them -- it reports -- because a runner that scores
# itself against expectations it also defines is a verdict table, not a
# measurement ([[verdict-tables-are-not-evidence]]). RESULT.md does the scoring,
# against the committed precommit.
#
# Each arm is compiled with ITS OWN gen_snapshot, ITS OWN vm_platform.dill and
# ITS OWN dart2bytecode. Borrowing one arm's toolchain for the other would make
# the comparison measure the borrowing.
#
#   run_probe.sh [--arm dm_on|dm_off]
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LANE=${LANE:-/Volumes/build/semantic-linker/sl1}
SRC="$LANE/flutter/engine/src"
EVID="$HERE/evidence"
mkdir -p "$EVID"

ARMS=(dm_off dm_on)
[[ "${1:-}" == "--arm" ]] && ARMS=("${2:?}")

DART_TREE="$SRC/flutter/third_party/dart"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
D2B="$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart"

for arm in "${ARMS[@]}"; do
  OUT="$SRC/out/sl1_$arm"
  LOGF="$EVID/probe_$arm.txt"
  {
    echo "SL1-G1 substrate probe -- arm $arm"
    echo "out          : $OUT"
    echo "date         : $(date -u +%FT%TZ)"
    if [[ ! -d "$OUT" ]]; then echo "ABSENT: no build at $OUT"; continue; fi
    echo "dm flag lines: $(grep -c '^dart_dynamic_modules' "$OUT/args.gn")"
    for f in gen_snapshot dartaotruntime dart-sdk/bin/dart vm_platform.dill; do
      [[ -e "$OUT/$f" ]] && echo "sha256 $(shasum -a 256 "$OUT/$f" | cut -d' ' -f1)  $f" \
                         || echo "MISSING $f"
    done
    echo
  } > "$LOGF"

  [[ -d "$OUT" ]] || { echo "arm $arm: no build, skipped"; continue; }

  W=$(mktemp -d)
  mkdir -p "$W/lib" "$W/.dart_tool"
  cp "$HERE/probe/host_probe.dart" "$W/lib/host_probe.dart"
  cp "$HERE/probe/replacement.dart" "$W/replacement.dart"
  # `dart:_internal` is importable only by a package: library whose path starts
  # with dart_internal/ or dynamic_modules/ (pkg/kernel/lib/target/targets.dart) --
  # upstream's own allowance for this feature. Hence the package name; it is not
  # an SDK edit and not a workaround.
  cat > "$W/.dart_tool/package_config.json" <<JSON
{
  "configVersion": 2,
  "packages": [
    { "name": "dynamic_modules", "rootUri": "file://$W/", "packageUri": "lib/", "languageVersion": "3.9" }
  ]
}
JSON
  URI="package:dynamic_modules/host_probe.dart"
  DART="$OUT/dart-sdk/bin/dart"

  {
    echo "== 1. AOT kernel (with the banked dynamic interface) =="
    "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
      --packages "$W/.dart_tool/package_config.json" \
      --dynamic-interface "$HERE/probe/di.yaml" \
      -o "$W/host.dill" "$URI" 2>&1 | sed 's/^/   /'
    echo "   gen_kernel exit=${PIPESTATUS[0]}"

    echo "== 2. AOT snapshot =="
    "$OUT/gen_snapshot" --snapshot_kind=app-aot-elf --elf="$W/host.aot" "$W/host.dill" 2>&1 | sed 's/^/   /'
    echo "   gen_snapshot exit=${PIPESTATUS[0]}"
    [[ -f "$W/host.aot" ]] && echo "   host.aot sha256 $(shasum -a 256 "$W/host.aot" | cut -d' ' -f1) bytes $(wc -c < "$W/host.aot" | tr -d ' ')"

    echo "== 3. normal-AOT check (no module) =="
    "$OUT/dartaotruntime" "$W/host.aot" 2>&1 | sed 's/^/   /'
    echo "   exit=${PIPESTATUS[0]}"

    echo "== 4. replacement -> KBC bytecode =="
    "$DART" "$D2B" --platform "$OUT/vm_platform.dill" \
      -o "$W/replacement.bytecode" "$W/replacement.dart" 2>&1 | sed 's/^/   /'
    echo "   dart2bytecode exit=${PIPESTATUS[0]}"
    [[ -f "$W/replacement.bytecode" ]] && echo "   replacement.bytecode sha256 $(shasum -a 256 "$W/replacement.bytecode" | cut -d' ' -f1) bytes $(wc -c < "$W/replacement.bytecode" | tr -d ' ')"

    echo "== 5. the three natives, under this arm =="
    if [[ -f "$W/replacement.bytecode" ]]; then
      "$OUT/dartaotruntime" "$W/host.aot" "$W/replacement.bytecode" "$URI" 2>&1 | sed 's/^/   /'
      echo "   exit=${PIPESTATUS[0]}"
    else
      echo "   SKIPPED: no bytecode was produced"
    fi
  } >> "$LOGF" 2>&1

  echo "arm $arm -> $LOGF"
  rm -rf "$W"
done
