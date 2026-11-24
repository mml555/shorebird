# #254 on Android, cell 9995f957: Android patches are full AOT, so the iOS kept check does not apply. Every edit the iPhone
# refused (t254 awaiting a TickerFuture, p06/p07/p08 with an ordinary await, the trio) should publish and run here.
. "$(dirname "$0")/lib.sh"
launch boot_release shot
launch boot_release2
try_patch t254_await_ticker t254
try_patch p06_async_return+p07_async_loop+p08_async_star+p03_setstate_closure+p16b_sdk_list_add_length+p29_const_only awaits
echo "--- patches on server:"; cd $APP; $SB patches list --release-version $VERSION 2>&1 | tail -20; cd $R
cat $NUMS
last=$(tail -1 $NUMS); rollback "${last#* }" rollback1
launch rb1_learn; launch rb1_boot; launch rb1_boot2
echo STEPS_DONE
