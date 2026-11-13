set -uo pipefail
. $RUN/env.sh
export PATH="$CLI/bin:$PATH"
APP=$R/work/app; SYS=$R/logs/syslog.txt
launch() { # $1 = name
  pkill -f "idevicedebug -u $UDID run" ; idevicedebug -u $UDID kill $BUNDLE >/dev/null 2>&1; sleep 3
  off=$(stat -f %z $SYS)
  idevicedebug -u $UDID run $BUNDLE > $R/logs/$1.dbg 2>&1 &
  sleep 35
  tail -c +$off $SYS | grep -aE 'Runner\(Flutter\)' | grep -aE 'shorebird|CELL82FC|patch' > $R/logs/$1.txt
  echo "--- $1: $(grep -aoE 'CELL82FC-[A-Z0-9-]+' $R/logs/$1.txt | sort -u | tr '\n' ' ')"
  grep -aE '\[shorebird\]|shorebird.cc' $R/logs/$1.txt | sed -E 's/^.*<Notice>: //' | head -12
}
launch boot_release
cd $APP
sed -i '' 's/CELL82FC-V1-RELEASE/CELL82FC-V2-PATCH1/g' lib/main.dart
$SB patch ios --release-version 1.0.0+1 --no-codesign --no-confirm -v > $R/logs/patch1.log 2>&1
echo "patch1 exit=$?"; tail -5 $R/logs/patch1.log
launch p1_download
launch p1_boot
launch p1_boot2
$SB patches rollback --release-version 1.0.0+1 --patch-number 1 > $R/logs/rollback.log 2>&1
echo "rollback exit=$?"; tail -3 $R/logs/rollback.log
launch rb_learn
launch rb_boot
echo STEPS_DONE
