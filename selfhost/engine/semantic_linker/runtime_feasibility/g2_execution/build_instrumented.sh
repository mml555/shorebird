#!/usr/bin/env bash
# cspell:words dartaotruntime depot prebuilt dill semantic linker
# build_instrumented.sh -- SEMANTIC-LINKER-1 / G2. Build the same matched pair
# again, this time with the experiment-only execution-mode instrument applied.
#
# INTO NEW OUT DIRS, NEVER OVER G1's. out/sl1_dm_{on,off} are G1's evidence and
# stay byte-stable so that gate remains re-verifiable; ninja would happily
# rebuild them from the now-instrumented source, which would silently retire the
# artifacts G1's manifest hashes.
#
# The pair is derived exactly as G1's was -- one tools/gn template, one line of
# difference -- so the ONLY thing separating these four builds is (dynamic
# modules on/off) x (instrument present/absent).
set -u
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LANE=${LANE:-/Volumes/build/semantic-linker/sl1}
SRC="$LANE/flutter/engine/src"
TOOLS=${TOOLS:-/Volumes/build/ios-engine}
LOG="$LANE/logs/build_g2_$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LANE/logs"
export PATH="$TOOLS/depot_tools:$PATH"
export GIT_CONFIG_GLOBAL="$TOOLS/gitconfig"
export DEPOT_TOOLS_UPDATE=0

TEMPLATE=out/host_release_arm64
ON=out/sl1_g2_on
OFF=out/sl1_g2_off
TARGETS="gen_snapshot dartaotruntime dart dart_sdk vm_platform.dill"
RC=0
say()  { echo "=== $(date '+%F %H:%M:%S') $*" | tee -a "$LOG"; }
step() { local l=$1; shift; say "BEGIN $l"; "$@" >>"$LOG" 2>&1; local r=$?; say "END   $l exit=$r"; [ "$r" -eq 0 ] || RC=$((RC+1)); return $r; }

cd "$SRC" || { echo "ABORT: $SRC missing" >&2; exit 2; }
say "dart dirty: $(git -C "$SRC/flutter/third_party/dart" status --porcelain | tr '\n' ' ')"
# THE INSTRUMENT MUST BE PRESENT, or this builds G1 again under a new name.
grep -q Internal_functionExecutionMode "$SRC/flutter/third_party/dart/runtime/lib/object.cc" \
  || { say "ABORT: the G2 instrument is not applied to the lane tree"; exit 1; }
say "instrument present in runtime/lib/object.cc"

[ -f "$TEMPLATE/args.gn" ] || { say "ABORT: no template args.gn"; exit 1; }
rm -rf "$ON" "$OFF"; mkdir -p "$ON" "$OFF"
cp "$TEMPLATE/args.gn" "$ON/args.gn"
grep -v '^dart_dynamic_modules' "$TEMPLATE/args.gn" > "$OFF/args.gn"
D=$(diff "$OFF/args.gn" "$ON/args.gn")
if [ "$(grep -c '^>' <<<"$D")" -ne 1 ] || [ "$(grep -c '^<' <<<"$D")" -ne 0 ]; then
  say "ABORT: the pair differs by more than the dynamic-modules line"; exit 1
fi
say "OK: the pair differs in exactly dart_dynamic_modules"

GN="$SRC/flutter/third_party/gn/gn"
step "gn gen $OFF" "$GN" gen "$OFF"
step "gn gen $ON"  "$GN" gen "$ON"
# shellcheck disable=SC2086
step "ninja g2 OFF" nice -n 5 ninja -C "$OFF" -j 8 $TARGETS
# shellcheck disable=SC2086
step "ninja g2 ON"  nice -n 5 ninja -C "$ON"  -j 8 $TARGETS

for d in "$OFF" "$ON"; do
  say "--- $d ---"
  for f in gen_snapshot dartaotruntime vm_platform.dill dart-sdk/bin/dart; do
    [ -e "$d/$f" ] && say "  $(shasum -a 256 "$d/$f" | cut -d' ' -f1)  $f" || { say "  MISSING $f"; RC=$((RC+1)); }
  done
done
# G1's artifacts must be exactly as its manifest recorded them.
say "--- G1 artifacts, re-read ---"
for a in sl1_dm_off sl1_dm_on; do
  say "  $a dartaotruntime $(shasum -a 256 "out/$a/dartaotruntime" 2>/dev/null | cut -d' ' -f1)"
done
if [ "$RC" -eq 0 ]; then say "RESULT: OK"; else say "RESULT: $RC FAILED STEP(S)"; fi
exit "$RC"
