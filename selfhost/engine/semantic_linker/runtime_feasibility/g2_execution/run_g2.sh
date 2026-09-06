#!/usr/bin/env bash
# cspell:words dartaotruntime dill semantic linker
# run_g2.sh -- SEMANTIC-LINKER-1 / G2. Five tests, five modules, five processes.
#
# ONE TEST PER PROCESS, for the reason G1 learned the hard way: attach and load
# in one process made load report "already loaded", a fact about the harness's
# ordering that would have been recorded as a fact about the substrate.
#
# MISSING EVIDENCE IS A FAILURE. Every stage records its exit code, a stage that
# does not run is reported as such, and the summary counts a test with no
# transcript as failed rather than skipping it. G2 says so explicitly, and it is
# the same rule verify_supported_state.sh follows.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LANE=${LANE:-/Volumes/build/semantic-linker/sl1}
SRC="$LANE/flutter/engine/src"
ARM=${ARM:-g2_on}
OUT="$SRC/out/sl1_$ARM"
EVID="$HERE/evidence"; mkdir -p "$EVID"
# grep -c PRINTS 0 and EXITS 1 when there is no match, so `|| echo 0` appended a
# second line and made every arithmetic test a syntax error. Take the output.
DM=$(grep -c '^dart_dynamic_modules' "$SRC/out/sl1_$ARM/args.gn" 2>/dev/null)
DM=${DM:-0}
LOGF="$EVID/g2_$ARM.txt"

DART_TREE="$SRC/flutter/third_party/dart"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
D2B="$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart"
DART="$OUT/dart-sdk/bin/dart"
# sanity FIRST and deliberately: it falsifies the oracle before the oracle
# is allowed to score anything else.
TESTS=(sanity dispatch callback identity throw catch)

[[ -d "$OUT" ]] || { echo "no build at $OUT" >&2; exit 2; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/lib" "$W/.dart_tool"
cp "$HERE/probe/g2_host.dart" "$W/lib/g2_host.dart"
for t in "${TESTS[@]}"; do cp "$HERE/probe/m_$t.dart" "$W/m_$t.dart"; done
cat > "$W/.dart_tool/package_config.json" <<JSON
{"configVersion":2,"packages":[{"name":"dynamic_modules","rootUri":"file://$W/","packageUri":"lib/","languageVersion":"3.9"}]}
JSON
URI=package:dynamic_modules/g2_host.dart

{
echo "SL1-G2 mixed-execution probe -- arm $ARM"
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

echo "== pre-AOT import kernel (modules compile against the host's kernel) =="
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot --no-link-platform \
  --packages "$W/.dart_tool/package_config.json" \
  -o "$W/host_import.dill" "$URI" 2>&1 | sed 's/^/   /'
echo "   gen_kernel(import) exit=${PIPESTATUS[0]}"

FAILED=0
for t in "${TESTS[@]}"; do
  echo
  echo "=================== TEST $t ==================="
  "$DART" "$D2B" --platform "$OUT/vm_platform.dill" \
    --import-dill "$W/host_import.dill" \
    -o "$W/m_$t.bytecode" "$W/m_$t.dart" 2>&1 | sed 's/^/   /'
  rc=${PIPESTATUS[0]}
  echo "   dart2bytecode exit=$rc"
  if [[ ! -f "$W/m_$t.bytecode" ]]; then
    echo "   FAIL: no bytecode produced for $t — recorded as a FAILURE, not a skip"
    FAILED=$((FAILED+1)); continue
  fi
  echo "   bytecode sha256 $(shasum -a 256 "$W/m_$t.bytecode" | cut -d' ' -f1) bytes $(wc -c < "$W/m_$t.bytecode" | tr -d ' ')"
  RUNOUT=$("$OUT/dartaotruntime" "$W/host.aot" "$t" "$W/m_$t.bytecode" "file://$W/m_$t.dart" 2>&1)
  rc=$?
  sed 's/^/   /' <<<"$RUNOUT"
  echo "   run exit=$rc"
  # THE TWO ARMS HAVE DIFFERENT CORRECT OUTCOMES, and scoring them by the same
  # rule made the control read as six failures. On an OFF build the ONLY correct
  # result is the oracle reporting UNSUPPORTED and exit 3 -- so that is asserted
  # positively rather than "nonzero is fine", which would pass on any crash.
  if [[ "$DM" -eq 0 ]]; then
    if [[ "$rc" -eq 3 ]] && grep -q "ORACLE UNSUPPORTED" <<<"$RUNOUT"; then
      echo "   CONTROL ok: the oracle is gated on dart_dynamic_modules"
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
[[ "$FAILED" -eq 0 ]] && echo "G2 ARM PASS" || echo "G2 ARM FAIL"
[[ "$DM" -eq 0 ]] && echo "(OFF arm: PASS here means the substrate is correctly ABSENT, not present)"
} > "$LOGF" 2>&1

tail -3 "$LOGF"
echo "transcript: $LOGF"
grep -q "G2 ARM PASS" "$LOGF"
