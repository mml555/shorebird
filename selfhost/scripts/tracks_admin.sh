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
    # Which channels to report as absent comes from CHANNELS, because the
    # channel that must be EMPTY differs per arm: the tracks arm needed beta
    # absent, this one needs stable absent. A hardcoded pair silently reported
    # the wrong channel and would have left "stable: ABSENT" unevidenced.
    import os
    for want in os.environ.get("CHANNELS", "alpha beta").split():
        got = [x for x in deps if x.get("channel") == want]
        if not got:
            print("    {}: ABSENT (no deployment row at all)".format(want))
'
  ;;
fetch-release-app)
  # WHY THIS EXISTS. `shorebird patch` overwrites build/ios/archive with the
  # PATCH build, so after publishing a patch the local archive is no longer the
  # release. Installing it would put the patched code on the device directly and
  # every later reading would be meaningless -- and it would not even be caught
  # by a bind failure, because the engine compares the container's `built-for`
  # against the RUNNING release. So the release artifact is fetched from the
  # server, which is the only copy that is definitionally the release.
  RID=$(api GET "/api/v1/apps/$APP/releases" | python3 -c '
import json,sys,os
d=json.load(sys.stdin)
rows=d if isinstance(d,list) else (d.get("releases") or [])
rel=os.environ["REL"]
for r in rows:
    if r.get("version")==rel: print(r["id"]); break
')
  [ -n "$RID" ] || { echo "no release $REL"; exit 1; }
  URL=$(api GET "/api/v1/apps/$APP/releases/$RID/artifacts" | python3 -c '
import json,sys
d=json.load(sys.stdin)
rows=d if isinstance(d,list) else (d.get("artifacts") or [])
for a in rows:
    if a.get("arch")=="xcarchive":
        print(a.get("url") or a.get("download_url") or "")
        break
')
  [ -n "$URL" ] || { echo "no xcarchive artifact on release $RID"; exit 1; }
  OUT=${OUT:-/tmp/release_app}
  rm -rf "$OUT"; mkdir -p "$OUT"
  echo "release $REL -> id $RID"
  echo "fetching xcarchive…"
  curl -sSL -H "Authorization: Bearer $SHOREBIRD_TOKEN" "$URL" -o "$OUT/xcarchive.zip"
  ( cd "$OUT" && unzip -q xcarchive.zip )
  APPDIR=$(find "$OUT" -name 'Runner.app' -maxdepth 5 -type d | head -1)
  [ -n "$APPDIR" ] || { echo "no Runner.app inside the fetched xcarchive"; exit 1; }
  echo "app: $APPDIR"
  echo "this is the RELEASE, fetched from the server rather than rebuilt:"
  strings -a "$APPDIR/Frameworks/App.framework/App" \
    | grep -cE '^MANUAL-V1$|MANUAL-V1' | sed 's/^/  MANUAL-V1 occurrences: /'
  strings -a "$APPDIR/Frameworks/App.framework/App" \
    | grep -c 'MANUAL-V2' | sed 's/^/  MANUAL-V2 occurrences (must be 0): /'
  ;;
*) echo "unknown subcommand: $1"; exit 2;;
esac
