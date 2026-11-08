#!/usr/bin/env bash
# cspell:words armv gclient prebuilt ninja depot cipd openjdk ddm
# ANDROID-CELL-SUPPLY-2 gate 1, step 2: sync the DEPS-pinned Android deps into
# the scratch checkout.
#
# The copy came from an already-synced tree, so every non-Android dep is already
# at its DEPS revision and this should ADD the Android entries rather than move
# anything. `download_android_deps` is true on macOS (DEPS:102), which is why
# they are fetchable at all — the original checkout simply never asked.
#
# The Dart custom_dep stays the fork at 6b58bb3a (file://), and
# download_dart_sdk stays False, so Dart is still built from source. Nothing
# about the lineage changes.
set -uo pipefail
B=/Volumes/build/route-b/acs2
export PATH=/Volumes/build/ios-engine/depot_tools:$PATH
export GIT_CONFIG_GLOBAL=/Volumes/build/ios-engine/gitconfig
export DEPOT_TOOLS_UPDATE=0
cd "$B/flutter" || exit 1
echo "=== started $(date -u +%FT%TZ) ==="
echo "--- engine revision before: $(git -C engine/src/flutter rev-parse HEAD) ---"
gclient sync --no-history --shallow -v 2>&1 | tail -80
echo "=== gclient exit=${PIPESTATUS[0]} ==="
echo "--- engine revision after:  $(git -C engine/src/flutter rev-parse HEAD) ---"
echo "--- android deps present? ---"
for p in engine/src/flutter/third_party/android_tools \
         engine/src/flutter/third_party/android_embedding_dependencies; do
  printf "  %-64s %s\n" "$p" "$([ -d "$p" ] && echo PRESENT || echo ABSENT)"
done
ls engine/src/flutter/third_party/android_tools 2>/dev/null | head -8
echo "=== done $(date -u +%FT%TZ) ==="
