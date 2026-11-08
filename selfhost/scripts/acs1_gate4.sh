#!/usr/bin/env bash
# cspell:words getsockname pristine
# ANDROID-CELL-SUPPLY-1 gate 4: prove the measured closure is sufficient AND
# load-bearing, against a STRICT temporary origin — never the published cell
# namespace.
set -uo pipefail
A=/Volumes/build/route-b/acs1
pass=0; fail=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
step(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
free_port(){ python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

# Runs `flutter precache --android` on a PRISTINE checkout against a strict
# origin rooted at $1. Echoes "exit=<rc>".
trial(){
  local root=$1 name=$2
  local port; port=$(free_port)
  rm -rf "$A/t_$name"; cp -R "$A/flutter_pristine" "$A/t_$name"
  : > "$A/$name.origin.jsonl"
  python3 "$A/strict_origin.py" "$port" "$root" "$A/$name.origin.jsonl" >/dev/null 2>&1 &
  local pid=$!
  sleep 1
  FLUTTER_STORAGE_BASE_URL="http://127.0.0.1:$port" \
    timeout 1800 "$A/t_$name/bin/flutter" precache --android > "$A/$name.log" 2>&1
  local rc=$?
  kill $pid 2>/dev/null
  echo "$rc"
}

step "1. the measured closure is SUFFICIENT"
RC=$(trial "$A/store" full)
echo "  precache exit=$RC   requests=$(wc -l < $A/full.origin.jsonl | tr -d ' ')"
[ "$RC" -eq 0 ] && ok "precache succeeded against the strict origin alone" \
  || { bad "precache failed against the full closure"; tail -4 $A/full.log | sed 's/^/      /'; }
MISS=$(python3 -c "
import json;print(sum(1 for l in open('$A/full.origin.jsonl') if not json.loads(l)['served']))")
[ "$MISS" -eq 0 ] && ok "every request was served locally (0 absences)" \
  || bad "$MISS request(s) hit an absent object"

step "2. NO REQUEST ESCAPES — the origin is the only source"
# Strict mode has no upstream at all, so an escape would have to be a direct
# connection. Assert the log names no upstream host.
if grep -qE 'download\.shorebird\.dev|storage\.googleapis\.com|download\.flutter\.io/' $A/full.log; then
  bad "the precache log names an upstream host"; grep -oE 'https?://[^ ]*' $A/full.log | sort -u | head -3 | sed 's/^/      /'
else
  ok "the precache log names no upstream host"
fi

step "3. LOAD-BEARING — delete one required member"
VICTIM=flutter_infra_release/flutter/cd848320d605ff8af5060cabf9a8d1b35853f752/android-arm64-release/darwin-x64.zip
rm -rf "$A/store_missing"; cp -R "$A/store" "$A/store_missing"; rm -f "$A/store_missing/$VICTIM"
RC=$(trial "$A/store_missing" missing)
echo "  precache exit=$RC"
[ "$RC" -ne 0 ] && ok "precache FAILED with that one member absent" \
  || bad "precache still succeeded without a required member"
if grep -q "android-arm64-release/darwin-x64.zip" $A/missing.log; then
  ok "it failed naming that exact object"
  grep -m1 -E "Failed to download|android-arm64-release" $A/missing.log | sed 's/^/      /'
else
  bad "the failure did not name the deleted object"
fi

step "4. UNRELATED FILES CANNOT RESCUE IT"
rm -rf "$A/store_decoy"; cp -R "$A/store_missing" "$A/store_decoy"
D="$A/store_decoy/flutter_infra_release/flutter/cd848320d605ff8af5060cabf9a8d1b35853f752"
mkdir -p "$D/android-arm64-release"
head -c 4000000 /dev/urandom > "$D/android-arm64-release/darwin-x64.zip.decoy"
head -c 4000000 /dev/urandom > "$D/android-arm64-release/UNRELATED.zip"
cp "$A/store/$VICTIM" "$D/android-arm64-profile/darwin-x64.zip.copy" 2>/dev/null || true
RC=$(trial "$A/store_decoy" decoy)
echo "  precache exit=$RC"
[ "$RC" -ne 0 ] && ok "decoys next to the hole did not rescue it" \
  || bad "an unrelated file satisfied a required member"

step "RESULT"; printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
