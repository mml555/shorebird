# cspell:words setstate
# Launch the release, then patch: 1 = the combination (18 edits), 2 = p03+p16+p29+p07, then
# two edits that must be REFUSED before publishing (p20 const, p30 field initializer), then rollback.
set -uo pipefail
. "$(dirname "$0")/../env.sh"
export PATH="$CLI/bin:$PATH"
SH=$R/shapes; APP=$R/work/untab; SYS=$R/logs/syslog.txt
launch() { # $1 = name
  pkill -f "idevicedebug -u $UDID run" ; idevicedebug -u $UDID kill $BUNDLE >/dev/null 2>&1; sleep 3
  off=$(stat -f %z $SYS)
  idevicedebug -u $UDID run $BUNDLE > $R/logs/$1.dbg 2>&1 &
  sleep 40
  tail -c +$off $SYS | grep -aE 'Runner\(Flutter\)' > $R/logs/$1.txt
  echo "--- $1"
  grep -aE '\[shorebird\]|shorebird.cc|ROUTEB' $R/logs/$1.txt | grep -aiE 'patch|applied|ROUTEB|error|fail' | sed -E 's/^.*<Notice>: //' | cut -c1-220 | head -8
  grep -aoE 'shape:[a-z-]+=[^<]*' $R/logs/$1.txt | sort -u | cut -c1-120
}
variant() { python3 -I $SH/variants.py $SH/main.dart $SH/tally.dart "$1" $APP/lib/main.dart $APP/packages/tally/lib/tally.dart || { echo "variant $1 did not apply"; exit 1; }; }
patch() { # $1 = variant, $2 = log name
  variant "$1"
  (cd $APP && nice -n 10 $SB patch ios --release-version $VERSION --no-codesign --no-confirm -v > $R/logs/patch_$2.log 2>&1); rc=$?
  variant base
  echo "patch $2 exit=$rc"
  grep -naE "carrying|Published Patch|cannot|refus|Refus|^  package:" $R/logs/patch_$2.log | cut -c1-260 | tail -20
  return $rc
}
launch boot_release
launch boot_release2
patch combo combo || echo "COMBO PATCH FAILED"
launch combo_download
launch combo_boot
launch combo_boot2
patch p03_setstate_closure+p16_sdk_list_add+p29_const_only+p07_async_loop trio || echo "TRIO PATCH FAILED"
launch trio_download
launch trio_boot
launch trio_boot2
patch p20_const refuse_const && echo "UNEXPECTED: p20 published"
patch p30_field_initializer refuse_field && echo "UNEXPECTED: p30 published"
$SB patches rollback --release-version $VERSION --patch-number 2 > $R/logs/rollback.log 2>&1
echo "rollback exit=$?"; tail -3 $R/logs/rollback.log
launch rb_learn
launch rb_boot
echo STEPS_DONE
