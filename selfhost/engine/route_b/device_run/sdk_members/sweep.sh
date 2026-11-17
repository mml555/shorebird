#!/usr/bin/env bash
# cspell:words SDKPROBE
# shellcheck disable=SC1090,SC2164,SC2034
# sweep.sh <name> [max launches]: launch the app until it prints SDKPROBE SWEEP_DONE. An abort kills
# the process; the next launch marks the probe that was running as ABORTS and goes on (see the
# runner in gen_device_probe.py), so each launch is one device cycle.
# Needs $DEVRUN_ENV (default ../env.sh, from ../env.example.sh): R, UDID, BUNDLE; idevicesyslog must be
# writing $R/logs/syslog.txt (../bin/up.sh starts it) and the app must be a release built by release_probe.sh.
# Appends every SDKPROBE line of every launch to $R/logs/<name>.txt.
set -uo pipefail
. "${DEVRUN_ENV:-$(dirname "$0")/../env.sh}" || exit 1
NAME=${1:?name}; MAX=${2:-40}; SYS="$R/logs/syslog.txt"; : > "$R/logs/$NAME.txt"
# has <pattern>: whether this launch's part of the syslog (from $off) holds the pattern. `grep -q` would end
# the pipe early, `tail` would die of SIGPIPE, and under `pipefail` the test would then fail on a big
# syslog (3 GB here), so a finished sweep kept launching until the budget ran out. grep -c reads it all.
has() { [ "$(tail -c +"$off" "$SYS" | grep -ac "$1")" -gt 0 ]; }
for n in $(seq 1 "$MAX"); do
  pkill -f "idevicedebug -u $UDID run"; idevicedebug -u "$UDID" kill "$BUNDLE" >/dev/null 2>&1; sleep 3
  off=$(stat -f %z "$SYS")
  idevicedebug -u "$UDID" run "$BUNDLE" > "$R/logs/$NAME.$n.dbg" 2>&1 & pid=$!
  idle=0; last=0
  for _ in $(seq 1 240); do
    sleep 2
    cur=$(tail -c +"$off" "$SYS" | grep -ac 'SDKPROBE')
    if has 'SDKPROBE SWEEP_DONE'; then break; fi
    if [ "$cur" = "$last" ]; then idle=$((idle+1)); else idle=0; last=$cur; fi
    # a patched launch spends 20-30 s activating targets and 6 s in main before the first line, so
    # idle only counts once a line was seen; a dead debugger process ends the wait after 3 idle polls
    if [ "$last" -gt 0 ] && [ "$idle" -ge 5 ]; then break; fi
    if ! kill -0 "$pid" 2>/dev/null && [ "$idle" -ge 3 ]; then break; fi
  done
  sleep 3
  tail -c +"$off" "$SYS" | grep -a 'SDKPROBE' | sed -E 's/^.*flutter: //' >> "$R/logs/$NAME.txt"
  tail -c +"$off" "$SYS" | grep -aE 'applied [0-9]+/[0-9]+ targets|current_patch_number|Fatal|crash|Abort|Attempt to compile' | sed -E 's/^.*<Notice>: //' | cut -c1-200 | head -5
  echo "launch $n: $(tail -c +"$off" "$SYS" | grep -ac 'SDKPROBE RESULT') results, last: $(tail -c +"$off" "$SYS" | grep -a 'SDKPROBE' | tail -1 | sed -E 's/^.*flutter: //')"
  if has 'SDKPROBE SWEEP_DONE'; then echo "SWEEP_DONE after $n launches"; pkill -f "idevicedebug -u $UDID run"; exit 0; fi
done
echo "SWEEP_NOT_DONE"; exit 1
