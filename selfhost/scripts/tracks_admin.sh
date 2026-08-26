#!/usr/bin/env bash
# cspell:words deployments
#
# tracks_admin.sh -- the authenticated half of the P6 tracks arm.
#
# Separated from the observation half so the token is needed only here, and so
# every assertion about server state is made against `deployments` rather than
# the convenience `channel` field. `api.dart:1601-1637` is explicit that one
# patch may be live on several tracks and that `deployments` is the authoritative
# representation; a singular field cannot express "alpha yes, beta no".
#
# Requires SHOREBIRD_TOKEN (an sb_api_ key). Subcommands:
#   channels   create alpha and beta, then ASSERT both exist
#   state      print every patch on the release with its full deployments list
set -euo pipefail

APP=${APP:-1c99c679-8650-ba82-3899-681349a59416}
BASE=${BASE:-http://10.0.0.7:18080}
REL=${REL:-1.10.0+1}
# Which channels `channels` creates and asserts. Overridable because channels are
# PER-APP: a second fixture with its own app_id starts with none of them, and an
# unknown channel yields an empty patch-check response (api.dart:2008) -- so a
# negative taken against a channel that was never created cannot fail.
CHANNELS=${CHANNELS:-"alpha beta"}
export REL CHANNELS   # read by the python readers below, which run as child processes
: "${SHOREBIRD_TOKEN:?set SHOREBIRD_TOKEN to an sb_api_ key}"

api() { # <method> <path> [body]
  local m=$1 p=$2 b=${3:-}
  if [ -n "$b" ]; then
    curl -sS -X "$m" -H "Authorization: Bearer $SHOREBIRD_TOKEN" \
      -H 'Content-Type: application/json' -d "$b" "$BASE$p"
  else
    curl -sS -X "$m" -H "Authorization: Bearer $SHOREBIRD_TOKEN" "$BASE$p"
  fi
}

case ${1:-state} in
channels)
  # WHY THIS EXISTS AT ALL. api.dart:2008 returns an empty response when the
  # requested channel does not exist. So a client on a channel that was never
  # created receives nothing REGARDLESS of any deployment -- a negative result
  # that cannot fail and certifies nothing. Creating both up front makes every
  # later withholding a deployment decision.
  for ch in $CHANNELS; do
    api POST "/api/v1/apps/$APP/channels" "{\"channel\":\"$ch\"}" >/dev/null
  done
  echo "channels on $APP:"
  api GET "/api/v1/apps/$APP/channels" | python3 -c '
import json,sys
d=json.load(sys.stdin)
# The channels endpoint returns a BARE list of {id,app_id,name} (api.dart:1711),
# while releases/patches are wrapped. Tolerate both rather than assume.
rows=d if isinstance(d,list) else (d.get("channels") or [])
names=[c["name"] if isinstance(c,dict) else str(c) for c in rows]
for n in sorted(names): print(f"  {n}")
import os
want=os.environ.get("CHANNELS","alpha beta").split()
missing=[c for c in want if c not in names]
print()
if missing:
    print(f"  ASSERTION FAILED: missing {missing} -- the negative arm would be vacuous")
    sys.exit(1)
print("  ASSERTION OK: " + ", ".join(want) + " all exist, so withholding can only be a deployment decision")
'
  ;;
state)
  RID=$(api GET "/api/v1/apps/$APP/releases" | python3 -c '
import json,sys,os
d=json.load(sys.stdin)
rel=os.environ["REL"]
rows=d if isinstance(d,list) else (d.get("releases") or [])
for r in rows:
    if r.get("version")==rel: print(r["id"]); break
' )
  [ -n "$RID" ] || { echo "no release $REL"; exit 1; }
  echo "release $REL -> id $RID"
  api GET "/api/v1/apps/$APP/releases/$RID/patches" | python3 -c '
import json,sys
d=json.load(sys.stdin)
ps=d if isinstance(d,list) else (d.get("patches") or [])
if not ps:
    print("  (no patches yet)")
for p in ps:
    num=p.get("number"); st=p.get("status"); conv=p.get("channel")
    print("  patch {}  status={}  convenience channel={!r}".format(num,st,conv))
    deps=p.get("deployments") or []
    if not deps:
        print("    deployments: NONE  <-- authoritative: live on no track")
    # Liveness is `status` compared against ChannelPatchStatus.active.name, with
    # `rolled_back` as a separate veto (api.dart:_currentTrack). There is no
    # "active" key -- reading one printed None and looked like "not active".
    for x in deps:
        live = x.get("status") == "active" and x.get("rolled_back") is not True
        print("    deployment: channel={} status={} rolled_back={} rollout={}  -> {}".format(
            x.get("channel"), x.get("status"), x.get("rolled_back"), x.get("rollout"),
            "LIVE" if live else "not live"))
    for want in ("alpha", "beta"):
        got = [x for x in deps if x.get("channel") == want]
        if not got:
            print("    {}: ABSENT (no deployment row at all)".format(want))
'
  ;;
*) echo "unknown subcommand: $1"; exit 2;;
esac
