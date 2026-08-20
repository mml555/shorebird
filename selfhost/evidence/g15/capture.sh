#!/usr/bin/env bash
# Non-booting lifecycle capture. QUALIFIED primitive only (afcclient / house_arrest).
# Usage: capture.sh <label>
set -uo pipefail
UD=8cb4bc982ddf6437b1952520edee80f898196c74
BID=dev.selfhost.killswitchProbe
B="Library/Application Support/shorebird/shorebird_updater"
OUT=/Volumes/build/route-b/tombstone/$1
rm -rf "$OUT"; mkdir -p "$OUT"
afc() { timeout 45 afcclient -u $UD --container $BID >/dev/null 2>&1; }

wit() {
  printf 'get Documents/g15_receipt %s/r_%s\nquit\n' "$OUT" "$1" | afc
  printf "%s/%s" "$(wc -l < "$OUT/r_$1" 2>/dev/null | tr -d ' ')" "$(grep -c '^native launch' "$OUT/r_$1" 2>/dev/null)"
}

BEFORE=$(wit before)
printf 'get "%s/pointers.json" %s/pointers.json\nget "%s/state.json" %s/state.json\nget "%s/patches/1/state.json" %s/patch1.json\nget "%s/patches/1/dlc.vmcode.routeb.trace" %s/trace\nget "%s/success_diag.log" %s/success_diag.log\nget Documents/g15_receipt %s/g15_receipt\nquit\n' \
  "$B" "$OUT" "$B" "$OUT" "$B" "$OUT" "$B" "$OUT" "${B%/shorebird_updater}" "$OUT" "$OUT" | afc
AFTER=$(wit after)

echo "════ $1 ════"
if [ "$BEFORE" = "$AFTER" ]; then echo "  witness $BEFORE -> $AFTER   read added NO activation"
else echo "  witness $BEFORE -> $AFTER   *** READ PERTURBED STATE — capture invalid ***"; fi
python3 - "$OUT" <<'PY'
import json,os,sys
o=sys.argv[1]
def j(f):
    try: return json.load(open(os.path.join(o,f)))
    except Exception: return None
p,pa,st=j('pointers.json'),j('patch1.json'),j('state.json')
print(f"  pointers : next={p.get('next_boot_patch')} last={p.get('last_booted_patch')} cur={p.get('currently_booting_patch')} count={p.get('boot_attempt_count')} lastAttempt={p.get('last_boot_attempt_patch')}" if p else "  pointers : ABSENT")
print(f"  patch 1  : {(pa.get('kind','?')+('{'+pa['reason']+'}' if pa.get('reason') else '')) if pa else 'ABSENT'}")
q=(st or {}).get('queued_events',[])
print(f"  queued   : {len(q)}" + (" -> "+", ".join(e.get('type','?') for e in q) if q else ""))
PY
echo "  trace_lines: $(wc -l < "$OUT/trace" 2>/dev/null | tr -d ' ' || echo ABSENT)"
if [ -s "$OUT/success_diag.log" ]; then sed 's/^/  success_diag: /' "$OUT/success_diag.log"; else echo "  success_diag: ABSENT (success seam did not execute, or pre-instrumentation engine)"; fi
tail -3 "$OUT/g15_receipt" 2>/dev/null | sed 's/^/  receipt: /'
