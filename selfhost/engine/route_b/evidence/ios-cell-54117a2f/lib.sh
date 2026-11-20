# shared by steps*.sh. The per-release SDK kept check is ON for every patch: no --allow-unchecked-sdk-calls anywhere.
# cspell:words NUMS
set -uo pipefail
. "$(dirname "$0")/../env.sh"
export PATH="$CLI/bin:$PATH"
trap unlock EXIT
SH=$R/shapes; APP=$R/work/untab; SYS=$R/logs/syslog.txt; NUMS=$R/logs/patch_numbers.txt
launch() { # $1 = name; $2 = "shot" to take screenshots while it boots
  pkill -f "idevicedebug -u $UDID run" ; idevicedebug -u $UDID kill $BUNDLE >/dev/null 2>&1; sleep 3
  off=$(stat -f %z $SYS)
  idevicedebug -u $UDID run $BUNDLE > $R/logs/$1.dbg 2>&1 &
  if [ "${2:-}" = shot ]; then mkdir -p $R/shots; for i in 1 2 3 4 5 6 7 8; do idevicescreenshot -u $UDID $R/shots/$1_$i.png >/dev/null 2>&1; done; sleep 20; else sleep 40; fi
  tail -c +$off $SYS | grep -aE 'Runner\(Flutter\)' > $R/logs/$1.txt
  echo "--- $1: $(grep -aoE 'applied [0-9]+/[0-9]+ targets|no active patch|current_patch_number: [A-Za-z(0-9)]+|rolled_back_patch_numbers: [A-Za-z(\[0-9, \])]+' $R/logs/$1.txt | sort -u | tr '\n' ';')"
  grep -aE '\[shorebird\]|shorebird.cc|ROUTEB' $R/logs/$1.txt | grep -aiE 'patch|applied|ROUTEB|error|fail' | sed -E 's/^.*<Notice>: //' | cut -c1-220 | head -8
  grep -aiE 'TickerFuture|Unhandled|NoSuchMethod|Exception' $R/logs/$1.txt | sed -E 's/^.*<Notice>: //' | cut -c1-220 | head -4
  grep -aoE 'shape:[a-z0-9-]+=[^<]*' $R/logs/$1.txt | grep -v 'shape:stream=' | sort -u | cut -c1-120
}
variant() { python3 -I $SH/variants.py $SH/main.dart $SH/tally.dart "$1" $APP/lib/main.dart $APP/packages/tally/lib/tally.dart || { echo "variant $1 did not apply"; exit 1; }; }
patch() { # $1 = variant, $2 = log name. Records "name number" in $NUMS when it publishes.
  variant "$1"
  lock "patch $2"
  (cd $APP && timeout 2400 nice -n 10 $SB patch ios --release-version $VERSION --no-codesign --no-confirm -v > $R/logs/patch_$2.log 2>&1); rc=$?
  unlock
  variant base
  echo "patch $2 exit=$rc"
  n=$(grep -aoE 'Published Patch [0-9]+' $R/logs/patch_$2.log | grep -oE '[0-9]+$' | tail -1)
  [ -n "$n" ] && echo "$2 $n" >> $NUMS
  grep -naE "carrying|Published Patch|cannot|refus|Refus|^  package:|dart: method|SDK|kept|keep_sdk|Iterable|TickerFuture" $R/logs/patch_$2.log | cut -c1-260 | tail -24
  return $rc
}
num() { awk -v k="$1" '$1==k{n=$2} END{print n}' $NUMS; }
rollback() { # $1 = patch number, $2 = log name
  (cd $APP; $SB patches rollback --release-version $VERSION --patch-number "$1" > $R/logs/$2.log 2>&1); echo "$2 (patch $1) exit=$?"; tail -3 $R/logs/$2.log
}
