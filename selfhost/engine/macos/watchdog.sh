#!/usr/bin/env bash
# Prints what happened and exits when the macOS build stalls or ends. Run it
# in the background next to every long build_shard.py run:
#
#   nohup caffeinate -i python3 build_shard.py ... > "$W/logs/build.log" 2>&1 &
#   watchdog.sh $! &
#
# Exit codes: 0 every shard built for the checkout's engine commit, 3 the build ended with shards left,
# 1 stalled (no shard log written for STALL_MINUTES, default 30), 2 bad usage.
here="$(cd "$(dirname "$0")" && pwd)"
cd "${SHOREBIRD_ENGINE_DIR:-$HOME/shorebird-engine}" || exit 2
pid="${1:-$(cat logs/build.pid 2>/dev/null)}"
[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || { echo "watchdog: no running build (pass its pid)"; exit 2; }
limit=$(( ${STALL_MINUTES:-30} * 60 ))
started=$(date +%s)
while :; do
  if ! kill -0 "$pid" 2>/dev/null; then
    sleep 2  # let the last status line land
    left=$(python3 "$here/build_shard.py" --left)
    echo "BUILD ENDED; not built: ${left:-none}"; tail -3 logs/shards.status
    [ -z "$left" ] && exit 0 || exit 3
  fi
  # Only this run's logs: earlier attempts are renamed *.attempt*.log.
  newest=$started
  for f in logs/shard-*.log; do
    case "$f" in *.attempt*|*.aborted*) continue ;; esac
    [ -f "$f" ] || continue
    m=$(stat -f %m "$f"); [ "$m" -gt "$newest" ] && newest=$m
  done
  age=$(( $(date +%s) - newest ))
  if [ "$age" -gt "$limit" ]; then
    echo "STALLED: no shard log written for $((age/60)) min"; ls -t logs/shard-*.log | head -1 | xargs tail -2
    exit 1
  fi
  sleep 60
done
