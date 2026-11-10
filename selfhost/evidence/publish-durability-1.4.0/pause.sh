#!/bin/bash
# pause.sh NAME PORT: a starved server (0.3 CPU, 256 MB) paused 3 s out of every 5 during the run.
. "$(dirname "$0")/lib.sh"
start_server --cpus 0.3 --memory 256m
python3 drive.py "http://127.0.0.1:$P" "sb_api_repro_$N" "out-$N.json" 6 8 plain > "drv-$N.txt" 2>&1 &
D=$!
while kill -0 "$D" 2>/dev/null; do sleep 2; docker pause "$C" >/dev/null; sleep 3; docker unpause "$C" >/dev/null; done
cat "drv-$N.txt"
read_back
log_summary
