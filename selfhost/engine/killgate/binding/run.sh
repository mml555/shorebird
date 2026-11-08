#!/usr/bin/env bash
# Spike B — bytecode→base binding kill gate (Route B's crux).
#
# Question: does patch bytecode compiled with --import-dill resolve references
# into the base AOT program at LOAD time — an app symbol (hostSuffix) and an
# SDK symbol (print) — and execute?
#
# Matrix:
#   r1 self-contained        (regression control for the --import-dill pipeline)
#   r2 calls hostSuffix()    (app-symbol binding)
#   r3 calls print()         (SDK-symbol binding, the canonical
#                             bytecode_reader.cc:1172 failure)
# × arm1: @pragma('vm:entry-point') retention on hostSuffix (known crutch)
#   arm2: gen_kernel --dynamic-interface di.yaml (upstream's designed contract)
#
# PASS: r2 and r3 load (no bytecode_reader FATAL) and execute under an arm.
# FAIL (compile-time): dart2bytecode --import-dill crashes on the PRE-AOT
#   kernel (the dynmod workaround does not generalize).
# FAIL (load-time, structural): resolution fails under BOTH arms.
#
# Prerequisite: the Track E rig (out/host_release_arm64 with
# dart_dynamic_modules=true and killgate/0001-attach-bytecode-native.patch).
set -uo pipefail

SRC="${SRC:-/Volumes/build/ios-engine/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
WORK="${WORK:-$(mktemp -d)}"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }

[ -d "$OUT" ] || die "no build at $OUT"
grep -q 'dart_dynamic_modules = true' "$OUT/args.gn" 2>/dev/null \
  || die "dart_dynamic_modules is not true in $OUT/args.gn"

GEN_SNAPSHOT="$OUT/gen_snapshot"
AOT_RUNTIME="$OUT/dartaotruntime"
DART="$OUT/dart-sdk/bin/dart"
GEN_KERNEL="$SRC/flutter/third_party/dart/pkg/vm/bin/gen_kernel.dart"
DART2BC="$SRC/flutter/third_party/dart/pkg/dart2bytecode/bin/dart2bytecode.dart"

TARGET_URI="package:dynamic_modules/target_binding.dart"
declare -a RESULTS=()

