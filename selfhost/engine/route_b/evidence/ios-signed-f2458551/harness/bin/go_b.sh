# Second session: up, steps_b, down. Keeps the first session's logs (up_b.out, steps_b.out, down_b.out).
D="$(dirname "$0")"; L="$D/../logs"
bash $D/up.sh > $L/up_b.out 2>&1; rc=$?; echo "up exit=$rc" >> $L/up_b.out
[ $rc = 0 ] && { bash $D/steps_b.sh > $L/steps_b.out 2>&1; echo "steps_b exit=$?" >> $L/steps_b.out; }
bash $D/down.sh > $L/down_b.out 2>&1
echo GO_B_DONE
