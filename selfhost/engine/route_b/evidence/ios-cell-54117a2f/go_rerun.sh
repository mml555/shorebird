# Keeps the first run's logs, brings the servers back up, re-runs e1b, shuts down.
D="$(dirname "$0")"; L="$D/../logs"
for f in syslog.txt origin.jsonl connproxy.jsonl bootstrap.log server.log origin.out connproxy.out; do [ -f $L/$f ] && [ ! -f $L/${f%.*}.run1.${f##*.} ] && mv $L/$f $L/${f%.*}.run1.${f##*.}; done
bash $D/up.sh > $L/up_rerun.out 2>&1; rc=$?; echo "up exit=$rc" >> $L/up_rerun.out
[ $rc = 0 ] && { bash $D/e1b_rerun.sh > $L/e1b_rerun.out 2>&1; echo "e1b_rerun exit=$?" >> $L/e1b_rerun.out; }
bash $D/down.sh > $L/down_rerun.out 2>&1
echo GO_RERUN_DONE
