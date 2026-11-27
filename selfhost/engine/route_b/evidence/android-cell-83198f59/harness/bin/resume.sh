# Resume after a keyguard stop: the release is already built, published and installed (app.env, data/), so only
# up, steps and down run again. Each step's output is logs/<step>.resume.out.
D="$(dirname "$0")"; L="$D/../logs"; rm -f "$D/../KEYGUARD_STOP"
bash $D/up.sh > $L/up.resume.out 2>&1; rc=$?; echo "up exit=$rc" >> $L/up.resume.out
[ $rc = 0 ] && { bash $D/steps.sh > $L/steps.resume.out 2>&1; echo "steps exit=$?" >> $L/steps.resume.out; }
bash $D/down.sh > $L/down.resume.out 2>&1
echo RESUME_DONE