# --- build one arm's target + import dill, then run all three replacements ----
run_arm() {  # run_arm <arm1|arm2>
  local arm="$1"
  local d="$WORK/$arm"
  mkdir -p "$d/lib" "$d/.dart_tool"

  if [[ "$arm" == "arm1" ]]; then
    cp "$HERE/target_binding.dart" "$d/lib/target_binding.dart"
  else
    # arm2: strip the vm:entry-point crutch from hostSuffix; retention must
    # come from the dynamic interface alone.
    grep -v 'ARM1-PRAGMA' "$HERE/target_binding.dart" > "$d/lib/target_binding.dart"
  fi

  cat > "$d/.dart_tool/package_config.json" <<JSON
{
  "configVersion": 2,
  "packages": [
    {
      "name": "dynamic_modules",
      "rootUri": "file://$d/",
      "packageUri": "lib/",
      "languageVersion": "3.9"
    }
  ]
}
JSON

  local di_args=()
  [[ "$arm" == "arm2" ]] && di_args=(--dynamic-interface "$HERE/di.yaml")

  note "[$arm] AOT kernel $( [[ "$arm" == "arm2" ]] && echo '(with dynamic interface)' )"
  if ! "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
      --packages "$d/.dart_tool/package_config.json" \
      ${di_args[@]+"${di_args[@]}"} \
      -o "$d/target.dill" "$TARGET_URI" 2> "$d/gen_kernel.err"; then
    cat "$d/gen_kernel.err" >&2
    if [[ "$arm" == "arm2" ]] && grep -qi 'dart:core\|has not been indexed' "$d/gen_kernel.err"; then
      RESULTS+=("$arm  -   FINDING: gen_kernel refuses the di.yaml (likely the dart:core entry) — SDK retention needs another mechanism")
    else
      RESULTS+=("$arm  -   FAIL: target kernel did not build")
    fi
    return 1
  fi

  note "[$arm] AOT snapshot"
  "$GEN_SNAPSHOT" --snapshot_kind=app-aot-elf --elf="$d/target.aot" "$d/target.dill" \
    || { RESULTS+=("$arm  -   FAIL: gen_snapshot"); return 1; }

  note "[$arm] pre-AOT import kernel (the dynmod --import-dill workaround)"
  "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot --no-link-platform \
    --packages "$d/.dart_tool/package_config.json" \
    -o "$d/host_import.dill" "$TARGET_URI" \
    || { RESULTS+=("$arm  -   FAIL: host_import.dill did not build"); return 1; }

  local r expected
  for r in r1 r2 r3; do
    case "$r" in
      r1) expected='NEW' ;;
      r2) expected='NEW-HOST' ;;
      r3) expected='NEW-PRINTED' ;;
    esac

    note "[$arm/$r] dart2bytecode --import-dill"
    if ! "$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" \
        --import-dill "$d/host_import.dill" \
        --packages "$d/.dart_tool/package_config.json" \
        -o "$d/$r.bytecode" "$HERE/replacement_$r.dart" 2> "$d/$r.compile.err"; then
      cat "$d/$r.compile.err" >&2
      RESULTS+=("$arm  $r  FAIL(compile): dart2bytecode crashed — see $d/$r.compile.err")
      continue
    fi

    note "[$arm/$r] attach + run (expect C++ invoke -> $expected)"
    local out rc
    out="$("$AOT_RUNTIME" "$d/target.aot" "$d/$r.bytecode" "$TARGET_URI" 2>&1)"
    rc=$?
    echo "$out" | sed 's/^/    | /'
    # The judged line is the attach native's own DartEntry::InvokeFunction
    # result — the one execution path proven to enter the interpreter. The
    # Dart-level "BINDING: RESULT=" is expected to stay OLD (every Dart-side
    # call shape is statically bound in AOT); that is the call-emission gap,
    # not a binding failure, and it is judged by Route B's next milestone,
    # not by this spike.
    if echo "$out" | grep -q "ATTACH: C++ invoke of target returned: $expected"; then
      RESULTS+=("$arm  $r  PASS: loaded, bound, executed ($expected via interpreter)")
    elif echo "$out" | grep -q 'Unable to find\|bytecode_reader'; then
      RESULTS+=("$arm  $r  FAIL(load): resolution died — $(echo "$out" | grep -m1 'Unable to find')")
    elif echo "$out" | grep -q 'BINDING: ATTACH-FAILED'; then
      RESULTS+=("$arm  $r  FAIL(attach): attachBytecodeToFunction returned false")
    elif echo "$out" | grep -q 'ATTACH: C++ invoke of target returned:'; then
      RESULTS+=("$arm  $r  FAIL(exec): wrong value — $(echo "$out" | grep -m1 'C++ invoke')")
    else
      RESULTS+=("$arm  $r  FAIL(runtime rc=$rc): $(echo "$out" | tail -1)")
    fi
  done
}

run_arm arm1 || true
run_arm arm2 || true

echo; echo "===== SPIKE B RESULTS ====="
printf '%s\n' "${RESULTS[@]}"
echo "workdir kept: $WORK"

# Verdict: the crux passes if r2 AND r3 pass under at least one arm.
if printf '%s\n' "${RESULTS[@]}" | grep -q 'r2  PASS' \
   && printf '%s\n' "${RESULTS[@]}" | grep -q 'r3  PASS'; then
  echo "SPIKE B: PASS — bytecode binds to the base program (app + SDK symbols)"
  exit 0
fi
echo "SPIKE B: NOT PASSED — see results above"
exit 1
