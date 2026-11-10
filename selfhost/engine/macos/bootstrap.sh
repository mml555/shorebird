#!/usr/bin/env bash
# cspell:words androideabi armv softwareupdate
# One-time: depot_tools, Rust 1.99.1 with the Apple targets, the shorebird-flutter
# checkout at the engine commit, gclient sync, and the patched Xcode SDK copies.
# Re-run it to resume an interrupted setup, but never while a build is running:
# it re-creates the SDK copies the build compiles against.
#
# usage: bootstrap.sh <shorebird-flutter commit>
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/env.sh"
REV="${1:?usage: bootstrap.sh <shorebird-flutter commit>}"
log(){ echo "[$(date '+%F %T')] $*"; }
[[ "$REV" =~ ^[0-9a-f]{40}$ ]] || { echo "bootstrap.sh: give the full 40-character commit, not '$REV'" >&2; exit 2; }
# Both are needed hours into the build, so check before the sync.
missing=0
# The engine's x64 host tools run under Rosetta (see build_shard.py).
arch -x86_64 /usr/bin/true 2>/dev/null || { log "MISSING Rosetta: softwareupdate --install-rosetta --agree-to-license"; missing=1; }
# The macOS framework compiles Metal shaders.
xcrun metal --version >/dev/null 2>&1 || { log "MISSING Metal toolchain: xcodebuild -downloadComponent MetalToolchain"; missing=1; }
command -v rustup >/dev/null || { log "MISSING rustup: brew install rustup"; missing=1; }
[[ $missing == 0 ]] || exit 1
cd "$W"
if [[ ! -d depot_tools/.git ]]; then
  log "clone depot_tools"
  rm -rf depot_tools
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
fi
(cd depot_tools && DEPOT_TOOLS_UPDATE=1 ./ensure_bootstrap)
log "depot_tools: $(git -C depot_tools rev-parse HEAD)"
log "rust 1.99.1"
rustup toolchain install 1.99.1 --profile minimal
rustup default 1.99.1
rustup target add --toolchain 1.99.1 aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
if [[ ! -d flutter/.git ]]; then
  log "clone shorebird-flutter"
  git clone --filter=blob:none --no-checkout https://github.com/mml555/shorebird-flutter.git flutter
fi
cd flutter
git fetch origin "$REV" "+refs/heads/shorebird/dev:refs/remotes/origin/shorebird/dev"
# Only build commits on the branch, so DEPS hooks never run from an unreviewed commit.
git merge-base --is-ancestor "$REV" origin/shorebird/dev \
  || { echo "bootstrap.sh: $REV is not on shorebird/dev" >&2; exit 2; }
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
# strip_x1.py). Point the engine at copies without it (the gclient hook above just
# re-created the links to Xcode's SDKs).
X="$(xcode-select -p)/Platforms"
P=engine/src/flutter/prebuilts/SDKs
for sdk in "$P"/MacOSX*.sdk "$P"/iPhoneOS*.sdk "$P"/iPhoneSimulator*.sdk; do
  name="$(basename "$sdk")"
  plat="${name%%[0-9]*}"
  "$HERE/strip_x1.py" "$X/$plat.platform/Developer/SDKs/$name" "$W/sdks/$name"
  ln -sfn "$W/sdks/$name" "$sdk"
done
log "bootstrap done"
