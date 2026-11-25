# #289 follow-up on cell 9995f957, CLI a4f84392: a release that names Future.catchError, whenComplete and timeout.
# Each of f01-f03 calls one of them on a Future value in loadGreeting and changes its greeting (G5, G6, G7). On
# release 1.0.0+77 (CLI 668ce3f0) all three are refused (no compiled member on TickerFuture). Here each must publish
# with the kept check on, and launch showing its greeting with no crash. Last, the newest patch is rolled back.
. "$(dirname "$0")/lib.sh"
try() { # $1 variant, $2 name: patch; launch it if it publishes
  if patch $1 $2; then echo "$2 PUBLISHED"; launch ${2}_download; launch ${2}_boot shot; launch ${2}_boot2; else echo "$2 REFUSED"; fi
}
launch boot_release
launch boot_release2
try f01_timeout f01
try f02_when_complete f02
try f03_catch_error f03
echo "--- patches on server:"; (cd $APP; $SB patches list --release-version $VERSION 2>&1 | tail -15)
last=$(tail -1 $NUMS 2>/dev/null || true); echo "newest: $last"
if [ -n "$last" ]; then rollback "${last#* }" rollback; launch rb_learn; launch rb_boot; launch rb_boot2; fi
echo STEPSF_DONE
