#!/usr/bin/env bash
# cspell:words Niced
#
# Phase 6 probe 4: WHICH object files are non-deterministic?
#
# Probe 3 established that relinking identical objects reproduces
# libflutter.so byte-for-byte, so the instability is in compilation. Rather
# than merely confirming that with a second build, this identifies the
# culprits: hash every .o from build 1, rebuild clean, and diff the hashes.
#
# A named list of differing objects is what turns "the engine build is not
# reproducible" into a fixable bug — the pattern in the names (Rust-adjacent?
# Skia? anything embedding __DATE__ or a build path?) is the diagnosis.
#
# Assumes build 1's out dir is still intact. Niced hard, -j3: hermes lives here.
set -euo pipefail

E=/data/shorebird-engine/src/flutter/engine/src
OUT=/data/shorebird-engine/determinism
OUT_DIR=out/android_release_arm64
JOBS="${JOBS:-3}"
export PATH=/data/shorebird-engine/depot_tools:/data/shorebird-engine/cargo/bin:$PATH
mkdir -p "$OUT"
cd "$E"

[ -d "$OUT_DIR" ] || { echo "no $OUT_DIR — run link_determinism.sh first" >&2; exit 1; }

echo "=== SNAPSHOT A $(date -u +%FT%TZ) hashing objects from build 1 ==="
# Paths are relative to $OUT_DIR so the two snapshots are comparable.
( cd "$OUT_DIR" && find . -name '*.o' -type f | sort | xargs -r sha256sum ) > "$OUT/objects.A"
echo "objects hashed: $(wc -l < "$OUT/objects.A")"

echo "=== REBUILD $(date -u +%FT%TZ) clean, identical source ==="
rm -rf "$OUT_DIR"
./flutter/tools/gn --no-rbe --no-enable-unittests \
  --android --android-cpu=arm64 --runtime-mode=release
nice -n 15 ninja -C "$OUT_DIR" -j "$JOBS" default gen_snapshot
echo "=== REBUILD DONE $(date -u +%FT%TZ) ==="

echo "=== SNAPSHOT B $(date -u +%FT%TZ) ==="
( cd "$OUT_DIR" && find . -name '*.o' -type f | sort | xargs -r sha256sum ) > "$OUT/objects.B"
echo "objects hashed: $(wc -l < "$OUT/objects.B")"

SO="$(find "$OUT_DIR" -maxdepth 1 -name libflutter.so | head -1)"
cp "$SO" "$OUT/libflutter.build2.so"

echo "=== RESULT $(date -u +%FT%TZ) ==="
echo "libflutter.so build1: $(awk '{print $1}' <<<"$(sha256sum "$OUT/libflutter.link1.so")")"
echo "libflutter.so build2: $(awk '{print $1}' <<<"$(sha256sum "$OUT/libflutter.build2.so")")"
if cmp -s "$OUT/libflutter.link1.so" "$OUT/libflutter.build2.so"; then
  echo "SO IDENTICAL across two clean builds — the earlier report may be stale."
else
  echo "SO DIFFERS across two clean builds (expected)."
fi

# Objects present in both, differing in content. Compare on path, not order.
join -j 2 <(sort -k2 "$OUT/objects.A") <(sort -k2 "$OUT/objects.B") \
  | awk '$2 != $3 {print $1}' > "$OUT/objects.differing"
ONLY_A=$(comm -23 <(awk '{print $2}' "$OUT/objects.A" | sort) <(awk '{print $2}' "$OUT/objects.B" | sort) | wc -l)
ONLY_B=$(comm -13 <(awk '{print $2}' "$OUT/objects.A" | sort) <(awk '{print $2}' "$OUT/objects.B" | sort) | wc -l)

echo "objects only in A: $ONLY_A   only in B: $ONLY_B"
echo "objects differing: $(wc -l < "$OUT/objects.differing") of $(wc -l < "$OUT/objects.A")"
echo "--- first 40 differing objects ---"
head -40 "$OUT/objects.differing"
echo "--- differing objects grouped by top-level directory ---"
sed 's|^\./obj/||; s|/.*||' "$OUT/objects.differing" | sort | uniq -c | sort -rn | head -15
echo "hermes-gateway: $(systemctl --user is-active hermes-gateway 2>/dev/null || echo unknown)"
