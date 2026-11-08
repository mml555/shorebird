#!/usr/bin/env bash
# cspell:words getsockname noninteractive chardev nonint armeabi OPORT dists noflag devnull cred wrongshape derivable nomatch ident sel conf
# CI-NONINTERACTIVE-1 gate 1b: the interaction surface, with INDEPENDENT arms.
#
# The first pass got one real result and two worthless ones: arm 1 created
# release 1.0.0+1, so arms 2 and 3 failed on "you have an existing android
# release for version 1.0.0+1" rather than on anything to do with stdin or the
# confirmation flag. Arms that mutate shared state are not arms. Every release
# arm here uses its OWN version, so none can be spoiled by another.
#
# Still measurement. Nothing in the CLI is changed by this script.
set -uo pipefail
source /Volumes/build/ci1/ci1.env
CLONE="$B/shorebird"
SEL=5b180d224df04a267a19888c3f344474e243b382
RUNTIME="$B/runtime"
SB="$RUNTIME/bin/shorebird"
PROFILE=/Volumes/build/cleanroom2/cleanroom.sb
CR_HOME=/Volumes/build/cleanroom2/home
LOG="$W/logs"; mkdir -p "$LOG"
OP_ANDROID_HOME=${OP_ANDROID_HOME:-$HOME/Library/Android/sdk}
OP_JAVA_HOME=${OP_JAVA_HOME:-$(/usr/libexec/java_home 2>/dev/null)}
OP_GRADLE_HOME=$W/gradle
INV="$W/inventory_1b.txt"; : > "$INV"
step(){ printf '\n\033[1m== %s\033[0m\n' "$1"; }
inv(){ printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$INV"; }

ver(){ sed -i '' "s/^version: .*/version: $1/" "$APP/pubspec.yaml"; }

arm() {
  local name=$1 mode=$2; shift 2
  local rc
  local -a env=(
    PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$CR_HOME" TMPDIR="$W/tmp"
    LANG=en_US.UTF-8 TERM=dumb CI=true
    SHOREBIRD_ARTIFACT_ORIGIN="$ORIGIN" FLUTTER_STORAGE_BASE_URL="$ORIGIN"
    SHOREBIRD_HOSTED_URL="$BASE" SHOREBIRD_TOKEN="$API_KEY"
    ANDROID_HOME="$OP_ANDROID_HOME" ANDROID_SDK_ROOT="$OP_ANDROID_HOME"
    JAVA_HOME="$OP_JAVA_HOME" GRADLE_USER_HOME="$OP_GRADLE_HOME"
  )
  if [[ "$mode" == closed ]]; then
    ( cd "$APP" && sandbox-exec -f "$PROFILE" /usr/bin/env -i "${env[@]}" \
        /bin/bash "$SB" "$@" ) > "$LOG/$name.log" 2>&1 0<&-
    rc=$?
  else
    ( cd "$APP" && sandbox-exec -f "$PROFILE" /usr/bin/env -i "${env[@]}" \
        /bin/bash "$SB" "$@" ) > "$LOG/$name.log" 2>&1 < /dev/null
    rc=$?
  fi
  printf '  %-24s stdin=%-7s exit=%-3s %s\n' "$name" "$mode" "$rc" \
    "$(grep -m1 -oiE 'Published (Release|Patch) [^!]*|existing android release|Input was required[^:]*|not specified' "$LOG/$name.log" | cut -c1-46)"
  echo "$rc"
}
mkdir -p "$W/tmp"

step "1 - CONFIRMATION: is a mutation approved without an explicit flag?"
# release_command.dart:647 reads
#   if (confirm && shorebirdEnv.canAcceptUserInput) { logger.confirm(...) }
# so when canAcceptUserInput is false the confirmation is SKIPPED and the
# mutation proceeds. Measured here on its own version so nothing else can
# explain the result.
ver 2.0.0+1
r=$(arm conf_noflag closed release android --artifact apk)
inv confirmation "conf_noflag" "$r" "stdin CLOSED, no --no-confirm: does it approve itself?"
ver 2.1.0+1
r=$(arm conf_flag closed release android --artifact apk --no-confirm)
inv confirmation "conf_flag" "$r" "stdin CLOSED, --no-confirm: the candidate mechanism"
ver 2.2.0+1
r=$(arm conf_devnull devnull release android --artifact apk)
inv confirmation "conf_devnull" "$r" "stdin=/dev/null, no flag: CONTRAST only"

step "2 - SELECTION: the chooser, with ambiguity it cannot shortcut"
# patch_command.dart:400-415: one release short-circuits; an explicit
# --release-version is used; interactive prompts; and NON-INTERACTIVE falls to
# an else branch that BUILDS to derive the version. Which of those fires is the
# whole of gate 3, so the state is arranged to make the shortcut impossible.
n=$(curl -fsS "$BASE/api/v1/apps/$APP_ID/releases" -H "Authorization: Bearer $API_KEY" \
     | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["releases"]))')
