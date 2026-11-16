set -uo pipefail
. "$(dirname "$0")/../env.sh"
export PATH="$CLI/bin:$PATH"
APP=$R/work/untab; SYS=$R/logs/syslog.txt
launch() {
  pkill -f "idevicedebug -u $UDID run" ; idevicedebug -u $UDID kill $BUNDLE >/dev/null 2>&1; sleep 3
  off=$(stat -f %z $SYS)
  idevicedebug -u $UDID run $BUNDLE > $R/logs/$1.dbg 2>&1 &
  sleep 40
  tail -c +$off $SYS | grep -aE 'Runner\(Flutter\)' > $R/logs/$1.txt
  echo "--- $1: $(grep -aoE 'applied [0-9]+/[0-9]+ targets|no active patch|current_patch_number: [A-Za-z(0-9)]+|rolled_back_patch_numbers: [A-Za-z(\[0-9, \])]+' $R/logs/$1.txt | sort -u | tr '\n' ';')"
  grep -aoE 'shape:(count|label|init|route)=[^<]*' $R/logs/$1.txt | sort -u | tr '\n' ' '; echo
}
cd $APP
$SB patches rollback --release-version $VERSION --patch-number 2 > $R/logs/rollback.log 2>&1
echo "rollback exit=$?"; tail -2 $R/logs/rollback.log
launch rb_learn
launch rb_boot
launch rb_boot2
