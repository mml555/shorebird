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
# host_release_arm64, not host_release: tools/gn defaults --mac-cpu to x64 even on
# Apple silicon, and we pass --mac-cpu arm64 (the x86_64-apple-darwin Rust std is
# not installed, and native is faster). arm64 suffixes the output dir.
OUT="${OUT:-$SRC/out/host_release_arm64}"
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
AOT_RUNTIME="$OUT/dartaotruntime"
DART="$OUT/dart-sdk/bin/dart"
for f in "$GEN_SNAPSHOT" "$AOT_RUNTIME"; do
  [ -x "$f" ] || die "missing or not executable: $f"
done

cd "$WORK"

# target.dart imports dart:_internal, which user code may not do. The CFE's rule
# (pkg/kernel/lib/target/targets.dart:399) allows it for a `package:` importer
# whose path starts with `dart_internal/` or `dynamic_modules/` -- an allowance
# upstream added for this very feature. So the target lives in a package called
# `dynamic_modules` rather than requiring further SDK edits.
mkdir -p lib .dart_tool
cp "$HERE/target.dart" lib/target.dart
cp "$HERE/replacement.dart" replacement.dart
# Absolute rootUri: a relative "../" is resolved against the config file's own
# location by some tools and the CWD by others, and getting it wrong yields a
# confusing "package:... file not found".
cat > .dart_tool/package_config.json <<JSON
{
  "configVersion": 2,
  "packages": [
    {
      "name": "dynamic_modules",
      "rootUri": "file://$WORK/",
      "packageUri": "lib/",
      "languageVersion": "3.9"
    }
  ]
}
JSON

TARGET_URI="package:dynamic_modules/target.dart"

# --- 1. the target program -> kernel + AOT snapshot ---------------------------
# Built FIRST because the replacement is compiled against this program's kernel.
# gen_kernel, not `dart compile kernel`: the latter takes a FILE PATH and rejects
# a package: URI ("file not found"), but the library URI recorded in the snapshot
# is whatever we compile — and it must be the package: URI, because that is what
# the native looks up at runtime.
note "AOT-compiling $TARGET_URI"
"$DART" "$SRC/flutter/third_party/dart/pkg/vm/bin/gen_kernel.dart" \
  --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json \
  -o target.dill "$TARGET_URI"
# GEN_SNAPSHOT_FLAGS lets the caller change how call sites are emitted, which is
# the whole question for the binder. In particular:
#
#   GEN_SNAPSHOT_FLAGS=--force_indirect_calls
#
# suppresses PC-relative calls (flow_graph_compiler.cc:62), so every static call
# goes through an object pool entry instead of a `bl` immediate baked into the
# instruction stream. Pool entries are DATA, so they can be rewritten at runtime
# on iOS, where code pages cannot be.
"$GEN_SNAPSHOT" ${GEN_SNAPSHOT_FLAGS:-} \
  --snapshot_kind=app-aot-elf --elf=target.aot target.dill

# --- 2. the replacement body -> bytecode --------------------------------------
# dart2bytecode's real interface (lib/dart2bytecode.dart:143) is
#   dart2bytecode --platform vm_platform.dill [--import-dill host_app.dill] input.dart
# so it takes SOURCE, not a prebuilt .dill. Feeding it a .dill makes it try to
# tokenize the binary as Dart and die reporting the error.
#
# --import-dill is upstream's channel for compiling a module against the host
# program's kernel, so the module's references resolve against the host rather
# than duplicating its declarations. That is exactly what patch bytecode needs,
# which makes it worth using here even though this replacement is self-contained.
note "compiling replacement.dart to bytecode (against the host's kernel)"
"$DART" "$SRC/flutter/third_party/dart/pkg/dart2bytecode/bin/dart2bytecode.dart" \
  --platform "$OUT/vm_platform.dill" \
  -o replacement.bytecode replacement.dart

# --- 3. run the gate ----------------------------------------------------------
# The library URI must match what the snapshot recorded, which is the path given
# to the kernel compiler.
LIB_URI="$TARGET_URI"
note "running gate (libraryUri=$LIB_URI)"
echo "--------------------------------------------------"
"$AOT_RUNTIME" target.aot replacement.bytecode "$LIB_URI" || true
echo "--------------------------------------------------"
note "workdir kept for inspection: $WORK"
