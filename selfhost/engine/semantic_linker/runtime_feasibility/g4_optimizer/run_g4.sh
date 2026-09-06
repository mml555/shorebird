#!/usr/bin/env bash
# cspell:words dartaotruntime objdump symbolize dill semantic linker devirtualized
# run_g4.sh -- SEMANTIC-LINKER-1 / G4. Five call shapes x {HostChild control,
# PatchChild subject} x {fenced contract, unfenced contract}, with RUNTIME truth
# and COMPILER truth for each.
#
# COMPILER TRUTH COMES FROM THE ARTIFACT THAT RAN. The frozen product
# gen_snapshot cannot print flow graphs or disassembly -- those flags are R() in
# flag_list.h and this is a PRODUCT build, so they are compiled to constants.
# Rather than compile a different, non-product compiler and reason about its
# decisions, this disassembles the SAME host.aot the run executed, with the
# engine's own llvm-objdump. It is the bytes, not a report about the bytes.
#
# The discriminator is mechanical:
#   ldr xN,[x21,...] + blr   -> DISPATCH_TABLE   (dispatch point left open)
#   bl <ConcreteImpl>        -> DIRECT_CALL      (devirtualized: bypass risk)
#   neither, body present    -> INLINED          (bypass risk)
# The raw disassembly of every shape is banked beside the verdict so the
# classification can be checked rather than believed.
#
# G4 DOES NOT FIX ANYTHING. A bypass is banked, attributed, and left in place.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LANE=${LANE:-/Volumes/build/semantic-linker/sl1}
SRC="$LANE/flutter/engine/src"
ARM=${ARM:-g3_on}
OUT="$SRC/out/sl1_$ARM"
LLVM="$SRC/flutter/buildtools/mac-arm64/clang/bin"
EVID="$HERE/evidence"; mkdir -p "$EVID"
DART_TREE="$SRC/flutter/third_party/dart"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
D2B="$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart"
DART="$OUT/dart-sdk/bin/dart"
SHAPES=(s1_virtual s2_monomorphic s3_chain_a s3_chain_b s4_generic s5_fieldCall)

[[ -d "$OUT" ]] || { echo "no build at $OUT" >&2; exit 2; }
[[ -x "$LLVM/llvm-objdump" ]] || { echo "no llvm-objdump at $LLVM" >&2; exit 2; }

