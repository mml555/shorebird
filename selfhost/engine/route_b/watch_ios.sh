#!/usr/bin/env bash
#
# watch_ios.sh -- watch the iOS build for its BINARY outcome. On failure,
# capture the full surrounding context and the exact failing command line --
# "Unexpected tag 4 (Field)" as a headline says nothing about which
# reader/writer contract disagrees, and ninja prints the whole invocation
# under FAILED:.
#
# VENDORED 2026-09-10 from /Volumes/build/route-b/watch_ios.sh, previously the
# only copy. Changes from that original, all of them here: ROOT and MOUNT take
# the house ${VAR:-default} form (build_host.sh:17), and an abort when no
# ios_release_*.log matches -- the original bound L to the empty string and then
# watched it forever, which reads on screen exactly like a build still running.
# Full diff: evidence/host/SSD_SCRIPT_VENDORING_2026-09-10.txt.
set -uo pipefail
ROOT=${ROOT:-/Volumes/build/route-b}
MOUNT=${MOUNT:-/Volumes/build}
L=$(ls -t "$ROOT"/logs/ios_release_*.log 2>/dev/null | head -1)
[ -n "$L" ] || { echo "ABORT: no $ROOT/logs/ios_release_*.log to watch" >&2; exit 2; }
while true; do
  if grep -q "=== ninja exit=" "$L" 2>/dev/null; then
    rc=$(grep -m1 "=== ninja exit=" "$L" | sed 's/.*exit=\([0-9]*\).*/\1/')
    if [ "$rc" = "0" ]; then
      echo "IOS BUILD PASSED -- AOT boundary cleared. Flutter.framework:"
      grep -A2 "Flutter.framework binary" "$L" | tail -2
    else
      echo "IOS BUILD FAILED (ninja exit=$rc). Full context follows in the log: $L"
      # The failing command, then everything after it: ninja prints the command
      # line under FAILED: and the compiler/AOT output immediately below.
      grep -n "FAILED:" "$L" | tail -3
    fi
    exit 0
  fi
  # The build volume is external and has detached mid-write twice
  # (MEDIA_PRESERVATION.md:5-8). A vanished mount looks exactly like a build
  # that has simply not finished, so name it rather than wait forever.
  if ! mount | grep -q "on $MOUNT "; then
    echo "ALERT: $MOUNT detached during the iOS build."
    exit 1
  fi
  sleep 120
done
