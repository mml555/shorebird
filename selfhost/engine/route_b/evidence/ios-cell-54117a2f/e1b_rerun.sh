# e1b re-run on CLI 37a0434b (the merge of #257: an extension getter's packed selector is no longer cut at the last
# `#`). Same release 1.0.0+71 and server data; the check is on. The first run's syslog and ledgers are kept as *.run1.*.
. "$(dirname "$0")/lib.sh"
patch e1b_extension_static_interp e1b_rerun && { launch e1b_rerun_download; launch e1b_rerun_boot; launch e1b_rerun_boot2; } || echo "e1b_rerun REFUSED"
grep -aE '\[route-b\] compiled' $R/logs/patch_e1b_rerun.log | cut -c1-120
echo "--- patches on server:"; cd $APP; $SB patches list --release-version $VERSION 2>&1 | tail -16
echo E1B_RERUN_DONE
