D="$(dirname "$0")"
bash $D/steps.sh > $D/../logs/steps.out 2>&1; echo "steps exit=$?" >> $D/../logs/steps.out
bash $D/steps2.sh > $D/../logs/steps2.out 2>&1; echo "steps2 exit=$?" >> $D/../logs/steps2.out
bash $D/steps3.sh > $D/../logs/steps3.out 2>&1; echo "steps3 exit=$?" >> $D/../logs/steps3.out
