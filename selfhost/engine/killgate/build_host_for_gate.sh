#!/usr/bin/env bash
# Build the engine with our patches AND dart_dynamic_modules=true.
#
# Sequencing is deliberate: HOST (macOS) release first, not iOS. A macOS release
# build is also a precompiled runtime, so it exercises the same
# DART_PRECOMPILED_RUNTIME + DART_DYNAMIC_MODULES combination the kill gate needs
# -- but with no signing, no device, and a much faster edit/build/run loop. iOS
# comes after the mechanism is proven here.
#
# --no-prebuilt-dart-sdk is REQUIRED for us: DEPS' prebuilt Dart SDK for macOS
# lives in a private Shorebird bucket that 401s, so we compile Dart from source
# (what the Linux build already does).
set -u

ROOT=/Volumes/build/ios-engine
SRC=$ROOT/flutter/engine/src
S=/private/tmp/claude-501/-Users-mendell-shorebird/b5a4ac4a-d4f8-4b9c-852f-f1db977cd8cc/scratchpad
LOG=$S/ios_build.log
export PATH="$ROOT/depot_tools:$PATH"
export GIT_CONFIG_GLOBAL="$ROOT/gitconfig"
export DEPOT_TOOLS_UPDATE=0

say() { echo "=== $(date '+%F %H:%M:%S') $*" >> "$LOG"; }

# --- wait for the dependency sync, so this can be launched immediately ---------
say "waiting for gclient sync to finish"
while ! grep -q 'SYNC COMPLETE' "$S/ios_sync.log" 2>/dev/null; do
  if grep -q 'SYNC FAILED' "$S/ios_sync.log" 2>/dev/null; then
    say "ABORT: sync failed"; exit 1
  fi
  sleep 30
done
say "sync is complete"

# --- apply our engine patches (idempotent) ------------------------------------
cd "$ROOT/flutter" || { say "ABORT: checkout missing"; exit 1; }

# -p3, not -p2. Patch paths are a/vendor/flutter/engine/src/flutter/... , so
# stripping three components ("a/vendor/flutter/") yields engine/src/flutter/... ,
# which is what this checkout uses.
#
# The earlier -p2 was a SILENT no-op and worth guarding against: it left paths as
# flutter/engine/... , which matched no --include filter, so every file was
# excluded, the patch became empty, and `git apply` exited 0 with nothing done --
# reporting success while changing nothing. Hence the sentinel check below:
# trust file contents, never the exit code.
for p in p1_asset_resolver p2_assets_only; do
  if git apply --check -p3 "$S/$p.patch" 2>/dev/null; then
    git apply -p3 "$S/$p.patch" && say "applied $p"
  elif git apply --check -p3 -R "$S/$p.patch" 2>/dev/null; then
    say "$p already applied"
  else
    say "WARNING: $p did not apply cleanly"
  fi
done

# Verify by content. Each sentinel is a string only our patches introduce.
for probe in \
  "shorebird_patch_assets_path:engine/src/flutter/common/settings.h" \
  "shorebird_patch_assets_path:engine/src/flutter/shell/common/run_configuration.cc" \
  "PatchCarriesCode:engine/src/flutter/shell/common/shorebird/shorebird.cc" ; do
  sentinel="${probe%%:*}"; file="${probe#*:}"
  if grep -q "$sentinel" "$file" 2>/dev/null; then
    say "  verified: $sentinel present in $(basename "$file")"
  else
    say "  MISSING: $sentinel absent from $file — our engine changes are NOT in this build"
  fi
done
say "engine diff now: $(git diff --stat | tail -1)"

# --- configure ----------------------------------------------------------------
cd "$SRC" || { say "ABORT: engine/src missing"; exit 1; }
# --mac-cpu arm64 is required, not a preference. tools/gn defaults --mac-cpu to
# x64 even on Apple silicon (tools/gn:971), which made the Rust updater build for
# x86_64-apple-darwin and fail with "can't find crate for `core`" -- that target's
# std is not installed, while aarch64-apple-darwin is. Building native also avoids
# Rosetta and is faster.
#
# Consequence: arm64 changes the output directory (tools/gn:41) to
# out/host_release_arm64, so OUT_DIR must follow it everywhere below.
OUT_DIR=out/host_release_arm64
say "running gn (host release arm64, dynamic modules ON, Dart from source)"
./flutter/tools/gn --runtime-mode=release --mac-cpu arm64 \
  --no-prebuilt-dart-sdk --dart-dynamic-modules \
  >> "$LOG" 2>&1
rc=$?
say "gn exit $rc"
[ "$rc" -eq 0 ] || { say "ABORT: gn failed"; exit 1; }
say "out dir: $OUT_DIR ($([ -d "$OUT_DIR" ] && echo exists || echo MISSING))"

# Confirm the flag actually reached args.gn — the whole point of this build.
say "args.gn dynamic-modules line: $(grep -i dynamic_modules "$OUT_DIR/args.gn" 2>/dev/null || echo MISSING)"
say "args.gn target_cpu: $(grep -E '^target_cpu' "$OUT_DIR/args.gn" 2>/dev/null || echo MISSING)"

# --- build --------------------------------------------------------------------
# Build ONLY what the kill gate needs, not the default all-targets.
#
# Two reasons. The default pulls in ANGLE, whose Metal shader compilation fails
# on Xcode 26 without a separately-downloaded Metal Toolchain
# ("cannot execute tool 'metal'") -- a dependency the gate has no use for. And
# the full graph is 11,462 targets against roughly 1,500 for these, so this is
# also much faster.
#
# Target names checked against `ninja -t targets all`: the AOT runtime is
# `dartaotruntime` (not dart_precompiled_runtime) and the platform dill is
# `vm_platform.dill` (not vm_platform_strong.dill) in this Dart version.
GATE_TARGETS="gen_snapshot dartaotruntime dart dart_sdk vm_platform.dill"
say "ninja starting for: $GATE_TARGETS"
# shellcheck disable=SC2086
nice -n 5 ninja -C "$OUT_DIR" -j 8 $GATE_TARGETS >> "$LOG" 2>&1
rc=$?
say "ninja exit $rc"

if [ "$rc" -eq 0 ]; then
  say "HOST BUILD COMPLETE"
  for f in gen_snapshot dartaotruntime dart; do
    say "  $f: $([ -x "$OUT_DIR/$f" ] && echo "$(wc -c < "$OUT_DIR/$f" | tr -d ' ') bytes" || echo MISSING)"
  done
else
  say "HOST BUILD FAILED — last errors:"
  grep -iE 'error:|FAILED:' "$LOG" | grep -v '^\[' | tail -12 >> "$LOG"
fi
