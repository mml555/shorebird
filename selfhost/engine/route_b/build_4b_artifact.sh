#!/usr/bin/env bash
# cspell:words SBRBPTCH dynmod dwarfdump killgate
#
# build_4b_artifact.sh -- Route B 4b milestone 1, producer half.
#
# Turns the already-proven replacement body into a real patch artifact:
#
#   replacement Dart -> bytecode -> SBRBPTCH container -> bidiff+zstd artifact
#
# and stops there. Publishing is publish_4b_patch.sh; the split is deliberate so
# a bad container cannot be discovered halfway through a control-plane write.
#
# THIS IS NOT `shorebird patch`. The producer is deliberately out of scope for
# milestone 1: the point is to prove that REAL updater bytes reach the pre-main
# hook, with the payload production held constant at something already known to
# work. Wiring ios_patcher.dart to emit these bytes is the step after.
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=$SRC/out/host_release_arm64
DART_TREE=$SRC/flutter/third_party/dart
DART=$OUT/dart-sdk/bin/dart
APP=${APP:-/Users/mendell/shorebird/selfhost/fixtures/airgap_app}
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ARTIFACT_TOOL=$SRC/flutter/third_party/updater/target/release/route_b_artifact

# The platform dill the RELEASE was built against, not one from the build tree.
# Bytecode compiled against a different platform does not bind at load time, and
# the failure surfaces on device rather than here.
PLATFORM=${PLATFORM:-/Volumes/build/route-b/published_sdk/flutter_patched_sdk_product/platform_strong.dill}

# The archive whose App binary carries the release identity. Must be the SAME
# build that was published -- a rebuilt archive gets a new UUID and the patch is
# then correctly refused as wrong-release.
XCARCHIVE=${XCARCHIVE:-$APP/build/ios/archive/Runner.xcarchive}
APP_BIN="$XCARCHIVE/Products/Applications/Runner.app/Frameworks/App.framework/App"

OUTDIR=${OUTDIR:-$APP/build/route_b}
mkdir -p "$OUTDIR"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -x "$DART" ] || die "no dart at $DART"
[ -f "$PLATFORM" ] || die "no platform dill at $PLATFORM"
[ -f "$APP_BIN" ] || die "no App binary at $APP_BIN — build the release first"
[ -x "$ARTIFACT_TOOL" ] || die "no route_b_artifact; build it with:
  cd $SRC/flutter/third_party/updater && cargo build --release --bin route_b_artifact"

# RELEASE IDENTITY.
#
# OS::GetAppBuildId prefers the instructions image's own build ID, and for a
# snapshot compiled to Mach-O that IS the Mach-O LC_UUID
# (Image::build_id() -> uuid_command->uuid). The Mach-O fallback path in
# os_macos.cc reaches the same bytes. So the release identity is the App
# dylib's UUID, lowercase hex, no dashes.
#
# Codesigning does not change LC_UUID -- the linker sets it -- which is why this
# survives Xcode re-signing the embedded framework, unlike the engine hash.
BUILD_ID=$(dwarfdump --uuid "$APP_BIN" 2>/dev/null \
  | sed -nE 's/^UUID: ([0-9A-Fa-f-]+).*/\1/p' | head -1 | tr -d '-' \
  | tr '[:upper:]' '[:lower:]')
[ -n "$BUILD_ID" ] || die "could not read LC_UUID from $APP_BIN"
echo "release build id : $BUILD_ID"
echo "  from           : $APP_BIN"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

echo "== app pre-AOT kernel (for --import-dill) =="
# dart2bytecode crashes the CFE on an AOT kernel; it needs the app's own pre-AOT
# kernel, which is the dynmod recipe Spike B established.
cd "$APP"
"$DART" "$DART_TREE/pkg/vm/bin/gen_kernel.dart" \
  --platform "$PLATFORM" --target flutter --no-aot --no-link-platform \
  --packages .dart_tool/package_config.json \
  -o "$W/app_import.dill" package:airgap_probe/main.dart

echo "== replacement body =="
cat > "$W/repl.dart" <<'DART'
@pragma('dyn-module:entry-point')
String routeBValue() => 'NEW';
DART

echo "== compile to bytecode =="
"$DART" "$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart" \
  --platform "$PLATFORM" --target flutter --import-dill "$W/app_import.dill" \
  -o "$W/routeb.bytecode" "$W/repl.dart"

echo "== pack container =="
"$DART" "$HERE/packaging/pack_patch.dart" \
  --release-build-id "$BUILD_ID" \
  --target "package:airgap_probe/main.dart#routeBValue=$W/routeb.bytecode" \
  --out "$OUTDIR/patch.sbrbptch"

echo "== produce artifact =="
# Verifies base-independence on every run; see the tool's header.
"$ARTIFACT_TOOL" "$OUTDIR/patch.sbrbptch" "$OUTDIR/patch.artifact"

# Provenance travels with the bytes. A stale container is now a clean
# wrong-release refusal rather than a mystery, but only if you can tell WHICH
# release it was built for without re-deriving it.
cat > "$OUTDIR/PROVENANCE.txt" <<EOF
Route B 4b milestone 1 artifact
built            : $(date -u +%FT%TZ)
release build id : $BUILD_ID
app binary       : $APP_BIN
platform dill    : $PLATFORM ($(shasum -a 256 "$PLATFORM" | cut -c1-16))
container sha256 : $(shasum -a 256 "$OUTDIR/patch.sbrbptch" | cut -d' ' -f1)
target           : package:airgap_probe/main.dart#routeBValue -> 'NEW'
EOF

echo
echo "wrote:"
ls -la "$OUTDIR"
echo
echo "NEXT: selfhost/engine/route_b/publish_4b_patch.sh"
