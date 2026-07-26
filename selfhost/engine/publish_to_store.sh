#!/usr/bin/env bash
#
# publish_to_store.sh — publish a locally-built Shorebird engine to OUR object
# store, mirroring the exact key layout that Shorebird's vendored *_upload.sh
# scripts push to gs://download.shorebird.dev. The CLI (pointed at our store via
# FLUTTER_STORAGE_BASE_URL / SHOREBIRD_STORAGE_BASE_URL) then consumes our engine.
#
# This is a faithful retarget of vendor/flutter/shorebird/ci/internal/mac_upload.sh
# (the macOS-host artifact set: iOS + macOS + Android-from-mac). On a Linux/Windows
# farm, add that host's artifacts per its *_upload.sh (aot-tools, gtk, windows-x64).
# Every `put` is existence-guarded, so it publishes exactly what was built.
#
# Usage:
#   S3_ENDPOINT=https://minio.yourco.com S3_BUCKET=engine-artifacts \
#   S3_ACCESS_KEY=… S3_SECRET_KEY=… \
#   selfhost/engine/publish_to_store.sh <engineHash>
#
# Requires: mc (MinIO client) on PATH.
set -euo pipefail

[[ "$#" -eq 1 ]] || { echo "usage: $0 <engineHash>" >&2; exit 2; }
ENGINE_HASH="$1"

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
FLUTTER_ROOT="$REPO_ROOT/vendor/flutter"
ENGINE_OUT="$FLUTTER_ROOT/engine/src/out"
GEN_MANIFEST="$FLUTTER_ROOT/shorebird/ci/internal/generate_manifest.sh"

: "${S3_ENDPOINT:?set S3_ENDPOINT}"
: "${S3_BUCKET:?set S3_BUCKET}"
: "${S3_ACCESS_KEY:?set S3_ACCESS_KEY}"
: "${S3_SECRET_KEY:?set S3_SECRET_KEY}"
STORAGE_HOST="${STORAGE_HOST:-$S3_BUCKET}"   # written into the manifest's storage_bucket

command -v mc >/dev/null 2>&1 || { echo "ERROR: mc (MinIO client) not on PATH" >&2; exit 1; }

mc alias set _eng "$S3_ENDPOINT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY" >/dev/null
DEST="_eng/$S3_BUCKET"
INFRA="flutter_infra_release/flutter/$ENGINE_HASH"    # dart-sdk, gen_snapshot, frameworks
SB="shorebird/$ENGINE_HASH"                            # patch tools + manifest

put() {  # put <localfile> <destkey>
  if [[ -f "$1" ]]; then echo "  + $2"; mc cp -q "$1" "$DEST/$2" >/dev/null
  else echo "  - skip (not built): $1" >&2; fi
}
zipdir() { ( cd "$1" && zip -qr "$2" "$3" ); }   # zip <dir> <out.zip> <subdir>

echo "==> Publishing engine $ENGINE_HASH to $S3_ENDPOINT/$S3_BUCKET"

# --- Dart SDK (host_release = x64, host_release_arm64 = arm64) ---------------
if [[ -d "$ENGINE_OUT/host_release/dart-sdk" ]]; then
  zipdir "$ENGINE_OUT/host_release" dart-sdk-darwin-x64.zip dart-sdk
  put "$ENGINE_OUT/host_release/dart-sdk-darwin-x64.zip" "$INFRA/dart-sdk-darwin-x64.zip"
fi
if [[ -d "$ENGINE_OUT/host_release_arm64/dart-sdk" ]]; then
  zipdir "$ENGINE_OUT/host_release_arm64" dart-sdk-darwin-arm64.zip dart-sdk
  put "$ENGINE_OUT/host_release_arm64/dart-sdk-darwin-arm64.zip" "$INFRA/dart-sdk-darwin-arm64.zip"
fi

# --- engine_stamp.json -------------------------------------------------------
put "$ENGINE_OUT/engine_stamp.json" "$INFRA/engine_stamp.json"