# Four arms: {two host implementations, one host implementation} x {contract
# present, contract absent}. The SOLO arms are the ones that can actually answer
# the question -- with two implementations reachable the compiler must emit a
# dispatch call regardless of the contract.
for VARIANT in fenced unfenced solo_fenced solo_unfenced soloinl_fenced soloinl_unfenced; do
  case "$VARIANT" in
    soloinl_*) HOSTSRC=g4_host_solo_inl.dart; MODSRC=m_patchchild_soloinl.dart ;;
    solo_*)    HOSTSRC=g4_host_solo.dart;     MODSRC=m_patchchild_solo.dart ;;
    *)         HOSTSRC=g4_host.dart;          MODSRC=m_patchchild.dart ;;
  esac
  DI="$HERE/probe/di_$VARIANT.yaml"
  LOGF="$EVID/g4_${VARIANT}.txt"
  DIS="$EVID/g4_${VARIANT}_disassembly.txt"
  W=$(mktemp -d)
  mkdir -p "$W/lib" "$W/.dart_tool"
  cp "$HERE/probe/$HOSTSRC" "$W/lib/$HOSTSRC"
  cp "$HERE/probe/$MODSRC" "$W/"
  cat > "$W/.dart_tool/package_config.json" <<JSON
{"configVersion":2,"packages":[{"name":"dynamic_modules","rootUri":"file://$W/","packageUri":"lib/","languageVersion":"3.9"}]}
JSON
  URI=package:dynamic_modules/$HOSTSRC
  {
    echo "SL1-G4 optimizer adversity -- contract variant: $VARIANT"
    echo "out  : $OUT"
    echo "di   : $DI"
    echo "date : $(date -u +%FT%TZ)"
    echo
    echo "== host kernel + AOT snapshot =="
    "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
      --packages "$W/.dart_tool/package_config.json" --dynamic-interface "$DI" \
      --dump-detailed-dynamic-interface "$W/di_actual.json" \
      -o "$W/host.dill" "$URI" 2>&1 | sed 's/^/   /'
    echo "   gen_kernel exit=${PIPESTATUS[0]}"
    "$OUT/gen_snapshot" --snapshot_kind=app-aot-elf --elf="$W/host.aot" "$W/host.dill" 2>&1 | sed 's/^/   /'
    echo "   gen_snapshot exit=${PIPESTATUS[0]}"
    [[ -f "$W/host.aot" ]] || { echo "   FAIL: no AOT snapshot"; exit 1; }
    echo "   host.aot sha256 $(shasum -a 256 "$W/host.aot" | cut -d' ' -f1)"
    [[ -f "$W/di_actual.json" ]] && cp "$W/di_actual.json" "$EVID/di_applied_$VARIANT.json"

    echo
    echo "== module =="
    "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot --no-link-platform \
      --packages "$W/.dart_tool/package_config.json" -o "$W/host_import.dill" "$URI" 2>&1 | sed 's/^/   /'
    "$DART" "$D2B" --platform "$OUT/vm_platform.dill" --import-dill "$W/host_import.dill" \
      -o "$W/m.bytecode" "$W/$MODSRC" 2>&1 | sed 's/^/   /'
    echo "   dart2bytecode exit=${PIPESTATUS[0]}"

    echo
    echo "== RUNTIME TRUTH =="
    if [[ -f "$W/m.bytecode" ]]; then
      "$OUT/dartaotruntime" "$W/host.aot" "$W/m.bytecode" "file://$W/$MODSRC" 2>&1 | sed 's/^/   /'
      echo "   run exit=${PIPESTATUS[0]}"
    else
      echo "   FAIL: no bytecode — recorded as a failure, not a skip"
    fi

    echo
    echo "== COMPILER TRUTH (disassembly of the SAME host.aot) =="
    for s in "${SHAPES[@]}"; do
      body=$("$LLVM/llvm-objdump" -d --symbolize-operands --no-show-raw-insn "$W/host.aot" 2>/dev/null \
             | awk -v s="<$s>:" 'index($0,s){f=1} f{print; if(f && /\tret$/){exit}}')
      if [[ -z "$body" ]]; then
        echo "  $s: NO SYMBOL — the shape was fully inlined away or never emitted (INLINED_OR_ABSENT)"
        continue
      fi
      form=UNCLASSIFIED
      # Stub branches are not calls to Dart code. Counting them made every
      # fully-inlined shape read as UNCLASSIFIED instead of "no call".
      real=$(grep -v 'bl\t *<stub ' <<<"$body")
      dedup=$(grep -oE 'bl\s+<s[0-9][a-zA-Z0-9_]*>' <<<"$real" | head -1 | grep -oE 's[0-9][a-zA-Z0-9_]*')
      if grep -qE 'ldr\s+x[0-9]+, \[x21' <<<"$real" && grep -q 'blr' <<<"$real"; then
        form=DISPATCH_TABLE
      elif grep -qE '^\s+[0-9a-f]+:\s+bl\s+<(Base|HostChild|execute)' <<<"$real"; then
        form=DIRECT_CALL_DEVIRTUALIZED
      elif [[ -n "$dedup" ]]; then
        # The optimizer emitted identical code for several shapes and merged
        # them (dedup_instructions is on in this build), or tail-called one into
        # another. Not a verdict of its own: the merged target's form IS this
        # shape's form, so it is named rather than swallowed.
        form="DEDUPED_INTO_${dedup}"
      elif ! grep -qE '\b(bl|blr)\b' <<<"$real"; then
        form=NO_CALL_INLINED
      fi
      echo "  $s: $form"
      { echo "########## $s ($VARIANT) : $form"; echo "$body"; echo; } >> "$DIS"
    done
  } > "$LOGF" 2>&1
  rm -rf "$W"
  echo "variant $VARIANT -> $LOGF"
done
