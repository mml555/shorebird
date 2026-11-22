# shared by steps.sh. The per-release SDK kept check is ON for every patch: no --allow-unchecked-sdk-calls anywhere.
# cspell:words NUMS logcat pidof
set -uo pipefail
. "$(dirname "$0")/../env.sh"
export PATH="$CLI/bin:$PATH"
trap unlock EXIT
SH=$R/shapes; APP=$R/work/untab; NUMS=$R/logs/patch_numbers.txt
adb() { $ADB -s $DEV "$@"; }
keyguard_ok() { # a secure keyguard makes the app unlaunchable; stop the whole run, never bypass
  adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1; sleep 1
  if adb shell dumpsys window | grep -q 'isKeyguardShowing=true'; then echo "KEYGUARD SHOWING: stopping, not bypassing"; touch $R/KEYGUARD_STOP; exit 99; fi
}
launch() { # $1 = name; $2 = "shot" to pull a screenshot while it boots
  [ -f $R/KEYGUARD_STOP ] && exit 99
  keyguard_ok
  adb shell am force-stop $PKG; sleep 2
  adb logcat -c
  adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  if [ "${2:-}" = shot ]; then sleep 12; adb shell screencap -p /sdcard/shapes_shot.png >/dev/null 2>&1; adb pull /sdcard/shapes_shot.png $R/shots/$1.png >/dev/null 2>&1; adb shell rm -f /sdcard/shapes_shot.png; sleep 13; else sleep 25; fi
  pid=$(adb shell pidof $PKG | tr -d '\r'); echo "pid=${pid:-NONE} (alive after wait: $([ -n "$pid" ] && echo yes || echo NO))" > $R/logs/$1.pid
  if [ -n "$pid" ]; then adb logcat -d --pid=$pid > $R/logs/$1.txt 2>&1; else adb logcat -d | grep -aE "$PKG|AndroidRuntime|FATAL|libc.*Fatal" > $R/logs/$1.txt 2>&1; fi
  echo "--- $1: $(cat $R/logs/$1.pid); $(grep -aoE 'applied [0-9]+/[0-9]+ targets|no active patch|current_patch_number: [A-Za-z(0-9)]+|rolled_back_patch_numbers: [A-Za-z(\[0-9, \])]+' $R/logs/$1.txt | sort -u | tr '\n' ';')"
  grep -aiE 'shorebird|updater|patch' $R/logs/$1.txt | grep -aviE 'shape:' | sed -E 's/^[0-9-]+ [0-9:.]+ +[0-9]+ +[0-9]+ //' | cut -c1-220 | head -10
  grep -aiE 'TickerFuture|Unhandled|NoSuchMethod|Exception|FATAL|Wrong full snapshot' $R/logs/$1.txt | cut -c1-220 | head -4
  grep -aoE 'shape:[a-z0-9-]+=[^<]*' $R/logs/$1.txt | grep -v 'shape:stream=' | sort -u | cut -c1-120
}
variant() { python3 -I $SH/variants.py $SH/main.dart $SH/tally.dart "$1" $APP/lib/main.dart $APP/packages/tally/lib/tally.dart || { echo "variant $1 did not apply"; exit 1; }; }
patch() { # $1 = variant, $2 = log name. Records "name number" in $NUMS when it publishes.
  variant "$1"
  lock "patch $2"
  (cd $APP && timeout 2400 nice -n 10 $SB patch android --release-version $VERSION --no-confirm -v > $R/logs/patch_$2.log 2>&1); rc=$?
  unlock
  variant base
  echo "patch $2 exit=$rc"
  n=$(grep -aoE 'Published Patch [0-9]+' $R/logs/patch_$2.log | grep -oE '[0-9]+$' | tail -1)
  [ -n "$n" ] && echo "$2 $n" >> $NUMS
  grep -naE "carrying|Published Patch|cannot|refus|Refus|^  package:|dart: method|SDK|kept|keep_sdk|Iterable|TickerFuture|Platform:|arm" $R/logs/patch_$2.log | cut -c1-260 | tail -24
  return $rc
}
num() { awk -v k="$1" '$1==k{n=$2} END{print n}' $NUMS; }
rollback() { # $1 = patch number, $2 = log name
  (cd $APP; $SB patches rollback --release-version $VERSION --patch-number "$1" > $R/logs/$2.log 2>&1); echo "$2 (patch $1) exit=$?"; tail -3 $R/logs/$2.log
}
try_patch() { # $1 variant, $2 name: publish -> launch download/boot/boot2; refused -> record
  if patch "$1" "$2"; then echo "$2 PUBLISHED"; launch ${2}_download; launch ${2}_boot shot; launch ${2}_boot2; else echo "$2 NOT PUBLISHED (exit above)"; fi
}
