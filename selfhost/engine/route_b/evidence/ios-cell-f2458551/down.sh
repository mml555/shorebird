# Stop everything up.sh started; release heavy.lock if this run holds it.
. "$(dirname "$0")/../env.sh"
for f in server origin connproxy syslog; do [ -f $R/$f.pid ] && kill "$(cat $R/$f.pid)" 2>/dev/null; rm -f $R/$f.pid; done
pkill -f "idevicedebug -u $UDID" 2>/dev/null
grep -q devrun-f2458551 "$LOCK/owner" 2>/dev/null && { rm -f "$LOCK/owner"; rmdir "$LOCK"; }
echo DOWN_DONE
