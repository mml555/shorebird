#!/usr/bin/env bash
# cspell:words Niced
#
# Phase 6 probe 3: where does libflutter.so's non-determinism actually live?
#
# Staged so the expensive half is paid once. Step 1 is a full clean build of the
# android-arm64 cell. Step 2 deletes ONLY the final link output and re-runs
# ninja, so the same object files are relinked — if the .so differs, the link is
# the culprit and we never needed a second full build. Step 3 (a second clean
# build, testing compilation) is deliberately NOT run here; do it only if step 2
# comes back stable.
#
# Two cheaper suspects are already eliminated by measurement: gen_snapshot and
# the Rust updater both build byte-identically, and both are full-LTO builds, so
# neither LTO nor cargo codegen explains this on its own.
#
# Niced hard and -j3: this box also runs hermes-gateway.
set -euo pipefail

E=/data/shorebird-engine/src/flutter/engine/src
OUT=/data/shorebird-engine/determinism
OUT_DIR=out/android_release_arm64
JOBS="${JOBS:-3}"
export PATH=/data/shorebird-engine/depot_tools:/data/shorebird-engine/cargo/bin:$PATH
mkdir -p "$OUT"
cd "$E"

# build.sh refuses without this, and cargo would fail deep into the build.
rustup target list --installed 2>/dev/null | grep -qx 'aarch64-linux-android' \
  || { echo "rust target aarch64-linux-android missing" >&2; exit 1; }

echo "=== STEP 1 $(date -u +%FT%TZ) clean gn + full build ==="
rm -rf "$OUT_DIR"
# Flags mirror selfhost/engine/build.sh --cell android-arm64 exactly. There is
# no shorebird_runtime GN arg at this revision; the hooks are unconditional.
./flutter/tools/gn --no-rbe --no-enable-unittests \
  --android --android-cpu=arm64 --runtime-mode=release
nice -n 15 ninja -C "$OUT_DIR" -j "$JOBS" default gen_snapshot
echo "=== STEP 1 DONE $(date -u +%FT%TZ) ==="

SO="$(find "$OUT_DIR" -maxdepth 1 -name libflutter.so | head -1)"
[ -n "$SO" ] || { echo "could not find libflutter.so under $OUT_DIR" >&2; ls "$OUT_DIR" | head -30; exit 1; }
echo "libflutter.so: $SO"
cp "$SO" "$OUT/libflutter.link1.so"
sha256sum "$OUT/libflutter.link1.so"

echo "=== STEP 2 $(date -u +%FT%TZ) relink from the SAME objects ==="
rm -f "$SO"
nice -n 15 ninja -C "$OUT_DIR" -j "$JOBS" default gen_snapshot
cp "$SO" "$OUT/libflutter.link2.so"
sha256sum "$OUT/libflutter.link2.so"

echo "=== RESULT $(date -u +%FT%TZ) ==="
if cmp -s "$OUT/libflutter.link1.so" "$OUT/libflutter.link2.so"; then
  echo "LINK DETERMINISTIC: relink from identical objects is byte-identical"
  echo "  => the non-determinism is in COMPILATION, not the link."
  echo "  => next: a second full clean build (step 3), which costs another full build."
else
  echo "LINK NON-DETERMINISTIC: same objects, different libflutter.so"
  echo "  => the link step alone explains it; no second full build needed."
  ls -l "$OUT/libflutter.link1.so" "$OUT/libflutter.link2.so"
fi
echo "hermes-gateway: $(systemctl --user is-active hermes-gateway 2>/dev/null || echo unknown)"
