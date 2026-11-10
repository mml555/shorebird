#!/bin/bash
# kill.sh NAME PORT SECONDS_BEFORE_KILL KILLS: SIGKILL the server mid-run and restart it.
. "$(dirname "$0")/lib.sh"
T=${3:?seconds}; K=${4:?kills}
# shellcheck disable=SC2119
start_server
python3 drive.py "http://127.0.0.1:$P" "sb_api_repro_$N" "out-$N.json" 10 8 interrupt > "drv-$N.txt" 2>&1 &
D=$!
for _ in $(seq 1 "$K"); do sleep "$T"; docker kill "$C" >/dev/null; sleep 1; docker start "$C" >/dev/null; done
wait "$D"
cat "drv-$N.txt"
docker kill "$C" >/dev/null 2>&1 || true   # final unclean stop before reading
read_back
