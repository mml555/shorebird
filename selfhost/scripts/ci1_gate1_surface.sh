#!/usr/bin/env bash
# cspell:words getsockname noninteractive chardev nonint armeabi OPORT
# CI-NONINTERACTIVE-1 gate 1: what does the ordinary workflow ASK FOR when
# nothing can answer?
#
# MEASUREMENT ONLY. Nothing is patched here. Every arm runs the real commands
# with a hostile stdio shape and records exactly where they block or ask, so the
# unattended contract is decided from an inventory rather than by silencing
# whatever appeared first.
#
# STDIN CLOSED MEANS CLOSED. `< /dev/null` is NOT closed: Dart classifies stdin
# by st_mode and /dev/null is a CHARACTER DEVICE, which it reports as
# StdioType.terminal -- so `stdin.hasTerminal` is TRUE and the CLI believes it
# can prompt. This fork measured that on 2026-08-14
# (evidence/g10.2-noninteractive/STDIN_CHARDEV_2026-08-14.txt). Both shapes are
# run here BECAUSE they differ, and the difference is part of the surface:
#   0<&-          fd 0 closed        what `docker run` without -i gives you
#   < /dev/null   chardev            what most shell scripts write by habit
set -uo pipefail
B=${B:-/Volumes/build/cleanroom2/boot}
W=${W:-/Volumes/build/ci1}
PROFILE=${PROFILE:-/Volumes/build/cleanroom2/cleanroom.sb}
CR_HOME=${CR_HOME:-/Volumes/build/cleanroom2/home}
SEL=5b180d224df04a267a19888c3f344474e243b382
CELL=f85251f344600ae08196925a174e9cff8f0ff18e
CLONE="$B/shorebird"
RUNTIME="$B/runtime"
DART="$RUNTIME/bin/cache/flutter/$SEL/bin/cache/dart-sdk/bin/dart"
FLUTTER="$RUNTIME/bin/cache/flutter/$SEL/bin/flutter"
SB="$RUNTIME/bin/shorebird"
rm -rf "$W"; mkdir -p "$W/logs"
LOG="$W/logs"
step(){ printf '\n\033[1m== %s\033[0m\n' "$1"; }
note(){ printf '  %s\n' "$1"; }
INV="$W/inventory.txt"; : > "$INV"
inv(){ printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$INV"; }

step "0 - the services an unattended job needs, from the TAG's own tree"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
OPORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
API_KEY="sb_api_ci1_$(date +%s)"
BASE="http://localhost:$PORT"
ORIGIN="http://127.0.0.1:$OPORT"
mkdir -p "$W/data"
( cd "$CLONE/packages/code_push_server" && PORT=$PORT API_KEY="$API_KEY" \
  DB_BACKEND=sqlite STORAGE_BACKEND=file DATA_DIR="$W/data" \
  PUBLIC_BASE_URL="$BASE" LOG_FORMAT=json \
  URL_SIGNING_SECRET="$(openssl rand -hex 32)" \
  LOGIN_EMAIL="ci1@self-host.local" HOME="$CR_HOME" \
  "$DART" run bin/server.dart ) > "$LOG/server.log" 2>&1 &
echo $! > "$W/server.pid"
python3 "$CLONE/selfhost/scripts/lib/overlay_origin.py" "$OPORT" \
  "$CLONE/selfhost/cdn/overlay" "$LOG/origin.jsonl" \
  https://storage.googleapis.com "$CELL" > "$LOG/origin.log" 2>&1 &
echo $! > "$W/origin.pid"
trap 'kill $(cat "$W/server.pid" "$W/origin.pid" 2>/dev/null) 2>/dev/null' EXIT
for _ in $(seq 1 60); do curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break; sleep 0.5; done
curl -fsS "$BASE/healthz" >/dev/null && note "control plane up on :$PORT (from the tag's tree)" \
                                     || { note "control plane did not start"; exit 1; }
note "artifact origin up on :$OPORT (overlay + upstream fallthrough)"

step "1 - a fresh app, and a THROWAWAY control-plane app record"
APP="$W/app"
( cd "$W" && HOME="$CR_HOME" "$FLUTTER" create --org dev.selfhost.ci1 --platforms=android app ) \
  > "$LOG/create.log" 2>&1
[[ -d "$APP/android/app/src" ]] || { note "flutter create failed"; tail -5 "$LOG/create.log"; exit 1; }
APP_ID=$(curl -fsS -X POST "$BASE/api/v1/apps" -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' -d '{"display_name":"ci-noninteractive-1"}' \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
cat > "$APP/shorebird.yaml" <<YAML
app_id: $APP_ID
base_url: $BASE
YAML
python3 "$CLONE/selfhost/scripts/lib/add_shorebird_asset.py" "$APP/pubspec.yaml" >/dev/null 2>&1 || true
note "app_id=$APP_ID"
cat > "$W/ci1.env" <<ENV
W=$W
B=$B
PORT=$PORT
OPORT=$OPORT
API_KEY=$API_KEY
APP_ID=$APP_ID
APP=$APP
ORIGIN=$ORIGIN
BASE=$BASE
ENV

# DECLARED OPERATOR CONFIGURATION. env -i strips everything, so anything the
# workflow needs has to be named here -- which is the point: the unattended
# contract is the list below, and nothing reaches the CLI by accident.
#
# Found by measurement, in this order: without ANDROID_HOME the release exits 70
# with "No Android SDK found. Try setting the ANDROID_HOME environment
# variable." That is environment/configuration, not a prompt, and it fails
# closed with the remedy named. The Android SDK and the JDK are operator-
# supplied tooling exactly like Xcode; passing them explicitly is what keeps
# them from being HIDDEN local state.
#
# ~/.gradle stays DENIED by the sandbox, so Gradle builds against a fresh
# cache in the cleanroom HOME rather than inheriting one.
# GRADLE_USER_HOME IS NOT OPTIONAL, and HOME does not cover it. Gradle is a
# Java process, and Java resolves `user.home` from passwd rather than from the
# HOME environment variable -- so with HOME pointed at the cleanroom, Gradle
# still reached for /Users/mendell/.gradle, which the sandbox denies:
#   java.io.FileNotFoundException: /Users/mendell/.gradle/wrapper/dists/
#     gradle-9.1.0-all/.../gradle-9.1.0-all.zip.lck (Operation not permitted)
# An unattended contract therefore has to name GRADLE_USER_HOME explicitly.
# Measured, not assumed: this is why the release arms exited 70 on the second
# pass rather than reaching any prompt.
OP_GRADLE_HOME=${OP_GRADLE_HOME:-$W/gradle}
mkdir -p "$OP_GRADLE_HOME"
OP_ANDROID_HOME=${OP_ANDROID_HOME:-$HOME/Library/Android/sdk}
OP_JAVA_HOME=${OP_JAVA_HOME:-$(/usr/libexec/java_home 2>/dev/null)}
note "declared operator config: ANDROID_HOME=$OP_ANDROID_HOME"
note "declared operator config: GRADLE_USER_HOME=$OP_GRADLE_HOME (fresh)"
note "declared operator config: JAVA_HOME=$OP_JAVA_HOME"

# Run a CLI command with the hostile shape. $1 = log name, $2 = stdin mode,
# rest = args. Never a TTY: stdout and stderr both go to a file.
arm() {
  local name=$1 mode=$2; shift 2
  local rc
  if [[ "$mode" == closed ]]; then
    ( cd "$APP" && sandbox-exec -f "$PROFILE" /usr/bin/env -i \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$CR_HOME" TMPDIR="$W/tmp" \
        LANG=en_US.UTF-8 TERM=dumb CI=true \
        SHOREBIRD_ARTIFACT_ORIGIN="$ORIGIN" FLUTTER_STORAGE_BASE_URL="$ORIGIN" \
        SHOREBIRD_HOSTED_URL="$BASE" SHOREBIRD_TOKEN="$API_KEY" \
        ANDROID_HOME="$OP_ANDROID_HOME" ANDROID_SDK_ROOT="$OP_ANDROID_HOME" \
        JAVA_HOME="$OP_JAVA_HOME" GRADLE_USER_HOME="$OP_GRADLE_HOME" \
        /bin/bash "$SB" "$@" ) > "$LOG/$name.log" 2>&1 0<&-
    rc=$?
  else
    ( cd "$APP" && sandbox-exec -f "$PROFILE" /usr/bin/env -i \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$CR_HOME" TMPDIR="$W/tmp" \
        LANG=en_US.UTF-8 TERM=dumb CI=true \
        SHOREBIRD_ARTIFACT_ORIGIN="$ORIGIN" FLUTTER_STORAGE_BASE_URL="$ORIGIN" \
        SHOREBIRD_HOSTED_URL="$BASE" SHOREBIRD_TOKEN="$API_KEY" \
        ANDROID_HOME="$OP_ANDROID_HOME" ANDROID_SDK_ROOT="$OP_ANDROID_HOME" \
        JAVA_HOME="$OP_JAVA_HOME" GRADLE_USER_HOME="$OP_GRADLE_HOME" \
        /bin/bash "$SB" "$@" ) > "$LOG/$name.log" 2>&1 < /dev/null
    rc=$?
  fi
  printf '  %-34s stdin=%-7s exit=%-3s %s\n' "$name" "$mode" "$rc" \
    "$(grep -m1 -oE 'Input was required for the following prompt[^\"]*' "$LOG/$name.log" | cut -c1-64)"
  echo "$rc"
}
mkdir -p "$W/tmp"

step "2 - is stdin actually closed? the two shapes, measured"
# Not an assumption: ask Dart itself what it sees.
cat > "$W/stdin_probe.dart" <<'DART'
import 'dart:io';
void main() {
  stdout.writeln('stdin.hasTerminal=${stdin.hasTerminal}');
  try {
    stdout.writeln('stdin.echoMode=${stdin.echoMode}');
  } on Object catch (e) {
    stdout.writeln('stdin.echoMode threw: ${e.runtimeType}');
  }
  stdout.writeln('stdout.hasTerminal=${stdout.hasTerminal}');
}
DART
for mode in closed devnull tty; do
  case $mode in
    closed)  out=$("$DART" run "$W/stdin_probe.dart" 2>&1 0<&-) ;;
    devnull) out=$("$DART" run "$W/stdin_probe.dart" 2>&1 < /dev/null) ;;
    tty)     out="(not measured: this harness never has a TTY)" ;;
  esac
  printf '  %-8s %s\n' "$mode" "$(echo "$out" | tr '\n' ' ')"
done

step "3a - PREFLIGHT: what the workflow demands of the PROJECT"
# Found by measurement, not anticipated: all three release arms first exited 78
# on `AndroidManifest.xml is missing the INTERNET permission / Aborting due to
# validation errors`. A `flutter create` app does not have it, so an unattended
# job must either patch the manifest itself or run the product's own fixer.
# Both are environment/configuration, not a prompt -- and the fixer MUTATES the
# project, so whether IT can run unattended is part of the surface.
r=$(arm doctor_fix closed doctor --fix); inv environment "$r" "doctor --fix adds the INTERNET permission; mutates the project"
grep -cE "INTERNET" "$APP/android/app/src/main/AndroidManifest.xml" \
  | sed 's/^/    INTERNET permission entries after doctor --fix: /'

step "3 - the ordinary release, with nothing able to answer"
r=$(arm release_noflag closed release android --artifact apk); inv release "$r" "no --no-confirm, stdin closed"
r=$(arm release_devnull devnull release android --artifact apk); inv release "$r" "no --no-confirm, stdin=/dev/null"
r=$(arm release_noconfirm closed release android --artifact apk --no-confirm); inv release "$r" "--no-confirm, stdin closed"

step "3b - PATCH, including the case a CI job must never be asked"
# A single release lets release_chooser.dart skip the prompt entirely, so the
# ambiguous case needs TWO releases or it proves less than it looks.
r=$(arm patch_noversion closed patch android --no-confirm); inv release_selection "$r" "no --release-version, one release exists"
if [[ "$r" == 0 ]]; then
  # Bump the version and cut a second release so the chooser cannot shortcut.
  sed -i '' 's/^version: 1\.0\.0+1$/version: 1.1.0+1/' "$APP/pubspec.yaml"
  arm release_second closed release android --artifact apk --no-confirm >/dev/null
  sed -i '' 's/^version: 1\.1\.0+1$/version: 1.0.0+1/' "$APP/pubspec.yaml"
  r=$(arm patch_ambiguous closed patch android --no-confirm)
  inv release_selection "$r" "no --release-version, TWO releases exist"
fi
r=$(arm patch_noauth closed patch android --no-confirm --release-version 1.0.0+1)
inv authentication "$r" "with a valid token, for contrast"

step "4 - what each arm actually asked for"
for f in doctor_fix release_noflag release_devnull release_noconfirm patch_noversion patch_ambiguous; do
  [[ -f "$LOG/$f.log" ]] || continue
  echo "  --- $f"
  grep -niE "input was required|would you like|confirm|\? \[y/n\]|Missing|refus|Error|Exception" "$LOG/$f.log" \
    | head -4 | sed 's/^/      /'
done

step "RESULT"
echo "  workspace: $W"
echo "  inventory: $INV"
column -t -s'|' "$INV" 2>/dev/null | sed 's/^/    /' || cat "$INV"
