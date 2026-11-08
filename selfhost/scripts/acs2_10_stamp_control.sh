#!/usr/bin/env bash
# cspell:words ninja depot armv stampctl
# Isolate the GATE from the REVISION STAMP.
#
# arm64 built from the PATCHED source but with engine_version forced back to
# the pre-patch revision. If the resulting libflutter.so is byte-identical to
# the pre-patch control, then the whole observed delta was the stamp and the
# applicability gate provably changed nothing for arm64 — which is the control
# the ruling asked for.
set -uo pipefail
B=/Volumes/build/route-b/acs2
SRC=$B/flutter/engine/src
OLD=dfa2b24ac38477f3705ff0357530f33fe09474b8
export PATH=/Volumes/build/ios-engine/depot_tools:$PATH
export GIT_CONFIG_GLOBAL=/Volumes/build/ios-engine/gitconfig
export DEPOT_TOOLS_UPDATE=0
cd "$SRC" || exit 1
OUT=out/android_release_arm64_stampctl
rm -rf "$OUT"
echo "=== started $(date -u +%FT%TZ); source $(git -C flutter rev-parse HEAD) ==="
# Same flags, then rewrite only engine_version and regenerate with raw gn so
# tools/gn cannot re-derive it from git.
cp -R out/android_release_arm64 "$OUT"
sed -i '' "s/^engine_version = .*/engine_version = \"$OLD\"/" "$OUT/args.gn"
grep -E "^engine_version" "$OUT/args.gn" | sed 's/^/  forced: /'
./flutter/third_party/gn/gn gen "$OUT" --check
echo "  gn gen exit=$?"
ninja -C "$OUT" \
  zip_archives/android-arm64-release/darwin-x64.zip \
  flutter/shell/platform/android:abi_jars
echo "=== ninja exit=$? $(date -u +%FT%TZ) ==="
echo "=== done $(date -u +%FT%TZ) ==="
