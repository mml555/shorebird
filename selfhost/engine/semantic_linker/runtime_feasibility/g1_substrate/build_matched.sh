#!/usr/bin/env bash
# cspell:words dartaotruntime depot gclient prebuilt caffeinate dill nodm semantic linker
# build_matched.sh -- SEMANTIC-LINKER-1 / G1 step 2. Build the Dynamic Modules
# OFF (control) and ON (experiment) host toolchains from ONE staged source, so
# they differ in exactly one GN setting and nothing else.
#
# THE MATCHING IS BY CONSTRUCTION, NOT BY INSPECTION. `flutter/tools/gn` runs
# once and its args.gn becomes the template. dm_on is that file verbatim; dm_off
# is that file with the single `dart_dynamic_modules` line removed. The two are
# diffed and the diff must be exactly one line, or the build refuses to start --
# a control that differs in two settings measures neither of them, which is the
# defect the existing out/host_release_arm64_nodm carries.
#
# `flutter/tools/gn` is used ONCE and then never again, because it derives the
# out dir name and would clobber it. Each configuration is generated with the
# engine's own gn binary against a hand-placed args.gn, the same way
# route_b/build_host_nodm_debug.sh does it.
#
# Run under screen, never as a harness background task -- harness cleanup has
# killed long builds in this tree before:
#   screen -dmS sl1build bash -c 'caffeinate -is .../build_matched.sh'
set -u
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

LANE=${LANE:-/Volumes/build/semantic-linker/sl1}
SRC="$LANE/flutter/engine/src"
TOOLS=${TOOLS:-/Volumes/build/ios-engine}
LOGDIR=${LOGDIR:-$LANE/logs}
LOG="$LOGDIR/build_matched_$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOGDIR"
export PATH="$TOOLS/depot_tools:$PATH"
export GIT_CONFIG_GLOBAL="$TOOLS/gitconfig"
export DEPOT_TOOLS_UPDATE=0

TEMPLATE_OUT=out/host_release_arm64      # what tools/gn insists on naming
ON=out/sl1_dm_on
OFF=out/sl1_dm_off
# Exactly what route_b/build_host.sh builds, so the substrate is comparable to
# the supported host rather than to a reduced graph of our own invention.
TARGETS="gen_snapshot dartaotruntime dart dart_sdk vm_platform.dill"

RC=0
say()  { echo "=== $(date '+%F %H:%M:%S') $*" | tee -a "$LOG"; }
step() { local label=$1; shift; say "BEGIN $label"; "$@" >>"$LOG" 2>&1; local rc=$?
         say "END   $label exit=$rc"; [ "$rc" -eq 0 ] || RC=$((RC+1)); return $rc; }

cd "$SRC" || { echo "ABORT: $SRC missing" >&2; exit 2; }
say "lane source: $SRC"
say "engine HEAD: $(git -C "$SRC/flutter" rev-parse HEAD)"
say "dart   HEAD: $(git -C "$SRC/flutter/third_party/dart" rev-parse HEAD)"
say "dart dirty : $(git -C "$SRC/flutter/third_party/dart" status --porcelain | tr '\n' ' ')"

# ---- 1. the template config -------------------------------------------------
# --mac-cpu arm64: tools/gn defaults to x64 even on Apple silicon and then builds
# the Rust updater for x86_64-apple-darwin, failing on a missing core crate.
# --no-prebuilt-dart-sdk: DEPS' prebuilt macOS Dart SDK is in a private bucket
# that 401s for us, and we want Dart from THIS source anyway.
step "gn template (release/arm64/dm ON)" \
  ./flutter/tools/gn --runtime-mode=release --mac-cpu arm64 \
    --no-prebuilt-dart-sdk --dart-dynamic-modules
[ -f "$TEMPLATE_OUT/args.gn" ] || { say "ABORT: tools/gn produced no args.gn"; exit 1; }

# ---- 2. derive the matched pair ---------------------------------------------
rm -rf "$ON" "$OFF"; mkdir -p "$ON" "$OFF"
cp "$TEMPLATE_OUT/args.gn" "$ON/args.gn"
grep -v '^dart_dynamic_modules' "$TEMPLATE_OUT/args.gn" > "$OFF/args.gn"

# THE REFUSAL. One line, and it must be the intended one.
DIFF=$(diff "$OFF/args.gn" "$ON/args.gn")
NLINES=$(grep -c '^>' <<<"$DIFF"); NREMOVED=$(grep -c '^<' <<<"$DIFF")
say "args.gn delta: +$NLINES -$NREMOVED"
printf '%s\n' "$DIFF" | sed 's/^/    /' | tee -a "$LOG" >/dev/null
if [ "$NLINES" -ne 1 ] || [ "$NREMOVED" -ne 0 ] || ! grep -q '^> dart_dynamic_modules = true' <<<"$DIFF"; then
  say "ABORT: OFF and ON differ by something other than the single dynamic-modules line"
  exit 1
fi
say "OK: the pair differs in exactly dart_dynamic_modules"
say "dart_version stamped by gn: $(sed -n 's/^dart_version = //p' "$ON/args.gn" | tr -d '\"')"

GN="$SRC/flutter/third_party/gn/gn"
step "gn gen $OFF" "$GN" gen "$OFF"
step "gn gen $ON"  "$GN" gen "$ON"

# ---- 3. build both ----------------------------------------------------------
# shellcheck disable=SC2086
step "ninja OFF (control)"    nice -n 5 ninja -C "$OFF" -j 8 $TARGETS
# shellcheck disable=SC2086
step "ninja ON  (experiment)" nice -n 5 ninja -C "$ON"  -j 8 $TARGETS

# ---- 4. record what was produced --------------------------------------------
for d in "$OFF" "$ON"; do
  say "--- $d ---"
  for f in gen_snapshot dartaotruntime dart vm_platform.dill dart-sdk/bin/dart; do
    if [ -e "$d/$f" ]; then
      say "  $(shasum -a 256 "$d/$f" | cut -d' ' -f1)  $(wc -c < "$d/$f" | tr -d ' ')  $f"
    else
      say "  MISSING  $f"; RC=$((RC+1))
    fi
  done
  say "  dm flag in args.gn: $(grep -c '^dart_dynamic_modules' "$d/args.gn")"
done

if [ "$RC" -eq 0 ]; then say "RESULT: OK"; else say "RESULT: $RC FAILED STEP(S)"; fi
say "log: $LOG"
exit "$RC"
