#!/usr/bin/env bash
# cspell:words dartaotruntime killgate dynmod depot gclient caffeinate
#
# build_host.sh — build the Route B host toolchain (macOS arm64, release,
# dart_dynamic_modules=true, Dart from source).
#
# HOST release, not iOS: a macOS release build is also a precompiled runtime,
# so it exercises the same DART_PRECOMPILED_RUNTIME + DART_DYNAMIC_MODULES
# combination Route B needs, with no signing, no device and a ~1-minute
# incremental loop. iOS comes at step 9, not now.
#
# Run me under a detached screen, never as a harness background task —
# harness cleanup has killed long builds here twice:
#   screen -dmS routeb bash -c 'caffeinate -is .../build_host.sh'
set -u

ROOT=${ROOT:-/Volumes/build/route-b}
TOOLS=${TOOLS:-/Volumes/build/ios-engine}   # depot_tools + gitconfig are shared: tools, not state
SRC=$ROOT/flutter/engine/src
LOG=$ROOT/logs/route_b_host_$(date +%Y%m%d-%H%M%S).log
OUT_DIR=out/host_release_arm64

mkdir -p "$(dirname "$LOG")"
export PATH="$TOOLS/depot_tools:$PATH"
export GIT_CONFIG_GLOBAL="$TOOLS/gitconfig"
export DEPOT_TOOLS_UPDATE=0

say() { echo "=== $(date '+%F %H:%M:%S') $*" >> "$LOG"; }

cd "$SRC" || { echo "ABORT: $SRC missing" >&2; exit 1; }

say "started; tree=$ROOT"

# --mac-cpu arm64 is required, not a preference: tools/gn defaults --mac-cpu to
# x64 even on Apple silicon, which builds the Rust updater for
# x86_64-apple-darwin and fails with "can't find crate for `core`".
# It also moves the out dir to out/host_release_arm64, so OUT_DIR follows it.
#
# --no-prebuilt-dart-sdk is required for us: DEPS' prebuilt macOS Dart SDK is in
# a private Shorebird bucket that 401s.
say "gn: release / arm64 / dynamic-modules ON / Dart from source"
./flutter/tools/gn --runtime-mode=release --mac-cpu arm64 \
  --no-prebuilt-dart-sdk --dart-dynamic-modules >> "$LOG" 2>&1
rc=$?
say "gn exit $rc"
[ "$rc" -eq 0 ] || { say "ABORT: gn failed"; exit 1; }

# Confirm the flag actually reached args.gn — the entire point of this tree.
say "args.gn dynamic_modules: $(grep -i dynamic_modules "$OUT_DIR/args.gn" 2>/dev/null || echo MISSING)"
say "args.gn target_cpu:      $(grep -E '^target_cpu' "$OUT_DIR/args.gn" 2>/dev/null || echo MISSING)"

# Build only what Route B needs. The default graph pulls in ANGLE, whose Metal
# shader compilation fails on Xcode 26 without a separate Metal Toolchain, and
# is ~11,000 targets against roughly 1,500 for these.
TARGETS="gen_snapshot dartaotruntime dart dart_sdk vm_platform.dill"
say "ninja: $TARGETS"
# shellcheck disable=SC2086
nice -n 5 ninja -C "$OUT_DIR" -j 8 $TARGETS >> "$LOG" 2>&1
rc=$?
say "ninja exit $rc"

if [ "$rc" -eq 0 ]; then
  say "BUILD COMPLETE"
  for f in gen_snapshot dartaotruntime dart; do
    say "  $f: $([ -x "$OUT_DIR/$f" ] && wc -c < "$OUT_DIR/$f" | tr -d ' ' || echo MISSING) bytes"
  done
  say "attach-bytecode native in dartaotruntime: $(nm -a "$OUT_DIR/dartaotruntime" 2>/dev/null | grep -ci AttachBytecode)"
else
  say "BUILD FAILED — last errors:"
  # Via a temp file, not a pipeline: grepping $LOG while appending to $LOG in
  # the same pipeline can feed the summary back into itself (SC2094).
  errs=$(mktemp)
  grep -iE 'error:|FAILED:' "$LOG" | grep -v '^\[' | tail -15 > "$errs"
  cat "$errs" >> "$LOG"
  rm -f "$errs"
fi
say "log: $LOG"
