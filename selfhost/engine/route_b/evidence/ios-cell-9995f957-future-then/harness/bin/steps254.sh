# #254 on cell 9995f957 (Route B analysis 24), check on, no --allow-unchecked-sdk-calls.
# t254 awaits a TickerFuture the release compiled no `then` for: it must be refused before upload. If it publishes, it is
# launched, which is the crash #254 describes. Then the await-bearing edits that published on f2458551 (p06, p07, p08)
# are patched alone, since analysis 24 now checks every `await` on a `Future` as a call of `then`; each that publishes is
# launched. The trio without p07 and p05 (no await) must publish and run. Last, the newest patch is rolled back.
. "$(dirname "$0")/lib.sh"
try() { # $1 variant, $2 name: patch; launch it if it publishes
  if patch $1 $2; then echo "$2 PUBLISHED"; launch ${2}_download; launch ${2}_boot shot; launch ${2}_boot2; else echo "$2 REFUSED"; fi
}
launch boot_release
launch boot_release2
try t254_await_ticker t254
try p06_async_return p06
try p07_async_loop p07
try p08_async_star p08
try p03_setstate_closure+p16b_sdk_list_add_length+p29_const_only trio2
try p05_init_state p05
echo "--- patches on server:"; (cd $APP; $SB patches list --release-version $VERSION 2>&1 | tail -15)
last=$(tail -1 $NUMS 2>/dev/null || true); echo "newest: $last"
if [ -n "$last" ]; then rollback "${last#* }" rollback; launch rb_learn; launch rb_boot; launch rb_boot2; fi
echo STEPS254_DONE
