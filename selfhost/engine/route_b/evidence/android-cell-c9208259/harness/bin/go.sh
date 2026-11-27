D="$(dirname "$0")"; L="$D/../logs"
bash $D/up.sh > $L/up.out 2>&1; rc=$?; echo "up exit=$rc" >> $L/up.out
if [ $rc = 0 ]; then
  bash $D/release.sh > $L/release.out 2>&1; rc=$?; echo "release exit=$rc" >> $L/release.out
  if [ $rc = 0 ]; then bash $D/steps.sh > $L/steps.out 2>&1; echo "steps exit=$?" >> $L/steps.out; fi
fi
bash $D/down.sh > $L/down.out 2>&1
echo GO_DONE
