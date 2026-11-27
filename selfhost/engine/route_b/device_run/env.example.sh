#!/usr/bin/env bash
# shellcheck disable=SC2155
# Copy to env.sh (git-ignored), fill in every REPLACE_ME, and keep env.sh and
# secrets.sh out of version control. Every script in bin/ sources env.sh, or the
# file named by DEVRUN_ENV.

# --- Required: you must set these. A REPLACE_ME value stops the script. ---
export R=REPLACE_ME                  # work dir for logs, work/, data/, signed/. Keep it outside the repo.
export CLI=REPLACE_ME                # checkout of this repo whose bin/shorebird is the CLI under test
export UDID=REPLACE_ME               # iPhone UDID (idevice_id -l)
export BASE=REPLACE_ME               # control-plane URL the phone and the CLI reach, e.g. http://<mac-lan-ip>:18290
export ARTIFACT_UPSTREAM=REPLACE_ME  # real artifact CDN that origin.py forwards to, e.g. http://<host>:8085
export ENGINE_REV=REPLACE_ME         # supported cell address: lineage.cell_address in SUPPORTED_STATE.yaml
export FLUTTER_REV=REPLACE_ME        # lineage.flutter_selector in SUPPORTED_STATE.yaml
export SIGN_IDENTITY=REPLACE_ME      # codesign identity (SHA-1 from `security find-identity -v -p codesigning`)
export PROVISIONING_PROFILE=REPLACE_ME  # path to the .mobileprovision for $BUNDLE
export TEAM_ID=REPLACE_ME            # Apple developer team id

# --- Optional: defaults shown. ---
export BUNDLE="${BUNDLE:-dev.selfhost.untab}"
export VERSION="${VERSION:-1.0.0+33}"          # release version (version+build) the shapes app is built with
export SECRETS_FILE="${SECRETS_FILE:-$R/secrets.sh}"  # must export API_KEY and URL_SIGNING_SECRET
export ORIGIN_PORT="${ORIGIN_PORT:-18185}"
export PROXY_PORT="${PROXY_PORT:-18188}"
export SERVER_PORT="${SERVER_PORT:-18290}"
export NO_PROXY_HOSTS="${NO_PROXY_HOSTS:-localhost,127.0.0.1}"  # add the artifact upstream and Mac LAN hosts
export EXTRA_PATH="${EXTRA_PATH:-/opt/homebrew/bin}"           # where ios-deploy and libimobiledevice live
export KEYS_DIR="${KEYS_DIR:-$R/keys}"  # patch signing pair; release.sh creates private.pem/public.pem here if missing

# --- Checks and derived values. No edits needed below. ---
for v in R CLI UDID BASE ARTIFACT_UPSTREAM ENGINE_REV FLUTTER_REV SIGN_IDENTITY PROVISIONING_PROFILE TEAM_ID; do
  eval "val=\${$v:-}"
  if [ -z "$val" ] || [ "$val" = REPLACE_ME ]; then
    echo "env.sh: $v is not set; edit env.sh (see env.example.sh)" >&2
    return 1 2>/dev/null || exit 1
  fi
done
FLUTTER_DIR="$CLI/bin/cache/flutter/$FLUTTER_REV"
[ "$R" != / ] && [ -d "$R" ] || { echo "env.sh: ""R=$R must be an existing directory, dedicated to this harness (release.sh deletes $R/work and $R/signed)" >&2; return 1 2>/dev/null || exit 1; }
[ -d "$CLI" ] && [ -x "$CLI/bin/shorebird" ] || { echo "env.sh: ""CLI=$CLI must be a repo checkout with bin/shorebird" >&2; return 1 2>/dev/null || exit 1; }
[ -f "$PROVISIONING_PROFILE" ] || { echo "env.sh: ""PROVISIONING_PROFILE=$PROVISIONING_PROFILE is not a file" >&2; return 1 2>/dev/null || exit 1; }
# up.sh fills the Flutter cache (its bootstrap runs through the recording origin), so it sources this file
# with DEVRUN_BOOTSTRAP=1 and checks the cache itself afterwards.
[ -d "$FLUTTER_DIR" ] || [ "${DEVRUN_BOOTSTRAP:-0}" = 1 ] || { echo "env.sh: ""$FLUTTER_DIR is missing. Run bin/up.sh first (it fills the cache); if it is already up, check FLUTTER_REV" >&2; return 1 2>/dev/null || exit 1; }
case "$BASE" in *:"$SERVER_PORT"|*:"$SERVER_PORT"/*) ;; *) echo "env.sh: BASE=$BASE must carry the port SERVER_PORT=$SERVER_PORT" >&2; return 1 2>/dev/null || exit 1 ;; esac
if [ ! -f "$SECRETS_FILE" ]; then
  echo "env.sh: SECRETS_FILE $SECRETS_FILE not found; it must export API_KEY and URL_SIGNING_SECRET" >&2
  return 1 2>/dev/null || exit 1
fi
# shellcheck disable=SC1090
. "$SECRETS_FILE"
for v in API_KEY URL_SIGNING_SECRET; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || { echo "env.sh: $v missing from $SECRETS_FILE" >&2; return 1 2>/dev/null || exit 1; }
done

[ -n "$EXTRA_PATH" ] && export PATH="$EXTRA_PATH:$PATH"
export HTTPS_PROXY="http://127.0.0.1:$PROXY_PORT" HTTP_PROXY="http://127.0.0.1:$PROXY_PORT"
NO_PROXY_UP="$(echo "$ARTIFACT_UPSTREAM" | sed -E 's#^[a-z]+://##; s#[:/].*##'),$(echo "$BASE" | sed -E 's#^[a-z]+://##; s#[:/].*##')"
export NO_PROXY="${NO_PROXY_HOSTS:+$NO_PROXY_HOSTS,}127.0.0.1,localhost,$NO_PROXY_UP"
export JAVA_TOOL_OPTIONS="-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=$PROXY_PORT -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=$PROXY_PORT -Dhttp.nonProxyHosts=localhost|127.*"
export SHOREBIRD_ARTIFACT_ORIGIN="http://127.0.0.1:$ORIGIN_PORT" FLUTTER_STORAGE_BASE_URL="http://127.0.0.1:$ORIGIN_PORT"
export CI=true LANG=en_US.UTF-8
export SB="$CLI/bin/shorebird"
export FLUTTER_DIR
export FLUTTER="$FLUTTER_DIR/bin/flutter"
export SHOREBIRD_HOSTED_URL="$BASE" SHOREBIRD_TOKEN="$API_KEY"
mkdir -p "$R/logs" "$R/shots"
