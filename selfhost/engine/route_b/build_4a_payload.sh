#!/usr/bin/env bash
# Build the 4a bytecode payload: a replacement body for routeBValue.
#
# Compiled against the APP's own pre-AOT kernel via --import-dill, which is the
# dynmod recipe Spike B established: feeding dart2bytecode an AOT kernel crashes
# the CFE.
set -uo pipefail
SRC=/Volumes/build/route-b/flutter/engine/src
OUT=$SRC/out/host_release_arm64
DART_TREE=$SRC/flutter/third_party/dart
APP=/Users/mendell/shorebird/selfhost/fixtures/airgap_app
DART=$OUT/dart-sdk/bin/dart
# The platform dill the RELEASE was built against, from the CLI cache -- not
# one from the build tree. Bytecode compiled against a different platform will
# not bind at load time, and the failure surfaces on device rather than here.
PLATFORM=/Volumes/build/route-b/published_sdk/flutter_patched_sdk_product/platform_strong.dill
W=$(mktemp -d)

set -e
echo "== app pre-AOT kernel (for --import-dill) =="
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
  -o "$APP/assets/routeb_patch.bytecode" "$W/repl.dart"

ls -la "$APP/assets/routeb_patch.bytecode"
