#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2164,SC2034
# shared by steps.sh / steps2.sh
set -uo pipefail
. "${DEVRUN_ENV:-$(dirname "$0")/../env.sh}" || exit 1
export PATH="$CLI/bin:$PATH"
KEYS_DIR="${KEYS_DIR:-$R/keys}"  # an env.sh from before KEYS_DIR existed has none
SH=$(cd "$(dirname "${BASH_SOURCE[0]}")/../shapes" && pwd); APP="$R/work/untab"; SYS="$R/logs/syslog.txt"
launch() { # $1 = name; $2 = "shot" to take screenshots while it boots
  pkill -f "idevicedebug -u $UDID run" ; idevicedebug -u "$UDID" kill "$BUNDLE" >/dev/null 2>&1; sleep 3
  off=$(stat -f %z "$SYS")
  idevicedebug -u "$UDID" run "$BUNDLE" > "$R/logs/$1.dbg" 2>&1 &
  if [ "${2:-}" = shot ]; then mkdir -p "$R/shots"; for i in 1 2 3 4 5 6 7 8; do idevicescreenshot -u "$UDID" "$R/shots/$1_$i.png" >/dev/null 2>&1; done; sleep 20; else sleep 40; fi
  tail -c +"$off" "$SYS" | grep -aE 'Runner\(Flutter\)' > "$R/logs/$1.txt"
  echo "--- $1: $(grep -aoE 'applied [0-9]+/[0-9]+ targets|no active patch|current_patch_number: [A-Za-z(0-9)]+|rolled_back_patch_numbers: [A-Za-z(\[0-9, \])]+' "$R/logs/$1.txt" | sort -u | tr '\n' ';')"
  grep -aE '\[shorebird\]|shorebird.cc|ROUTEB' "$R/logs/$1.txt" | grep -aiE 'patch|applied|ROUTEB|error|fail' | sed -E 's/^.*<Notice>: //' | cut -c1-220 | head -8
  grep -aoE 'shape:[a-z0-9-]+=[^<]*' "$R/logs/$1.txt" | grep -v 'shape:stream=' | sort -u | cut -c1-120
}
variant() { python3 -I "$SH/variants.py" "$SH/main.dart" "$SH/tally.dart" "$1" "$APP/lib/main.dart" "$APP/packages/tally/lib/tally.dart" || { echo "variant $1 did not apply"; exit 1; }; }
patch() { # $1 = variant, $2 = log name
  variant "$1"
  (cd "$APP" && nice -n 10 "$SB" patch ios --release-version "$VERSION" --no-codesign --public-key-path="$KEYS_DIR/public.pem" --private-key-path="$KEYS_DIR/private.pem" --no-confirm -v > "$R/logs/patch_$2.log" 2>&1); rc=$?
  variant base
  echo "patch $2 exit=$rc"
  grep -naE "carrying|Published Patch|cannot|refus|Refus|^  package:" "$R/logs/patch_$2.log" | cut -c1-260 | tail -20
  return $rc
}
# Detached launch: no debugger, so a crash leaves a crash report (crash_reports fetches them).
# $1 = name, $2 = seconds to wait; logs go to $L (default $R/logs).
boot() {
  local d="${L:-$R/logs}"; mkdir -p "$d"
  pkill -f "idevicedebug -u $UDID run"; idevicedebug -u "$UDID" kill "$BUNDLE" >/dev/null 2>&1; sleep 3; off=$(stat -f %z "$SYS")
  idevicedebug -u "$UDID" --detach run "$BUNDLE" > "$d/$1.dbg" 2>&1; sleep "${2:-30}"
  for i in 1 2; do idevicescreenshot -u "$UDID" "$d/$1_$i.png" >/dev/null 2>&1; sleep 4; done
  tail -c +"$((off + 1))" "$SYS" > "$d/$1.sys"
  echo "--- $1"
  grep -aE 'Runner\(Flutter\)' "$d/$1.sys" | grep -aE 'Prepared|known bad|downloaded|ROUTEB|REFUSED|rolled|Launch success|shape:(init|future-builder|count)' \
    | sed -E 's/^[A-Z][a-z]{2} +[0-9]+ //;s/Runner\(Flutter\)\[[0-9]+\] <[A-Za-z]+>: //;s/\[ERROR:flutter[^]]*\] //' | cut -c1-200 | head -20
  grep -aE "${BUNDLE##*.}>:[0-9]+\] (termination reported|Process exited)|ReportCrash.*Runner" "$d/$1.sys" | cut -c1-200 | head -4
}
# The app's crash reports written on the phone at or after $2 (YYYY-MM-DD-HHMMSS, phone local time),
# copied into a fresh $1/crash. Prints their names; none means no crash. Returns 2 if the copy failed.
crash_reports() {
  rm -rf "$1/crash"; mkdir -p "$1/crash"
  idevicecrashreport -u "$UDID" -k -f Runner "$1/crash" > "$1/crash.out" 2>&1 || { echo "idevicecrashreport failed: $(tail -1 "$1/crash.out")"; return 2; }
  find "$1/crash" -type f -name 'Runner-*.ips' | sed -E 's#.*/Runner-##; s#\.ips$##' | sort | awk -v t="$2" '$0 >= t {print "Runner-" $0 ".ips"}'
}
