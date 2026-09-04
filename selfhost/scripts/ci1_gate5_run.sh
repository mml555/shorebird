#!/usr/bin/env bash
# cspell:words getsockname noninteractive armeabi OPORT nonint RELVER newchannel settrack reqs
# CI-NONINTERACTIVE-1 gate 5: one clean unattended run, stdin closed throughout.
#
#   bootstrap-provided CLI -> authenticate -> release -> second source revision
#   -> patch -> promote
#
# fd 0 is closed for EVERY CLI invocation (0<&-), not redirected from
# /dev/null: Dart reports a character device as a terminal, so /dev/null leaves
# the CLI believing it can prompt. stdout and stderr are always files.
#
# The certified mechanisms, all explicit:
#   credential     SHOREBIRD_TOKEN (sb_api_ key)
#   app            shorebird.yaml app_id
#   release target --release-version on patch/promote
#   confirmation   --no-confirm
#   track          --track
set -uo pipefail
source /Volumes/build/ci1/ci1.env
B=${B:-/Volumes/build/cleanroom2/boot}
CLONE="$B/shorebird"
RUNTIME="$B/runtime"
SEL=5b180d224df04a267a19888c3f344474e243b382
CELL=f85251f344600ae08196925a174e9cff8f0ff18e
SB="$RUNTIME/bin/shorebird"
FLUTTER="$RUNTIME/bin/cache/flutter/$SEL/bin/flutter"
PROFILE=/Volumes/build/cleanroom2/cleanroom.sb
CR_HOME=/Volumes/build/cleanroom2/home
G=$W/gate5; rm -rf "$G"; mkdir -p "$G/logs" "$G/tmp"
LOG="$G/logs"
OP_AH=${OP_AH:-$HOME/Library/Android/sdk}
OP_JH=${OP_JH:-$(/usr/libexec/java_home 2>/dev/null)}
fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
step(){ printf '\n\033[1m== %s\033[0m\n' "$1"; }
BANK="$G/bank.txt"; : > "$BANK"
bank(){ printf '%-28s %s\n' "$1" "$2" >> "$BANK"; }

