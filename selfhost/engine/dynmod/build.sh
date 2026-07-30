#!/usr/bin/env bash
# cspell:words dynmod dyntest dartaotruntime AOTRT aot
#
# Phase 4 crux harness: can a dynamic module replace code the AOT snapshot
# already contains? See README.md — the answer is no, and the last stage here
# is EXPECTED to fail with a native-resolution error.
#
# Usage: ./build.sh [workdir] [dart-sdk]
#
# workdir defaults to /private/tmp/dyntest. Do NOT point it at the session
# scratchpad: gen_kernel mishandles paths containing a component that starts
# with `-`, and reports it as a missing file rather than a path bug.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="${1:-/private/tmp/dyntest}"
SDK="${2:-$HERE/../../../bin/cache/flutter/c15ef6379403a0a55531a058bdb2c8e55bc05c98/bin/cache/dart-sdk}"

case "$T" in
  *-*/*|*/-*) echo "refusing: '$T' has a path component starting with '-'; gen_kernel breaks on it" >&2; exit 1 ;;
esac
[[ -x "$SDK/bin/dartaotruntime" ]] || { echo "no dart sdk at $SDK" >&2; exit 1; }

AOTRT="$SDK/bin/dartaotruntime"
GEN_KERNEL="$SDK/bin/snapshots/gen_kernel_aot.dart.snapshot"
DART2BC="$SDK/bin/snapshots/dart2bytecode.dart.snapshot"
PLATFORM="$SDK/lib/_internal/vm_platform_product.dill"

mkdir -p "$T/.dart_tool"
cp "$HERE/host.dart" "$HERE/module.dart" "$HERE/di.yaml" "$T/"
cat > "$T/.dart_tool/package_config.json" <<'JSON'
{"configVersion":2,"packages":[{"name":"dynmod","rootUri":"../","packageUri":"","languageVersion":"3.12"}]}
JSON
say() { echo; echo "== $* =="; }

say "1/5 host kernel, AOT, with the dynamic interface"
"$AOTRT" "$GEN_KERNEL" --platform "$PLATFORM" --aot \
  --packages "$T/.dart_tool/package_config.json" \
  --dynamic-interface "$T/di.yaml" \
  -o "$T/host.dill" "$T/host.dart"

say "2/5 host AOT snapshot"
"$SDK/bin/utils/gen_snapshot" --snapshot_kind=app-aot-elf \
  --elf="$T/host.aot" "$T/host.dill"

say "3/5 baseline run — expect ORIGINAL"
"$AOTRT" "$T/host.aot"

# --import-dill needs the PRE-AOT kernel. Handing it the AOT-transformed dill
# crashes the CFE in DillExtensionBuilder with a null-check error, which reads
# like a compiler bug rather than "wrong input".
say "4/5 plain host kernel for import, then the module's bytecode"
"$AOTRT" "$GEN_KERNEL" --platform "$PLATFORM" --no-aot --no-link-platform \
  --packages "$T/.dart_tool/package_config.json" \
  -o "$T/host_import.dill" "$T/host.dart"
"$AOTRT" "$DART2BC" --platform "$PLATFORM" \
  --import-dill "$T/host_import.dill" \
  --packages "$T/.dart_tool/package_config.json" \
  -o "$T/module.bytecode" "$T/module.dart"

say "5/5 load the module — EXPECTED TO FAIL"
echo "(user code cannot reach Internal_loadDynamicModule; see README.md)"
"$AOTRT" "$T/host.aot" "$T/module.bytecode" || true
