#!/usr/bin/env bash
# obfuscation_arm.sh -- SM1-G1: MEASURE, rather than reason about, what
# obfuscation does to declaration identity.
#
# The map is derived from the KERNEL and obfuscation is a snapshot-time
# transform, so the expected answer is "declaration_id unchanged, runtime name
# changed". #50 requires that to be measured, not asserted -- so this actually
# builds an obfuscated snapshot, saves its obfuscation map, and reports both
# halves.
set -uo pipefail
SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
CORPUS=$1; W=$2
mkdir -p "$W"
bash "$(dirname "$0")/../../g0_freeze/lib/build_corpus_dill.sh" "$CORPUS" "$W/obf.dill" >/dev/null 2>&1 \
  || { echo "DILL_BUILD_FAILED"; exit 1; }
# Plain snapshot.
"$OUT/gen_snapshot" --snapshot_kind=app-aot-elf --elf="$W/plain.aot" "$W/obf.dill" >/dev/null 2>&1 \
  || { echo "PLAIN_SNAPSHOT_FAILED"; exit 1; }
# Obfuscated snapshot, with the rename map saved so the effect is visible.
"$OUT/gen_snapshot" --snapshot_kind=app-aot-elf --obfuscate \
  --save-obfuscation-map="$W/obfmap.json" \
  --elf="$W/obf.aot" "$W/obf.dill" >/dev/null 2>&1 \
  || { echo "OBFUSCATED_SNAPSHOT_FAILED"; exit 1; }
echo "OK $(shasum -a 256 "$W/plain.aot" | cut -d' ' -f1) $(shasum -a 256 "$W/obf.aot" | cut -d' ' -f1)"
