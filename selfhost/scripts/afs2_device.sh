#!/usr/bin/env bash
# cspell:words uiautomator screencap dumpsys keyguard reqs booted armeabi keyevent Lockscreen bmgr BMGR vmcode
# ANDROID-FINAL-STACK-2 stage C: the physical sequence on a wired CPH2551.
#
# THE MIDDLE OBSERVATION IS THE POINT. A patch that is downloaded and installed
# must NOT be executing yet; the running process keeps the release marker until
# it is restarted. Without that reading, "the marker changed" is consistent with
# a hot reload, a rebuilt install, or the wrong APK, and proves nothing about
# code push.
#
# The marker is read MECHANICALLY from the accessibility tree (`uiautomator
# dump`), never by looking at a picture. A screenshot is kept alongside as
# human-checkable evidence, pulled as a FILE -- `exec-out screencap -p` shares
# stdout with a "[Warning] Multiple displays" line on this device, which once
# made two different screens produce byte-identical non-PNG captures.
set -uo pipefail
source /Volumes/build/route-b/afs2/control.env
ADB=$HOME/Library/Android/sdk/platform-tools/adb
DEV=${DEV:-3f72a543}
PKG=${PKG:-dev.selfhost.afs2.app}
BASE="http://localhost:$PORT"
SHOT="$WORK/shots"; mkdir -p "$SHOT"
step(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

marker(){
  "$ADB" -s "$DEV" shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
  "$ADB" -s "$DEV" shell cat /sdcard/ui.xml 2>/dev/null \
    | tr '>' '\n' | grep -oE 'AFS2-V[0-9]-[A-Z]+' | head -1
}
shot(){
  "$ADB" -s "$DEV" shell screencap -p /sdcard/shot.png >/dev/null 2>&1
  "$ADB" -s "$DEV" pull /sdcard/shot.png "$SHOT/$1.png" >/dev/null 2>&1
  file "$SHOT/$1.png" | grep -q "PNG image" || echo "    WARNING: $1.png is not a PNG"
}
paths(){ python3 - "$WORK/server.log" "${1:-0}" <<'PY'
import json,sys
skip=int(sys.argv[2]); n=0
for l in open(sys.argv[1], errors='replace'):
    try: d=json.loads(l)
    except Exception: continue
    if d.get('msg')=='request':
        n+=1
        if n>skip: print('      %-6s %-46s %s' % (d['method'], d['path'], d['status']))
PY
}
reqs(){ grep -c '"msg":"request"' "$WORK/server.log" 2>/dev/null || echo 0; }

step "13. the screen must be awake and unlocked"
# A secured keyguard leaves the app running and INVISIBLE: the updater completes
# check -> download -> install while `uiautomator dump` reads nothing, and every
# marker observation comes back empty. That is a rig fault that looks exactly
# like a product failure, so it is a hard precondition, not a warning.
"$ADB" -s "$DEV" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
sleep 1
LOCK=$("$ADB" -s "$DEV" shell dumpsys window 2>/dev/null | grep -oE "mDreamingLockscreen=(true|false)" | head -1)
AWAKE=$("$ADB" -s "$DEV" shell dumpsys window 2>/dev/null | grep -oE "mAwake=(true|false)" | head -1)
echo "    $AWAKE  $LOCK"
if [[ "$LOCK" != "mDreamingLockscreen=false" ]]; then
  echo "  STOP: the device is locked. Unlock it and re-run this stage."
  exit 2
fi
ok "awake and unlocked"

step "14. install the fresh release APK, with a genuinely fresh updater state"
# ANDROID BACKUP AUTO-RESTORE IS A TRAP, and it cost this lane a run.
#
# A `flutter create` app has allowBackup=true. This package name has been used
# by an earlier lane against a DIFFERENT engine, so on reinstall Android
# restored `files/shorebird_updater/` from that app's backup -- including a
# `dlc.vmcode` inflated for the fallback engine. Our engine then loaded it and
# aborted with `Wrong full snapshot version, expected <ours> found <fallback>`,
# which reads exactly like a broken cell and is not one.
#
# So: backup is disabled for the run, and the updater's own log line is
# asserted. Without that assertion the sequence can silently measure RESTORED
# state instead of a fresh install.
"$ADB" -s "$DEV" shell bmgr enable false >/dev/null 2>&1
BMGR=$("$ADB" -s "$DEV" shell bmgr enabled 2>/dev/null | tr -d '\r')
echo "    $BMGR"
[[ "$BMGR" == *disabled* ]] && ok "backup manager disabled, so no state can be restored" \
                            || bad "backup manager is still enabled — a restore could poison the run"
"$ADB" -s "$DEV" reverse "tcp:$PORT" "tcp:$PORT" >/dev/null
"$ADB" -s "$DEV" uninstall "$PKG" >/dev/null 2>&1 || true
"$ADB" -s "$DEV" shell ls -d "/data/data/$PKG" >/dev/null 2>&1 \
  && bad "the app data directory survived the uninstall" \
  || ok "the app data directory is gone after the uninstall"
"$ADB" -s "$DEV" logcat -c >/dev/null 2>&1
"$ADB" -s "$DEV" install -r "$APK" 2>&1 | tail -2 | sed 's/^/    /'
echo "    apk sha256 $(shasum -a 256 "$APK" | cut -d' ' -f1)"
BEFORE=$(reqs); echo "    control-plane requests before launch: $BEFORE"
ok "installed"

step "15. launch as a user would, and read the RELEASE marker"
"$ADB" -s "$DEV" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 12
# The updater must have started from nothing. If it reports a restored state or
# a current patch on a first launch, every later observation is about the wrong
# artifact.
LOG=$("$ADB" -s "$DEV" logcat -d 2>/dev/null | grep -E "flutter : (updater|\[)" || true)
printf '%s\n' "$LOG" | grep -qE "No existing state file found" \
  && ok "the updater started from no state file" \
  || bad "the updater did NOT start from a fresh state — a restore may have poisoned this run"
printf '%s\n' "$LOG" | grep -q "current_patch_number: None" \
  && ok "first patch check reports current_patch_number: None" \
  || bad "the first patch check already names a current patch"
printf '%s\n' "$LOG" | grep -q "Prepared boot of the base release" \
  && ok "this launch booted the BASE release, not a patch" \
  || bad "the first launch did not boot the base release"
shot 1_first_launch
M1=$(marker); echo "    marker on first launch: ${M1:-<none read>}"
[[ "$M1" == "AFS2-V1-RELEASE" ]] && ok "the release marker is on screen" \
                                 || bad "expected AFS2-V1-RELEASE, read '${M1:-<none>}'"

step "16. normal discovery, download and install — no manual trigger"
for i in $(seq 1 14); do
  grep -q '"path":"/api/v1/patches/check"' "$WORK/server.log" 2>/dev/null && break
  sleep 5
done
sleep 8
echo "    what the device asked the control plane:"
paths "$BEFORE"
# RUNTIME PATCH PROVENANCE, which is a different question from engine artifact
# provenance. Stage A answered where the ENGINE came from; this answers where
# the PATCH came from and that the device acknowledged it. Conflating the two
# would let a green attribution on one stand in for the other.
grep -q '"path":"/api/v1/patches/check"' "$WORK/server.log" && ok "the device called /patches/check" \
                                                            || bad "no /patches/check from the device"
grep -qE '"path":"/api/v1/download/|"path":"/download/' "$WORK/server.log" \
  && ok "the device downloaded the patch artifact" || bad "no patch download recorded"
grep -q '"path":"/api/v1/patches/events"' "$WORK/server.log" \
  && ok "the device acknowledged with /patches/events" \
  || echo "  note   no /patches/events yet — re-checked after the restart"
# Every device request must have been answered; a 4xx/5xx here is a rig fault
# masquerading as a product result.
python3 - "$WORK/server.log" <<'PY2'
import json, sys
bad = []
for l in open(sys.argv[1], errors='replace'):
    try:
        d = json.loads(l)
    except Exception:
        continue
    if d.get('msg') == 'request' and int(d.get('status', 0)) >= 400:
        bad.append(f"{d['status']} {d['method']} {d['path']}")
print(f"    device/CLI requests answered 4xx or 5xx: {len(bad)}")
for b in bad:
    print(f"      {b}")
sys.exit(1 if bad else 0)
PY2
[[ $? -eq 0 ]] && ok "no request was refused by the control plane" \
               || bad "the control plane refused a request — see above"

step "16b. the updater's own account of the install"
LOG=$("$ADB" -s "$DEV" logcat -d 2>/dev/null | grep -E "flutter : updater" || true)
printf '%s\n' "$LOG" | grep -E "Inflating patch|successfully applied|Update installed|will be launched" \
  | sed 's/.*\[shorebird\] /      /' | head -6
printf '%s\n' "$LOG" | grep -q "Patch successfully applied" \
  && ok "the diff inflated and was applied" || bad "the updater did not apply the patch"
printf '%s\n' "$LOG" | grep -q "Update thread finished with status: Update installed" \
  && ok "the updater reports: Update installed" || bad "the updater did not report Update installed"
printf '%s\n' "$LOG" | grep -q "will be launched when the app next restarts" \
  && ok "and says it will be launched on the NEXT RESTART — staged, by the product's own account" \
  || bad "the updater did not say the patch is deferred to a restart"
# The inflated size must equal the release artifact it patches, or the base was
# not what the diff was computed against.
printf '%s\n' "$LOG" | grep -oE "base_size=[0-9]+b output_written=[0-9]+b" | head -1 | sed 's/^/      /'

step "17. THE MANDATORY MIDDLE OBSERVATION: staged, not executed"
shot 2_after_download
M2=$(marker); echo "    marker after download, before restart: ${M2:-<none read>}"
if [[ "$M2" == "AFS2-V1-RELEASE" ]]; then
  ok "still the RELEASE marker — the patch is staged, not executing"
elif [[ "$M2" == "AFS2-V2-PATCHED" ]]; then
  bad "the PATCHED marker appeared BEFORE a restart — STOP CONDITION"
else
  bad "could not read a marker at this step ('${M2:-<none>}'); the middle observation is mandatory"
fi

step "18. restart the app — the only lifecycle step"
"$ADB" -s "$DEV" shell am force-stop "$PKG" >/dev/null 2>&1
sleep 2
"$ADB" -s "$DEV" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 11
shot 3_after_restart
M3=$(marker); echo "    marker after restart: ${M3:-<none read>}"
[[ "$M3" == "AFS2-V2-PATCHED" ]] && ok "PATCHED CODE IS EXECUTING" \
                                 || bad "expected AFS2-V2-PATCHED, read '${M3:-<none>}'"

step "19. what the updater reports back"
paths "$BEFORE"
sleep 6
grep -q '"path":"/api/v1/patches/events"' "$WORK/server.log" \
  && ok "/patches/events acknowledgement recorded" || bad "no /patches/events acknowledgement"
python3 - "$WORK/server.log" <<'PY3'
import json, sys
ev = []
for l in open(sys.argv[1], errors='replace'):
    try:
        d = json.loads(l)
    except Exception:
        continue
    if d.get('msg') == 'request' and d.get('path', '').endswith('/patches/events'):
        ev.append(d)
print(f"    /patches/events calls: {len(ev)}  statuses: {[e['status'] for e in ev]}")
PY3
curl -fsS "$BASE/api/v1/apps/$APP_ID/metrics" -H "Authorization: Bearer $API_KEY" \
  > "$WORK/metrics.json" 2>/dev/null
python3 - "$WORK/metrics.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(json.dumps(d, indent=2)[:1400])
PY
python3 - "$WORK/metrics.json" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1]))
# READ THE FIELDS THAT EXIST. A first version of this control looked for
# top-level `patch_install_failure_count` / `install_failures`, which this
# schema does not have -- so `or 0` supplied a zero and the check PASSED while
# the real nested counter said install_failures: 1. A check that cannot see the
# number it is asserting about is worse than no check.
rows = d.get('patches') or []
if not rows:
    print('    NO patches[] rows in the metrics — nothing to assert')
    sys.exit(1)
