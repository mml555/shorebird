#!/usr/bin/env bash
# cspell:words dartaotruntime dill semantic linker
# run_g3.sh -- SEMANTIC-LINKER-1 / G3. Type-system participation and GC
# correctness across the mixed object graph.
#
# ORDER IS DELIBERATE. gc_control runs FIRST and falsifies the collector: a
# no-op GC trigger would make every survival test below pass while collecting
# nothing. Nothing that follows is worth reading if it fails.
#
# MISSING EVIDENCE FAILS CLOSED, as in G2: a test whose bytecode does not
# compile, or that produces no transcript, is counted as FAILED, never skipped.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LANE=${LANE:-/Volumes/build/semantic-linker/sl1}
SRC="$LANE/flutter/engine/src"
ARM=${ARM:-g3_on}
OUT="$SRC/out/sl1_$ARM"
EVID="$HERE/evidence"; mkdir -p "$EVID"
LOGF="$EVID/g3_$ARM.txt"
DM=$(grep -c '^dart_dynamic_modules' "$OUT/args.gn" 2>/dev/null); DM=${DM:-0}

DART_TREE="$SRC/flutter/third_party/dart"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
D2B="$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart"
DART="$OUT/dart-sdk/bin/dart"

# test -> module source. gc_control needs none: it measures the collector on
# ordinary AOT objects, before any patch object exists.
TESTS=(gc_control gc_aot_roots_patch gc_patch_roots_aot gc_cycle_collects
       type_implements type_extends type_return type_collections type_generic
       type_generic_patcharg)
mod_for() {
  case "$1" in
    gc_control)          echo "" ;;
    gc_aot_roots_patch)  echo m_gc_aot_roots_patch ;;
    gc_patch_roots_aot)  echo m_gc_patch_roots_aot ;;
    gc_cycle_collects)   echo m_gc_cycle ;;
    type_implements)     echo m_iface ;;
    type_generic_patcharg) echo m_generic ;;
    *)                   echo m_child ;;
  esac
}

[[ -d "$OUT" ]] || { echo "no build at $OUT" >&2; exit 2; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/lib" "$W/.dart_tool"
cp "$HERE/probe/g3_host.dart" "$W/lib/g3_host.dart"
for f in "$HERE"/probe/m_*.dart; do cp "$f" "$W/"; done
cat > "$W/.dart_tool/package_config.json" <<JSON
{"configVersion":2,"packages":[{"name":"dynamic_modules","rootUri":"file://$W/","packageUri":"lib/","languageVersion":"3.9"}]}
JSON
URI=package:dynamic_modules/g3_host.dart

{
echo "SL1-G3 types + GC probe -- arm $ARM"
echo "out  : $OUT"
echo "date : $(date -u +%FT%TZ)"
echo "dm   : $DM line(s) in args.gn"
for f in gen_snapshot dartaotruntime vm_platform.dill; do
  echo "sha256 $(shasum -a 256 "$OUT/$f" | cut -d' ' -f1)  $f"
done
echo

echo "== host kernel + AOT snapshot =="
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages "$W/.dart_tool/package_config.json" \
  --dynamic-interface "$HERE/probe/di.yaml" \
  --dump-detailed-dynamic-interface "$W/di_actual.json" \
  -o "$W/host.dill" "$URI" 2>&1 | sed 's/^/   /'
echo "   gen_kernel exit=${PIPESTATUS[0]}"
"$OUT/gen_snapshot" --snapshot_kind=app-aot-elf --elf="$W/host.aot" "$W/host.dill" 2>&1 | sed 's/^/   /'
echo "   gen_snapshot exit=${PIPESTATUS[0]}"
[[ -f "$W/di_actual.json" ]] && cp "$W/di_actual.json" "$EVID/di_applied_$ARM.json"

echo "== pre-AOT import kernel =="
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot --no-link-platform \
  --packages "$W/.dart_tool/package_config.json" \
  -o "$W/host_import.dill" "$URI" 2>&1 | sed 's/^/   /'
echo "   gen_kernel(import) exit=${PIPESTATUS[0]}"

FAILED=0
for t in "${TESTS[@]}"; do
  echo
  echo "=================== TEST $t ==================="
  m=$(mod_for "$t")
  ARGS=("$t")
  if [[ -n "$m" ]]; then
    "$DART" "$D2B" --platform "$OUT/vm_platform.dill" \
      --import-dill "$W/host_import.dill" \
      -o "$W/$m.bytecode" "$W/$m.dart" 2>&1 | sed 's/^/   /'
    echo "   dart2bytecode($m) exit=${PIPESTATUS[0]}"
    if [[ ! -f "$W/$m.bytecode" ]]; then
      echo "   FAIL: no bytecode for $t — recorded as a FAILURE, not a skip"
      FAILED=$((FAILED+1)); continue
    fi
    echo "   bytecode sha256 $(shasum -a 256 "$W/$m.bytecode" | cut -d' ' -f1)"
    ARGS+=("$W/$m.bytecode" "file://$W/$m.dart")
  fi
  RUNOUT=$("$OUT/dartaotruntime" "$W/host.aot" "${ARGS[@]}" 2>&1); rc=$?
  sed 's/^/   /' <<<"$RUNOUT"
  echo "   run exit=$rc"
  if [[ "$DM" -eq 0 ]]; then
    # gc_control is ARM-INDEPENDENT: it measures ordinary AOT objects and the GC
    # instrument, neither of which depends on dynamic modules. It must PASS on
    # the OFF arm, and its passing there is what shows the collector instrument
    # is not entangled with the substrate under test. Every other test must
    # report the substrate absent.
    if [[ "$t" == "gc_control" ]]; then
      if [[ "$rc" -eq 0 ]]; then
        echo "   CONTROL ok: the collector behaves identically with dynamic modules OFF"
      else
        echo "   CONTROL FAIL: the GC falsification must pass on both arms"
        FAILED=$((FAILED+1))
      fi
    elif [[ "$rc" -eq 3 ]] && grep -q "ORACLE UNSUPPORTED" <<<"$RUNOUT"; then
      echo "   CONTROL ok: the substrate is correctly absent on this arm"
    else
      echo "   CONTROL FAIL: expected exit 3 with ORACLE UNSUPPORTED"
      FAILED=$((FAILED+1))
    fi
  else
    [[ "$rc" -eq 0 ]] || FAILED=$((FAILED+1))
  fi
done

echo
echo "SUMMARY arm=$ARM tests=${#TESTS[@]} failed=$FAILED"
[[ "$FAILED" -eq 0 ]] && echo "G3 ARM PASS" || echo "G3 ARM FAIL"
[[ "$DM" -eq 0 ]] && echo "(OFF arm: PASS means the substrate is correctly ABSENT)"
} > "$LOGF" 2>&1

tail -3 "$LOGF"
echo "transcript: $LOGF"
grep -q "G3 ARM PASS" "$LOGF"