echo "    releases now on the control plane: $n"
ver 2.1.0+1
r=$(arm sel_derivable closed patch android --no-confirm)
inv release_selection "sel_derivable" "$r" "no --release-version; pubspec 2.1.0+1 HAS a release"
ver 9.9.9+1
r=$(arm sel_nomatch closed patch android --no-confirm)
inv release_selection "sel_nomatch" "$r" "no --release-version; pubspec 9.9.9+1 has NO release"
ver 2.1.0+1
r=$(arm sel_explicit closed patch android --no-confirm --release-version 2.1.0+1)
inv release_selection "sel_explicit" "$r" "explicit --release-version: the deterministic form"

step "3 - APP IDENTITY: what happens with no app_id at all"
cp "$APP/shorebird.yaml" "$W/shorebird.yaml.bak"
printf 'base_url: %s\n' "$BASE" > "$APP/shorebird.yaml"
r=$(arm ident_missing closed patch android --no-confirm --release-version 2.1.0+1)
inv app_selection "ident_missing" "$r" "shorebird.yaml with NO app_id"
cp "$W/shorebird.yaml.bak" "$APP/shorebird.yaml"

step "4 - CREDENTIALS: missing and invalid, and where they fail"
for spec in "cred_missing:" "cred_garbage:not-a-key" "cred_wrongshape:sb_api_deadbeef"; do
  nm=${spec%%:*}; tok=${spec#*:}
  ( cd "$APP" && sandbox-exec -f "$PROFILE" /usr/bin/env -i \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$CR_HOME" TMPDIR="$W/tmp" \
      LANG=en_US.UTF-8 TERM=dumb CI=true \
      SHOREBIRD_ARTIFACT_ORIGIN="$ORIGIN" FLUTTER_STORAGE_BASE_URL="$ORIGIN" \
      SHOREBIRD_HOSTED_URL="$BASE" ${tok:+SHOREBIRD_TOKEN="$tok"} \
      ANDROID_HOME="$OP_ANDROID_HOME" JAVA_HOME="$OP_JAVA_HOME" \
      GRADLE_USER_HOME="$OP_GRADLE_HOME" \
      /bin/bash "$SB" patch android --no-confirm --release-version 2.1.0+1 ) \
    > "$LOG/$nm.log" 2>&1 0<&-
  rc=$?
  # Did it refuse BEFORE mutating? A build starting is the tell.
  built=$(grep -c "Building" "$LOG/$nm.log" || true)
  printf '  %-24s exit=%-3s built=%-3s %s\n' "$nm" "$rc" "$built" \
    "$(grep -m1 -oiE 'Failed to (parse|refresh)[^.]*|You must be logged in|Missing[^.]*' "$LOG/$nm.log" | cut -c1-44)"
  inv authentication "$nm" "$rc" "token='${tok:-<unset>}'; build attempts=$built"
done

step "5 - THE SECRET must not appear in any captured output"
hits=$(grep -rlF "$API_KEY" "$LOG" 2>/dev/null | wc -l | tr -d ' ')
echo "    log files containing the literal token: $hits"
if [[ "$hits" != 0 ]]; then
  grep -rlF "$API_KEY" "$LOG" | sed 's/^/      LEAKED IN: /'
fi
inv secret "token_in_logs" "$hits" "must be 0"

step "RESULT"
column -t -s'|' "$INV" 2>/dev/null | sed 's/^/    /' || cat "$INV"
echo
echo "  logs: $LOG"
