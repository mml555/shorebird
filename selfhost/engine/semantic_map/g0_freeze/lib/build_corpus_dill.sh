#!/usr/bin/env bash
# Build a release dill from a corpus variant, using the FROZEN toolchain.
#   build_corpus_dill.sh <corpus-dir> <out.dill>
set -uo pipefail
SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
[[ -x "$OUT/dart-sdk/bin/dart" ]] || { echo "no frozen toolchain at $OUT" >&2; exit 2; }
# A STABLE PATH, NOT A FRESH TEMP DIR. The package_config rootUri is a file://
# URI and is baked into the dill, so building each variant under a different
# mktemp path makes every dill unique and the determinism control fails for a
# reason that has nothing to do with the compiler. Same path every call.
W=${CORPUS_BUILD_DIR:-${TMPDIR:-/tmp}/sm1_corpus_build}
rm -rf "$W"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/lib" "$W/.dart_tool"
cp "$1"/*.dart "$W/lib/"
printf '{"configVersion":2,"packages":[{"name":"corpus","rootUri":"file://%s/","packageUri":"lib/","languageVersion":"3.9"}]}' "$W" > "$W/.dart_tool/package_config.json"
rm -f "$2"
"$OUT/dart-sdk/bin/dart" "$SRC/flutter/third_party/dart/pkg/vm/bin/gen_kernel.dart" \
  --platform "$OUT/vm_platform.dill" --aot \
  --packages "$W/.dart_tool/package_config.json" -o "$2" package:corpus/app.dart
