#!/usr/bin/env bash
# cspell:words caffeinate interpretcall routebios
#
# run_mint_build.sh -- detached driver for the mint's iOS engine build.
#
# VENDORED 2026-09-10 from /Volumes/build/route-b/run_mint_build.sh, which until
# then was the only copy in existence. It is the sole writer of
# logs/mint_build.status -- the file probes/assert_mint_ready.sh gates the mint
# on -- and it lived on media MEDIA_PRESERVATION.md:5-8 records as having
# physically detached mid-operation twice. Losing the drive lost the gate's
# input. Changes from the SSD original, all of them here:
#   * ROOT/TOOLS take the house ${VAR:-default} form (build_host.sh:17-18), and
#     are EXPORTED so the child builds the tree this then reads the log of;
#   * BUILD_SCRIPT defaults to this directory's build_ios.sh instead of
#     $ROOT/build_ios_release.sh. Those two files are byte-identical apart from
#     one header comment line -- diffed, not assumed;
#   * an executable check on BUILD_SCRIPT before the status file claims
#     state=running;
#   * root= and build_script= recorded in the status, so a reader can tell which
#     tree and which script the verdict is about.
# Full diff: evidence/host/SSD_SCRIPT_VENDORING_2026-09-10.txt.
#
# WHY A WRAPPER AT ALL. build_ios.sh wraps its whole body in
# `{ ... } >>"$LOG" 2>&1`, and the last statement inside that block is an `echo`.
# With `set -uo pipefail` and no `-e`, the script therefore exits 0 WHETHER OR NOT
# ninja succeeded. Reading its exit status would report success for a failed build --
# the worst shape available here, because the mint that follows would then be built
# from a stale or partial out/ios_release.
#
# The authoritative signal is the line the script itself writes immediately after
# ninja, with `$?` read directly and no pipeline in between:
#
#     echo "=== ninja exit=$? finished ... ==="
#
# So this driver records THAT, plus whether the Flutter framework actually exists
# afterwards, into one status file the next step can gate on.
#
# Run detached, NEVER as a harness background task:
#   screen -dmS routebios bash -c 'caffeinate -is selfhost/engine/route_b/run_mint_build.sh'
set -uo pipefail

ROOT=${ROOT:-/Volumes/build/route-b}
TOOLS=${TOOLS:-/Volumes/build/ios-engine}   # depot_tools + gitconfig are shared: tools, not state
BUILD_SCRIPT=${BUILD_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build_ios.sh}
OUT_DIR=$ROOT/flutter/engine/src/out/ios_release
STATUS=$ROOT/logs/mint_build.status

# The child reads the same two knobs. Exporting is what makes ROOT a real
# parameter rather than a default that silently disagrees between the driver and
# the build it drives -- the log this then parses is $ROOT/logs/ios_release_*.log,
# so a child building elsewhere would have its status read from the wrong tree.
export ROOT TOOLS

[ -x "$BUILD_SCRIPT" ] || { echo "ABORT: build script not executable: $BUILD_SCRIPT" >&2; exit 2; }

mkdir -p "$ROOT/logs"
{
  echo "state=running"
  echo "started=$(date -u +%FT%TZ)"
  echo "root=$ROOT"
  echo "build_script=$BUILD_SCRIPT"
} > "$STATUS"

# caffeinate -is: the build outlives idle sleep. Not backgrounded here -- screen
# already detached us, and backgrounding again would orphan the status write.
caffeinate -is "$BUILD_SCRIPT"
driver_rc=$?

log=$(ls -t "$ROOT"/logs/ios_release_*.log 2>/dev/null | head -1)
# Parsing the recorded status, not capturing a live one: the number below was
# produced by `$?` inside the build script with nothing piped.
ninja_rc=$(sed -n 's/.*ninja exit=\([0-9][0-9]*\).*/\1/p' "$log" 2>/dev/null | tail -1)
framework=$(find "$OUT_DIR" -maxdepth 4 -name Flutter -type f 2>/dev/null | head -1)

{
  echo "state=finished"
  echo "root=$ROOT"
  echo "build_script=$BUILD_SCRIPT"
  echo "log=$log"
  echo "driver_rc=$driver_rc"
  echo "ninja_rc=${ninja_rc:-unknown}"
  echo "framework=${framework:-<none>}"
  if [ -n "$framework" ]; then
    echo "framework_bytes=$(wc -c < "$framework" | tr -d ' ')"
    echo "interpretcall_symbols=$(nm -a "$framework" 2>/dev/null | grep -ci interpretcall || true)"
  fi
  echo "finished=$(date -u +%FT%TZ)"
  # The one line the next step should read. `unknown` is NOT success: it means the
  # build never reached the ninja line, which is its own failure.
  if [ "${ninja_rc:-unknown}" = "0" ] && [ -n "$framework" ]; then
    echo "VERDICT=ok"
  else
    echo "VERDICT=failed"
  fi
} > "$STATUS"
