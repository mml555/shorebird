#!/usr/bin/env bash
# cspell:words armv androideabi
# One-time: depot_tools, Rust 1.99.1 with the Apple targets, the shorebird-flutter
# checkout at the engine commit, and gclient sync. Safe to re-run.
set -euo pipefail
source "$HOME/shorebird-engine/env.sh"
# The frozen tree is d0714887 (compatibility.yaml engine_revision). Override with REV=... only
# for a deliberate re-bootstrap of another pin.
REV="${REV:-d0714887dd95d2990e0185fe1893523f3d600cc5}"
log(){ echo "[$(date '+%F %T')] $*"; }
cd "$W"
if [[ ! -d depot_tools ]]; then
  log "clone depot_tools"
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
  (cd depot_tools && DEPOT_TOOLS_UPDATE=1 ./ensure_bootstrap)
fi
log "rust 1.99.1"
rustup toolchain install 1.99.1 --profile minimal
rustup default 1.99.1
rustup target add --toolchain 1.99.1 aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
if [[ ! -d flutter/.git ]]; then
  log "clone shorebird-flutter"
  git clone --filter=blob:none --no-checkout https://github.com/mml555/shorebird-flutter.git flutter
fi
cd flutter
git fetch origin "$REV"
git checkout --detach "$REV"
[[ "$(git rev-parse HEAD)" == "$REV" ]]
cat > .gclient <<'G'
solutions = [
  {
    "custom_deps": {},
    "deps_file": "DEPS",
    "managed": False,
    "name": ".",
    "safesync_url": "",
    "url": "https://github.com/mml555/shorebird-flutter.git",
    "custom_vars": {
      # gs://shorebird-dart-sdk-prebuilt is private; Dart is built from source.
      "download_dart_sdk": False,
    },
  },
]
G
log "gclient sync (long)"
gclient sync --no-history
log "dart: $(git -C engine/src/flutter/third_party/dart rev-parse HEAD)"
# Xcode 27 SDKs are newer than the engine's pinned clang 23 (see
# tools/strip_x1.py). Point the engine at copies without it (the gclient hook above just
# re-created the links to Xcode's SDKs).
X="$(xcode-select -p)/Platforms"
P=engine/src/flutter/prebuilts/SDKs
for sdk in "$P"/MacOSX*.sdk "$P"/iPhoneOS*.sdk "$P"/iPhoneSimulator*.sdk; do
  name="$(basename "$sdk")"
  plat="${name%%[0-9]*}"
  "$W/tools/strip_x1.py" "$X/$plat.platform/Developer/SDKs/$name" "$W/sdks/$name"
  ln -sfn "$W/sdks/$name" "$sdk"
done
log "bootstrap done"
