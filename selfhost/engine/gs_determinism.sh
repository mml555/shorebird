#!/usr/bin/env bash
# cspell:words Niced
# Phase 6 probe: is a from-scratch gen_snapshot build byte-reproducible?
# Niced hard and -j3 on purpose: this box also runs hermes-gateway.
set -euo pipefail
ENGINE_SRC=/data/shorebird-engine/src/flutter/engine/src
OUTBIN=/data/shorebird-engine/determinism
export PATH=/data/shorebird-engine/depot_tools:$PATH
mkdir -p "$OUTBIN"
cd "$ENGINE_SRC"
build_once() {
  local tag="$1"
  echo "=== [$tag] $(date -u +%FT%TZ) clean out/host_release ==="
  rm -rf out/host_release
  ./flutter/tools/gn --no-rbe --no-enable-unittests --runtime-mode=release
  echo "=== [$tag] $(date -u +%FT%TZ) ninja ==="
  nice -n 15 ninja -C out/host_release -j3 gen_snapshot
  cp out/host_release/gen_snapshot "$OUTBIN/gen_snapshot.$tag"
  echo "=== [$tag] sha256 ==="
  sha256sum "$OUTBIN/gen_snapshot.$tag"
}
build_once A
build_once B
echo "=== RESULT $(date -u +%FT%TZ) ==="
if cmp -s "$OUTBIN/gen_snapshot.A" "$OUTBIN/gen_snapshot.B"; then
  echo "DETERMINISTIC: byte-identical across two clean builds"
else
  echo "NON-DETERMINISTIC: builds differ"
  ls -l "$OUTBIN"/gen_snapshot.A "$OUTBIN"/gen_snapshot.B
fi
echo "hermes-gateway: $(systemctl --user is-active hermes-gateway 2>/dev/null || echo unknown)"
