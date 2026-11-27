# Stop everything up.sh started; remove the adb reverse; release heavy.lock if this run holds it.
. "$(dirname "$0")/../env.sh"
for f in server origin connproxy logcat; do [ -f $R/$f.pid ] && kill "$(cat $R/$f.pid)" 2>/dev/null; rm -f $R/$f.pid; done
$ADB -s $DEV reverse --remove tcp:$PORT 2>/dev/null
grep -q devrun-83198f59-android "$LOCK/owner" 2>/dev/null && { rm -f "$LOCK/owner"; rmdir "$LOCK"; }
echo DOWN_DONE
