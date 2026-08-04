#!/usr/bin/env bash
# Run the iOS code-push kill gate. See README.md for what this proves.
#
# Prerequisite: an engine host_release built with BOTH
#   --dart-dynamic-modules      (interpreter + InterpretCall stub + AttachBytecode)
#   --no-prebuilt-dart-sdk      (mandatory for us: their prebuilt macOS Dart SDK
#                                lives in a private bucket that 401s)
# and the three source additions applied (see README.md "Files").
set -euo pipefail

SRC="${SRC:-/Volumes/build/ios-engine/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
WORK="${WORK:-$(mktemp -d)}"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

[ -d "$OUT" ] || die "no build at $OUT"

# Verify the flag actually made it in. Without this the gate can "fail" for a
# build-config reason and waste a debugging session.
if ! grep -q 'dart_dynamic_modules = true' "$OUT/args.gn" 2>/dev/null; then
  die "dart_dynamic_modules is not true in $OUT/args.gn — rebuild before running the gate"
fi
note "dart_dynamic_modules confirmed in args.gn"

GEN_SNAPSHOT="$OUT/gen_snapshot"
AOT_RUNTIME="$OUT/dart_precompiled_runtime"
DART="$OUT/dart-sdk/bin/dart"
for f in "$GEN_SNAPSHOT" "$AOT_RUNTIME"; do
  [ -x "$f" ] || die "missing or not executable: $f"
done

cp "$HERE/target.dart" "$HERE/replacement.dart" "$WORK/"
cd "$WORK"

# --- 1. the replacement body -> bytecode --------------------------------------
note "compiling replacement.dart to bytecode"
# dart2bytecode ships in-tree at pkg/dart2bytecode. It needs a kernel (.dill)
# first, so this is two steps, not one.
"$DART" compile kernel -o replacement.dill replacement.dart >/dev/null
"$DART" "$SRC/flutter/third_party/dart/pkg/dart2bytecode/bin/dart2bytecode.dart" \
  --platform "$OUT/vm_platform_strong.dill" \
  -o replacement.bytecode replacement.dill

# --- 2. the target program -> AOT snapshot ------------------------------------
note "AOT-compiling target.dart"
"$DART" compile kernel -o target.dill target.dart >/dev/null
"$GEN_SNAPSHOT" --snapshot_kind=app-aot-elf --elf=target.aot target.dill

# --- 3. run the gate ----------------------------------------------------------
# The library URI must match what the snapshot recorded, which is the path given
# to the kernel compiler.
LIB_URI="file://$WORK/target.dart"
note "running gate (libraryUri=$LIB_URI)"
echo "--------------------------------------------------"
"$AOT_RUNTIME" target.aot replacement.bytecode "$LIB_URI" || true
echo "--------------------------------------------------"
note "workdir kept for inspection: $WORK"
