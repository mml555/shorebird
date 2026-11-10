#!/usr/bin/env bash
# Prints one line and exits when the macOS build stalls (newest shard log
# unchanged for 20 minutes) or ends with non-iOS shards left. Run it in the
# background next to every long build_shard.py run.
#
# usage: watchdog.sh [pid]   (default: the pid in logs/build.pid)
cd "${SHOREBIRD_ENGINE_DIR:-$HOME/shorebird-engine}" || exit 2
pid="${1:-$(cat logs/build.pid 2>/dev/null)}"
[ -n "$pid" ] || { echo "no pid given and no logs/build.pid"; exit 2; }
while :; do
  if ! kill -0 "$pid" 2>/dev/null; then
    left=$(python3 -c "
import json
ok={l.split()[2].rstrip(':') for l in open('logs/shards.status') if len(l.split())>3 and l.split()[3]=='OK'}
print(' '.join(n for n in json.load(open('flutter/shorebird/ci/shards/macos.json')) if not n.startswith('ios') and n not in ok))")
    echo "BUILD ENDED; not built: ${left:-none}"; tail -3 logs/shards.status; exit 0
  fi
  log=$(ls -t logs/shard-*.log 2>/dev/null | head -1)
  if [ -n "$log" ]; then
    age=$(( $(date +%s) - $(stat -f %m "$log") ))
    [ "$age" -gt 1200 ] && { echo "STALLED: $log unchanged for $((age/60)) min"; tail -2 "$log"; exit 1; }
  fi
  sleep 60
done
