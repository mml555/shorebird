# The whole run: up, release + upgrade install, steps254, then down. Each step's output is logs/<step>.out.
D="$(dirname "$0")"; L="$D/../logs"
bash $D/up.sh > $L/up.out 2>&1; rc=$?; echo "up exit=$rc" >> $L/up.out
if [ $rc = 0 ]; then
  bash $D/release.sh > $L/release.out 2>&1; rc=$?; echo "release exit=$rc" >> $L/release.out
  if [ $rc = 0 ]; then
    for s in stepsF; do bash $D/$s.sh > $L/$s.out 2>&1; echo "$s exit=$?" >> $L/$s.out; done
  fi
fi
bash $D/down.sh > $L/down.out 2>&1
echo GO_DONE
