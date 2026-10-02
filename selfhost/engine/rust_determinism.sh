#!/usr/bin/env bash
# Phase 6 probe 2: is the Rust updater byte-reproducible?
#
# Builds the real aarch64-linux-android target twice, through the engine's own
# build_rust_updater.py, so this measures exactly the artifact that gets linked
# into libflutter.so — not a host-target approximation.
#
# Context: the crate already sets codegen-units = 1 and lto = true in
# [profile.release], so cargo's parallel-codegen non-determinism is already
# excluded by configuration. This probe confirms that by measurement and
# eliminates Rust as a suspect, leaving the C++/ThinLTO link of libflutter.so.
set -euo pipefail
E=/data/shorebird-engine/src/flutter/engine/src/flutter
# The NDK is installed under a version directory (28.2.13676358 today), and
# cc-rs wants the root that *contains* toolchains/. Pointing at the parent gives
# a "failed to find tool ...-clang" error that looks like a missing NDK rather
# than a path off by one level. Derived so an NDK bump does not break this.
NDK="$(find "$E/third_party/android_tools/sdk/ndk" -maxdepth 1 -mindepth 1 -type d | sort -V | tail -1)"
[ -n "$NDK" ] || { echo "no NDK found" >&2; exit 1; }
echo "NDK: $NDK"
OUT=/data/shorebird-engine/determinism
export PATH=/data/shorebird-engine/cargo/bin:$PATH
mkdir -p "$OUT"

run() {
  # Split, not `local tag="$1" td="...$tag"`: bash expands every right-hand
  # side of a `local` before performing any of its assignments, so the second
  # would read an unset $tag and die under `set -u`.
  local tag="$1"
  local td="$OUT/rust_target_$tag"
  rm -rf "$td"
  echo "=== [$tag] $(date -u +%FT%TZ) cargo build ==="
  nice -n 15 python3 "$E/shell/common/shorebird/build_rust_updater.py" \
    --rust-target aarch64-linux-android \
    --manifest-dir "$E/third_party/updater" \
    --target-dir "$td" \
    --output-lib "$td/aarch64-linux-android/release/libupdater.a" \
    --stamp "$td/stamp" \
    --ndk-path "$NDK" \
    --android-api-level 24
  cp "$td/aarch64-linux-android/release/libupdater.a" "$OUT/libupdater.$tag.a"
  sha256sum "$OUT/libupdater.$tag.a"
}

run A
run B

echo "=== RESULT $(date -u +%FT%TZ) ==="
if cmp -s "$OUT/libupdater.A.a" "$OUT/libupdater.B.a"; then
  echo "RUST DETERMINISTIC: libupdater.a byte-identical across two clean builds"
else
  echo "RUST NON-DETERMINISTIC: libupdater.a differs"
  ls -l "$OUT/libupdater.A.a" "$OUT/libupdater.B.a"
fi
echo "hermes-gateway: $(systemctl --user is-active hermes-gateway 2>/dev/null || echo unknown)"