# --- Android gen_snapshot (built on mac host -> darwin-x64.zip) --------------
put "$ENGINE_OUT/android_release_arm64/zip_archives/android-arm64-release/darwin-x64.zip" "$INFRA/android-arm64-release/darwin-x64.zip"
put "$ENGINE_OUT/android_release/zip_archives/android-arm-release/darwin-x64.zip"         "$INFRA/android-arm-release/darwin-x64.zip"
put "$ENGINE_OUT/android_release_x64/zip_archives/android-x64-release/darwin-x64.zip"     "$INFRA/android-x64-release/darwin-x64.zip"

# --- iOS ---------------------------------------------------------------------
put "$ENGINE_OUT/release/artifacts.zip"                "$INFRA/ios-release/artifacts.zip"
put "$ENGINE_OUT/release/Flutter.framework.dSYM.zip"   "$INFRA/ios-release/Flutter.framework.dSYM.zip"

# --- macOS -------------------------------------------------------------------
put "$ENGINE_OUT/release/framework/framework.zip"      "$INFRA/darwin-x64-release/framework.zip"
put "$ENGINE_OUT/release/snapshot/gen_snapshot.zip"    "$INFRA/darwin-x64-release/gen_snapshot.zip"
# arm64 mac artifacts intentionally land under darwin-x64-release (arm macs use it).
put "$ENGINE_OUT/mac_release_arm64/zip_archives/darwin-arm64-release/artifacts.zip" "$INFRA/darwin-x64-release/artifacts.zip"
put "$ENGINE_OUT/release/framework/FlutterMacOS.framework.dSYM.zip" "$INFRA/darwin-x64/FlutterMacOS.framework.dSYM.zip"

# --- Linux-host additions (only present when built on Linux; see linux_build/upload.sh)
put "$ENGINE_OUT/host_release/flutter_patched_sdk_product.zip" "$INFRA/flutter_patched_sdk_product.zip"

# --- Patch tools (the standalone CLI, per-platform) --------------------------
# Shorebird's mac_upload.sh fetches released patch binaries from the updater
# GitHub release and uploads them to shorebird/<hash>/patch-<plat>.zip. Mirror
# that, or substitute your own build of vendor/updater's `patch` crate.
PATCH_VERSION="${PATCH_VERSION:-0.3.0}"
GH="https://github.com/shorebirdtech/updater/releases/download/patch-v${PATCH_VERSION}"
TMP="$(mktemp -d)"
declare -A PATCH_MAP=(
  [patch-x86_64-apple-darwin.zip]=patch-darwin-x64.zip
  [patch-aarch64-apple-darwin.zip]=patch-darwin-arm64.zip
  [patch-x86_64-pc-windows-msvc.zip]=patch-windows-x64.zip
  [patch-x86_64-unknown-linux-musl.zip]=patch-linux-x64.zip
)
for src in "${!PATCH_MAP[@]}"; do
  if curl -fsSL "$GH/$src" -o "$TMP/$src"; then
    put "$TMP/$src" "$SB/${PATCH_MAP[$src]}"
  else
    echo "  - skip patch tool (download failed): $src" >&2
  fi
done

# --- Manifest (rewrite storage_bucket to our store) --------------------------
MAN="$TMP/artifacts_manifest.yaml"
bash "$GEN_MANIFEST" "$ENGINE_HASH" | sed "s#storage_bucket: download.shorebird.dev#storage_bucket: $STORAGE_HOST#" > "$MAN"
put "$MAN" "$SB/artifacts_manifest.yaml"

rm -rf "$TMP"
echo "==> Done. Point the CLI at this store:"
echo "    FLUTTER_STORAGE_BASE_URL=$S3_ENDPOINT   (or your CDN in front of it)"
echo "    SHOREBIRD_STORAGE_BASE_URL=<same>   SHOREBIRD_STORAGE_BUCKET=$S3_BUCKET"
