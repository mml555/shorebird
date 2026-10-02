#!/usr/bin/env bash
# Spike A matrix runner: build P0..P3 of the medium program on a given engine
# out-dir and dump each build's global object pool as JSONL
# (--dump_global_object_pool_to, the spike-only gen_snapshot flag).
#
#   OUT=<engine out dir> WORK=<dir> ./run_matrix.sh
#
# Deltas, applied to lib/medium.dart via its marker comments:
#   P0 baseline (built twice: p0a/p0b for determinism)
#   P1 one function BODY edit                  (// P1-EDIT line)
#   P2 added function + call site              (// P2-CALLSITE marker)
#   P3 added const construction + new string   (// P2-CALLSITE marker)
set -euo pipefail

SRC="${SRC:-/Volumes/build/ios-engine/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64_nodm}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
WORK="${WORK:-$(mktemp -d)}"

DART="$OUT/dart-sdk/bin/dart"
GEN_KERNEL="$SRC/flutter/third_party/dart/pkg/vm/bin/gen_kernel.dart"
GEN_SNAPSHOT="$OUT/gen_snapshot"

[ -x "$GEN_SNAPSHOT" ] || { echo "no gen_snapshot at $OUT" >&2; exit 1; }
"$GEN_SNAPSHOT" --dump_global_object_pool_to=/dev/null --version >/dev/null 2>&1 \
  || true  # flag presence is checked by the first real dump below

build_variant() {  # build_variant <name>
  local name="$1"
  local d="$WORK/$name"
  mkdir -p "$d/lib" "$d/.dart_tool"
  cp "$HERE/medium/lib/support.dart" "$d/lib/support.dart"

  case "$name" in
    p0a|p0b)
      cp "$HERE/medium/lib/medium.dart" "$d/lib/medium.dart" ;;
    p1)
      sed "s|'stamp:\$base'; // P1-EDIT|'stamp!v2:\$base'; // P1-EDIT|" \
        "$HERE/medium/lib/medium.dart" > "$d/lib/medium.dart" ;;
    p2)
      sed "s|  // P2-CALLSITE|  print(extraProbe());|" \
        "$HERE/medium/lib/medium.dart" > "$d/lib/medium.dart"
      cat >> "$d/lib/medium.dart" <<'DART'

@pragma('vm:never-inline')
String extraProbe() => 'EXTRA-PROBE';
DART
      ;;
    p3)
      sed "s|  // P2-CALLSITE|  print(const LogRecord(Severity.error, 'p3-brand-new-const', 999).toJson());|" \
        "$HERE/medium/lib/medium.dart" > "$d/lib/medium.dart" ;;
    *) echo "unknown variant $name" >&2; return 1 ;;
  esac

  cat > "$d/.dart_tool/package_config.json" <<JSON
{
  "configVersion": 2,
  "packages": [
    {
      "name": "spike_medium",
      "rootUri": "file://$d/",
      "packageUri": "lib/",
      "languageVersion": "3.9"
    }
  ]
}
JSON

  echo "==> $name: kernel"
  "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
    --packages "$d/.dart_tool/package_config.json" \
    -o "$d/medium.dill" "package:spike_medium/medium.dart"
  echo "==> $name: snapshot + pool dump"
  "$GEN_SNAPSHOT" --snapshot_kind=app-aot-elf --elf="$d/medium.aot" \
    --dump_global_object_pool_to="$WORK/pool_$name.jsonl" "$d/medium.dill"
  echo "    $(wc -l < "$WORK/pool_$name.jsonl" | tr -d ' ') pool entries"
}

for v in p0a p0b p1 p2 p3; do build_variant "$v"; done
echo "dumps in $WORK"