bad = 0
for r in rows:
    print("    patch %-3s downloads=%-3s installs=%-3s install_failures=%-3s "
          "update_failures=%-3s unique_clients=%s"
          % (r.get('patch_number'), r.get('downloads'), r.get('installs'),
             r.get('install_failures'), r.get('update_failures'),
             r.get('unique_clients')))
    if r.get('installs', 0) < 1:
        print('      FAIL no install recorded for this patch')
        bad = 1
    if r.get('install_failures', 0) != 0:
        print('      FAIL install_failures is not zero')
        bad = 1
    if r.get('update_failures', 0) != 0:
        print('      FAIL update_failures is not zero')
        bad = 1
print(f"    event types: {d.get('events_by_type')}")
print(f"    unique clients on this app: {d.get('unique_clients')}")
if (d.get('unique_clients') or 0) > 1:
    print('      FAIL more than one client reported against this app, so the'
          ' counters mix runs')
    bad = 1
sys.exit(bad)
PY2
[[ $? -eq 0 ]] && ok "patch 1 installed, and install/update failure counts are zero for a single client" \
               || bad "the updater's own counters do not show a clean single-client install"

step "20. the updater's own view, from the device"
"$ADB" -s "$DEV" shell run-as "$PKG" cat /data/data/$PKG/files/shorebird_updater/state.json 2>/dev/null \
  | tee "$WORK/updater_state.json" | sed 's/^/    /'
if [[ -s "$WORK/updater_state.json" ]]; then
  python3 - "$WORK/updater_state.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print(f'    (not parseable: {e})'); sys.exit(0)
print(f"    current_boot_patch    {d.get('current_boot_patch')}")
print(f"    current_slot          {d.get('current_slot')}")
print(f"    next_boot_patch       {d.get('next_boot_patch')}")
PY
else
  echo "    (updater state not readable via run-as on a release build)"
fi

step "21. restore the device's backup setting"
"$ADB" -s "$DEV" shell bmgr enable true >/dev/null 2>&1
echo "    $("$ADB" -s "$DEV" shell bmgr enabled 2>/dev/null | tr -d '\r')"

step "RESULT"
printf '  first launch   : %s\n  after download : %s\n  after restart  : %s\n' \
  "${M1:-?}" "${M2:-?}" "${M3:-?}"
echo "  screenshots: $SHOT"
if [[ $fail -eq 0 ]]; then echo "  STAGE C PASSED"; else echo "  STAGE C: $fail FAILURE(S)"; exit 1; fi
