#!/usr/bin/env bash
# measure_scale.sh -- SM1-G4: the retention cost CURVE, measured not extrapolated.
#
# SL1-G6B measured +16,704 bytes (+1.88%) for ONE declared-patchable member and
# said explicitly that the number must not be multiplied naively. This builds the
# same program at several N, each twice -- contract present and contract absent
# -- so the delta at every N is the cost of the contract and nothing else.
#
# The two builds at a given N differ ONLY in whether --dynamic-interface is
# passed. Same source, same compiler, same flags otherwise.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
DT=${DT:-$SRC/flutter/third_party/dart}
DART="$OUT/dart-sdk/bin/dart"
NS=${NS:-"0 1 2 4 8 16 32 64 128"}
JSON=${1:-/dev/null}

echo "N,aot_absent,aot_present,delta,pct,per_member"
ROWS=""
for N in $NS; do
  W=$(mktemp -d); mkdir -p "$W/lib" "$W/.dart_tool"
  python3 "$HERE/gen_scale_host.py" "$N" "$W/gen" >/dev/null
  cp "$W/gen/scale_host.dart" "$W/lib/"
  printf '{"configVersion":2,"packages":[{"name":"dynamic_modules","rootUri":"file://%s/","packageUri":"lib/","languageVersion":"3.9"}]}' "$W" \
    > "$W/.dart_tool/package_config.json"
  URI=package:dynamic_modules/scale_host.dart

  # contract ABSENT
  "$DART" "$DT/pkg/vm/bin/gen_kernel.dart" --platform "$OUT/vm_platform.dill" --aot \
    --packages "$W/.dart_tool/package_config.json" -o "$W/a.dill" "$URI" >/dev/null 2>&1 || { echo "  N=$N absent kernel FAILED" >&2; rm -rf "$W"; continue; }
  "$OUT/gen_snapshot" --snapshot_kind=app-aot-elf --elf="$W/a.aot" "$W/a.dill" >/dev/null 2>&1
  # contract PRESENT
  "$DART" "$DT/pkg/vm/bin/gen_kernel.dart" --platform "$OUT/vm_platform.dill" --aot \
    --packages "$W/.dart_tool/package_config.json" --dynamic-interface "$W/gen/di_scale.yaml" \
    -o "$W/b.dill" "$URI" >/dev/null 2>&1 || { echo "  N=$N present kernel FAILED" >&2; rm -rf "$W"; continue; }
  "$OUT/gen_snapshot" --snapshot_kind=app-aot-elf --elf="$W/b.aot" "$W/b.dill" >/dev/null 2>&1

  if [[ -f "$W/a.aot" && -f "$W/b.aot" ]]; then
    A=$(stat -f%z "$W/a.aot"); B=$(stat -f%z "$W/b.aot")
    D=$((B-A))
    PCT=$(python3 -c "print(f'{($D)*100/$A:+.3f}')")
    PER=$(python3 -c "print('n/a' if $N==0 else f'{$D/$N:.1f}')")
    echo "$N,$A,$B,$D,$PCT,$PER"
    ROWS="$ROWS{\"n\":$N,\"absent\":$A,\"present\":$B,\"delta\":$D,\"per_member\":\"$PER\"},"
  else
    echo "  N=$N snapshot FAILED" >&2
  fi
  rm -rf "$W"
done
[[ "$JSON" != /dev/null ]] && printf '{"schema":"semantic-map-1/g4-scale/1","rows":[%s]}\n' "${ROWS%,}" > "$JSON"
exit 0
