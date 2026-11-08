#!/usr/bin/env bash
# Sets Documents/g15_mode via the qualified afcclient path, then READS IT BACK.
# A write that is not verified is not a mode selection.
set -uo pipefail
UD=8cb4bc982ddf6437b1952520edee80f898196c74
BID=dev.selfhost.killswitchProbe
MODE="$1"
T=$(mktemp -d)
printf '%s' "$MODE" > "$T/g15_mode"
# `rm` FIRST: afcclient's `put` does NOT overwrite an existing file — it fails
# silently, leaving the previous mode in place. Caught by the readback below,
# which is the only reason five launches did not run in the wrong mode.
printf 'rm Documents/g15_mode\nput %s/g15_mode Documents/g15_mode\nquit\n' "$T" | timeout 45 afcclient -u $UD --container $BID >/dev/null 2>&1
printf 'get Documents/g15_mode %s/readback\nquit\n' "$T" | timeout 45 afcclient -u $UD --container $BID >/dev/null 2>&1
GOT=$(cat "$T/readback" 2>/dev/null)
if [ "$GOT" = "$MODE" ]; then echo "  mode = $MODE  (verified on device)"
else echo "  *** MODE NOT SET: wanted '$MODE', device has '$GOT' ***"; exit 1; fi
rm -rf "$T"