APP5="$G/app"
cli() { # name -- args...   ALWAYS fd 0 closed
  local nm=$1; shift
  ( cd "$APP5" && sandbox-exec -f "$PROFILE" /usr/bin/env -i \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$CR_HOME" TMPDIR="$G/tmp" \
      LANG=en_US.UTF-8 TERM=dumb CI=true \
      SHOREBIRD_ARTIFACT_ORIGIN="$ORIGIN" FLUTTER_STORAGE_BASE_URL="$ORIGIN" \
      SHOREBIRD_HOSTED_URL="$BASE" SHOREBIRD_TOKEN="$API_KEY" \
      ANDROID_HOME="$OP_AH" ANDROID_SDK_ROOT="$OP_AH" JAVA_HOME="$OP_JH" \
      GRADLE_USER_HOME="$W/gradle" \
      /bin/bash "$SB" "$@" ) > "$LOG/$nm.log" 2>&1 0<&-
  local rc=$?
  bank "exit:$nm" "$rc"
  printf '  %-20s exit=%-3s %s\n' "$nm" "$rc" \
    "$(grep -m1 -oiE 'Published (Release|Patch)[^!]*|Promoted[^.]*|Input was required[^:]*' "$LOG/$nm.log" | cut -c1-44)"
  return $rc
}

step "0 - the identities this run is against"
bank tag "$(git -C "$CLONE" describe --tags 2>/dev/null || echo '<detached>')"
bank cli_revision "$(git -C "$RUNTIME" rev-parse HEAD)"
bank flutter_selector "$SEL"
bank cell "$CELL"
bank flutter_version "$(git -C "$RUNTIME/bin/cache/flutter/$SEL" describe --match '*.*.*' --first-parent --long --tags 2>/dev/null)"
sed 's/^/    /' "$BANK"

step "1 - a throwaway app, and a fresh app record"
( cd "$G" && HOME="$CR_HOME" "$FLUTTER" create --org dev.selfhost.ci5 --platforms=android app ) > "$LOG/create.log" 2>&1
grep -qiE "Failed to update packages|version solving failed" "$LOG/create.log" \
  && { bad "flutter create's pub get failed"; tail -4 "$LOG/create.log"; } \
  || ok "flutter create succeeded, including pub get"
cat > "$APP5/lib/main.dart" <<'DART'
import 'package:flutter/material.dart';

@pragma('vm:never-inline')
@pragma('vm:entry-point')
String markerText() => DateTime.now().millisecondsSinceEpoch >= 0
    ? 'CI1-V1-RELEASE'
    : 'CI1-V1-RELEASE!';

void main() => runApp(const MarkerApp());

class MarkerApp extends StatelessWidget {
  const MarkerApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(body: Center(child: Text(markerText()))),
  );
}
DART
APP5_ID=$(curl -fsS -X POST "$BASE/api/v1/apps" -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' -d '{"display_name":"ci-noninteractive-1-gate5"}' \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
printf 'app_id: %s\nbase_url: %s\n' "$APP5_ID" "$BASE" > "$APP5/shorebird.yaml"
python3 "$CLONE/selfhost/scripts/lib/add_shorebird_asset.py" "$APP5/pubspec.yaml" >/dev/null 2>&1 || true
bank app_id "$APP5_ID"
ok "app_id $APP5_ID"

step "2 - doctor --fix supplies the INTERNET permission, unattended"
cli doctor doctor --fix || true
grep -qE "INTERNET" "$APP5/android/app/src/main/AndroidManifest.xml" \
  && ok "INTERNET permission present" || bad "manifest not fixed"

step "3 - RELEASE, stdin closed, explicit --no-confirm"
cli release release android --artifact apk --no-confirm && ok "release exited 0" || bad "release failed"
REL=$(curl -fsS "$BASE/api/v1/apps/$APP5_ID/releases" -H "Authorization: Bearer $API_KEY" \
  | python3 -c 'import json,sys;r=json.load(sys.stdin)["releases"];print(r[0]["id"] if r else "")')
RELVER=$(curl -fsS "$BASE/api/v1/apps/$APP5_ID/releases" -H "Authorization: Bearer $API_KEY" \
  | python3 -c 'import json,sys;r=json.load(sys.stdin)["releases"];print(r[0]["version"] if r else "")')
bank release_id "$REL"; bank release_version "$RELVER"
[[ -n "$REL" ]] && ok "release id $REL ($RELVER)" || bad "no release recorded"
curl -fsS "$BASE/api/v1/apps/$APP5_ID/releases/$REL/artifacts" -H "Authorization: Bearer $API_KEY" \
  > "$G/release_artifacts.json"
python3 - "$G/release_artifacts.json" "$BANK" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
arts = d.get('artifacts', d if isinstance(d, list) else [])
with open(sys.argv[2], 'a') as b:
    for a in arts:
        b.write('%-28s %s\n' % ('release_artifact:%s' % a.get('arch'),
                                '%s %s' % (a.get('size'), a.get('hash'))))
print('    release artifacts banked: %d' % len(arts))
PY

step "4 - a SECOND SOURCE REVISION, then the patch, published to a track"
sed -i '' "s/CI1-V1-RELEASE/CI1-V2-PATCHED/g" "$APP5/lib/main.dart"
grep -q "CI1-V2-PATCHED" "$APP5/lib/main.dart" && ok "source changed to the patched marker" \
                                               || bad "source edit did not land"
# `patch --track <name>` publishes AND assigns the track, auto-creating the
# channel. This is the promotion mechanism that works unattended; the audit
# records it as channel.create + patch.promote.
cli patch patch android --no-confirm --release-version "$RELVER" --track stable \
  && ok "patch exited 0, published to stable" || bad "patch failed"
curl -fsS "$BASE/api/v1/apps/$APP5_ID/releases/$REL/patches" -H "Authorization: Bearer $API_KEY" \
  > "$G/patches.json"
python3 - "$G/patches.json" "$BANK" <<'PY1'
import json, sys
d = json.load(open(sys.argv[1]))
with open(sys.argv[2], 'a') as b:
    for p in d.get('patches', []):
        b.write('%-28s %s\n' % ('patch', 'id=%s number=%s status=%s channel=%s'
                % (p['id'], p['number'], p['status'], p['channel'])))
        for a in p.get('artifacts', []):
            b.write('%-28s %s\n' % ('patch_artifact:%s' % a['arch'],
                                    '%s %s' % (a['size'], a['hash'])))
n = len(d.get('patches', []))
print('    patches banked: %d' % n)
sys.exit(0 if n >= 1 else 1)
PY1
[[ $? -eq 0 ]] && ok "a patch is recorded" || bad "no patch recorded"
P1=$(python3 -c 'import json;print(json.load(open("'"$G"'/patches.json"))["patches"][0]["number"])' 2>/dev/null)
C1=$(python3 -c 'import json;print(json.load(open("'"$G"'/patches.json"))["patches"][0]["channel"])' 2>/dev/null)
[[ "$C1" == stable ]] && ok "patch $P1 is live on stable, unattended" || bad "channel is '$C1'"

step "5 - MOVING a patch between tracks, and the one case that refuses"
# A THIRD source revision, so patch 2 is genuinely different code.
sed -i '' "s/CI1-V2-PATCHED/CI1-V3-SECOND/g" "$APP5/lib/main.dart"
cli patch2 patch android --no-confirm --release-version "$RELVER" --track beta \
  && ok "patch 2 exited 0, published to beta" || bad "second patch failed"
P2=$(curl -fsS "$BASE/api/v1/apps/$APP5_ID/releases/$REL/patches" -H "Authorization: Bearer $API_KEY" \
     | python3 -c 'import json,sys;ps=json.load(sys.stdin)["patches"];print(max(p["number"] for p in ps))')
bank patch2_number "$P2"

# set-track to an EXISTING channel: stable exists because patch 1 created it.
cli settrack patches set-track --release "$RELVER" --patch "$P2" --track stable \
  && ok "set-track to an EXISTING channel exited 0" || bad "set-track failed"
TRK=$(curl -fsS "$BASE/api/v1/apps/$APP5_ID/releases/$REL/patches" -H "Authorization: Bearer $API_KEY" \
      | python3 -c 'import json,sys
ps=json.load(sys.stdin)["patches"]
print([p["channel"] for p in ps if p["number"]=='"$P2"'][0])')
bank patch2_channel_after_settrack "$TRK"
[[ "$TRK" == stable ]] && ok "patch $P2 moved beta -> stable, unattended" \
                       || bad "patch $P2 channel is '$TRK', not stable"

# THE DOCUMENTED LIMIT, asserted rather than assumed. set-track cannot CREATE a
# channel unattended: it asks "No channel named X found. Do you want to create
# it?" and its own hint says it has no flag to skip that. It refuses -- which is
# the right failure -- and this control pins that behaviour so a future change
# cannot turn it into a silent auto-create.
cli settrack_newchannel patches set-track --release "$RELVER" --patch "$P2" --track ci1-nonexistent
rc=$?
if [[ "$rc" != 0 ]] && grep -q "No channel named ci1-nonexistent found" "$LOG/settrack_newchannel.log"; then
  ok "set-track REFUSES to create a channel unattended (exit $rc), naming the prompt"
else
  bad "set-track did not refuse for the expected reason (exit $rc)"
fi
bank exit_settrack_new_channel "$rc"

# And a missing mandatory target must be refused by the parser itself.
cli settrack_missing patches set-track --release "$RELVER" --track stable
rc=$?
[[ "$rc" != 0 ]] && ok "omitting a mandatory target refuses (exit $rc), it does not ask" \
                 || bad "a missing mandatory target did not refuse"

step "6 - the audit trail attributes every mutation to the credential"
# FILTERED SERVER-SIDE. `?limit=80` returns the OLDEST 80 rows, so on a control
# plane with history the run's own events fall outside the window -- a first
# pass reported "audit events for this app: 0" against 25 that existed.
curl -fsS "$BASE/admin/audit?app_id=$APP5_ID&limit=200" -H "Authorization: Bearer $API_KEY" > "$G/audit.json"
API_KEY="$API_KEY" python3 - "$G/audit.json" "$BANK" "$APP5_ID" <<'PY'
import json, os, sys
ev = json.load(open(sys.argv[1]))['events']
mine = [e for e in ev if e.get('app_id') == sys.argv[3]]
key = os.environ['API_KEY']
creds = sorted({str(e.get('actor_credential')) for e in mine})
reqs = [e.get('request_id') for e in mine if e.get('request_id')]
raw = any(key in json.dumps(e) for e in mine)
with open(sys.argv[2], 'a') as b:
    b.write('%-28s %s\n' % ('audit_events', len(mine)))
    b.write('%-28s %s\n' % ('audit_actor_credential', ','.join(creds)))
    b.write('%-28s %s\n' % ('audit_raw_token_present', raw))
    for e in mine:
        b.write('%-28s %s\n' % ('audit:%s' % e['operation'],
                '%s %s req=%s' % (e['result'], e['http_status'], e.get('request_id'))))
print('    audit events for this app: %d' % len(mine))
print('    actor_credential (a FINGERPRINT, not the key): %s' % ', '.join(creds))
print('    request ids captured: %d of %d' % (len(reqs), len(mine)))
print('    the raw token appears in an audit row: %s' % raw)
# Every mutation attributed to exactly one credential, every row carrying a
# request id, and the secret itself never stored.
sys.exit(0 if mine and len(creds) == 1 and len(reqs) == len(mine) and not raw else 1)
PY
[[ $? -eq 0 ]] && ok "every mutation carries one credential fingerprint and a request id, and the key is never stored" \
               || bad "audit attribution incomplete"

step "7 - stdin was never usable, and the secret never printed"
# The CLI cannot have read stdin: fd 0 was closed for every invocation. Prove
# the CLI SAW it that way rather than trusting the shell.
grep -rlF "$API_KEY" "$LOG" 2>/dev/null | sed 's/^/      LEAKED: /'
hits=$(grep -rlF "$API_KEY" "$LOG" 2>/dev/null | wc -l | tr -d ' ')
bank secret_in_logs "$hits"
[[ "$hits" == 0 ]] && ok "the token appears in 0 captured log files" || bad "the token leaked into $hits file(s)"
# Scoped to the CERTIFIED path. settlement of a NEW channel is a deliberate
# refusal arm, so its log is expected to contain the prompt text; counting it
# would make this control fail for doing its job.
pr=$(grep -rlE "Input was required for the following prompt" "$LOG" 2>/dev/null \
     | grep -v "settrack_newchannel" | wc -l | tr -d ' ')
bank interactive_prompts_hit "$pr"
[[ "$pr" == 0 ]] && ok "no invocation on the certified path hit an interactive prompt" \
                 || { bad "$pr invocation(s) hit a prompt"; grep -rlE "Input was required" "$LOG" | sed 's/^/      /'; }

step "RESULT"
sed 's/^/    /' "$BANK"
echo
if [[ $fail -eq 0 ]]; then echo "  GATE 5 PASSED — unattended release, patch and promote"; else
  echo "  GATE 5: $fail FAILURE(S)"; exit 1; fi
