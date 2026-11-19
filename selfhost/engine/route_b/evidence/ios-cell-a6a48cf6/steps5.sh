# Cell a6a48cf6, 2026-11-19: boot what steps4b.sh published under --allow-unchecked-sdk-calls, past the #247 false
# positive: i2 (patch 10; its checked run's only refusal was Iterable.iterator) and, if it published, p16 (patch 11).
# p20 is never booted (it was refused for kTitle under the flag, as it must be).
. "$(dirname "$0")/lib.sh"
if grep -q "^p16 PUBLISHED" $R/logs/steps4b.out; then
  launch p16_download; launch p16_boot; launch p16_boot2
  (cd $APP; $SB patches rollback --release-version $VERSION --patch-number 11 > $R/logs/rollback3.log 2>&1; echo "rollback 11 exit=$?"; tail -3 $R/logs/rollback3.log)
  launch i2_learn; launch i2_boot; launch i2_boot2
else
  launch i2_download; launch i2_boot; launch i2_boot2
fi
echo STEPS5_DONE
