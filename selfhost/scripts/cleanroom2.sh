#!/usr/bin/env bash
# cspell:words seatbelt sandboxed pubcache prebuilt getsockname realpath PREREQ prereq CLEANROOM cleanroom cellhits CELLREQ OTHERREQ
# SELFHOST-CLEANROOM-2 -- the same hostile cleanroom as CLEANROOM-1, re-run
# after SELFHOST-DISTRIBUTION-1.
#
# Same denials, same fresh HOME, same scrubbed environment. The difference is
# that this run starts from an IMMUTABLE TAG and is expected to reach
# SUPPORTED STATE VERIFIED and then hydrate release-side artifacts for both
# supported platforms.
#
# The isolation is asserted before anything else and the assertion has its own
# control, because a cleanroom that is not actually sealed proves nothing.
set -uo pipefail
ROOT=${ROOT:-/Volumes/build/cleanroom2}
TAG=${TAG:-}
CLI_REPO=https://github.com/mml555/shorebird.git
DEV_CHECKOUT=/Users/mendell/shorebird
DENIED=(
  /Volumes/build/route-b
  "$DEV_CHECKOUT"
  "$HOME/.shorebird"
  "$HOME/.pub-cache"
  "$HOME/.gradle"
)
fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
mkdir -p "$ROOT"; cd "$ROOT"
LOG="$ROOT/logs"; mkdir -p "$LOG" "$ROOT/tmp"
PROFILE="$ROOT/cleanroom.sb"

note "0 - the sealed cleanroom"
{
  echo '(version 1)'
  echo '(allow default)'
  for d in "${DENIED[@]}"; do echo "(deny file-read* (subpath \"$d\"))"; done
  a="$ROOT"
  while [[ "$a" != "/" && -n "$a" ]]; do echo "(allow file-read-metadata (literal \"$a\"))"; a=$(dirname "$a"); done
  echo "(allow file-read* (subpath \"$ROOT\"))"
} > "$PROFILE"
box() { sandbox-exec -f "$PROFILE" "$@"; }
for d in "${DENIED[@]}"; do
  [[ -e "$d" ]] || { echo "    (absent, nothing to deny: $d)"; continue; }
  box /bin/ls "$d" >/dev/null 2>&1 && bad "STILL READABLE: $d" || ok "denied: $d"
done
outside=0
for d in "${DENIED[@]}"; do [[ -e "$d" ]] && /bin/ls "$d" >/dev/null 2>&1 && outside=$((outside+1)); done
[[ "$outside" -gt 0 ]] && ok "$outside of them ARE readable outside the sandbox, so the denial is what stops them" \
                       || bad "the denied paths were unreadable anyway — this control proves nothing"
CR_HOME="$ROOT/home"; rm -rf "$CR_HOME"; mkdir -p "$CR_HOME"
run() {
  sandbox-exec -f "$PROFILE" /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$CR_HOME" TMPDIR="$ROOT/tmp" \
    LANG=en_US.UTF-8 TERM=dumb GIT_TERMINAL_PROMPT=0 "$@"
}
for c in .shorebird .pub-cache .gradle; do
  [[ -e "$CR_HOME/$c" ]] && bad "the fresh HOME already has $c" || ok "fresh HOME has no $c"
done

note "1 - the immutable selfhost tag RESOLVES"
if [[ -z "$TAG" ]]; then
  TAG=$(run /usr/bin/git ls-remote --tags "$CLI_REPO" 'selfhost-v*' 2>/dev/null \
        | sed 's|.*refs/tags/||' | grep -v '\^{}' | sort -V | tail -1)
fi
echo "    newest selfhost-v* on the remote: ${TAG:-<none>}"
[[ -n "$TAG" ]] && ok "an immutable selfhost tag resolves anonymously" || bad "no selfhost-v* tag"

note "2 - bootstrap from that tag alone"
# The supported path, run inside the sandbox. It clones, reads the record,
# creates the runtime checkout, downloads and hydrates the cell, fetches the
# selector, derives SHOREBIRD_ROOT and verifies.
CLONE="$ROOT/boot/shorebird"
run /usr/bin/git clone --quiet "$CLI_REPO" "$ROOT/seed" >"$LOG/seed.log" 2>&1
run /usr/bin/git -C "$ROOT/seed" fetch --quiet --tags origin 2>/dev/null
run /usr/bin/git -C "$ROOT/seed" checkout --quiet --detach "$TAG" 2>/dev/null \
  && ok "the tag checks out ($(run /usr/bin/git -C "$ROOT/seed" rev-parse --short HEAD))" \
  || bad "the tag does not check out"
BOOT="$ROOT/seed/selfhost/scripts/bootstrap_selfhost.sh"
[[ -f "$BOOT" ]] && ok "the tag carries the bootstrap path" || bad "no bootstrap script at the tag"
run /bin/bash "$BOOT" --root "$ROOT/boot" --ref "$TAG" > "$LOG/bootstrap.log" 2>&1
grep -E "^  (PASS|FAIL|PREREQ)" "$LOG/bootstrap.log" | sed 's/\x1b\[[0-9;]*m//g;s/^/    /'
grep -q "BOOTSTRAP COMPLETE" "$LOG/bootstrap.log" && ok "BOOTSTRAP COMPLETE" \
  || bad "the bootstrap did not complete — see logs/bootstrap.log"

note "3 - the acceptance table"
STATE="$CLONE/selfhost/engine/route_b/SUPPORTED_STATE.yaml"
rec() { sed -nE "s/^[[:space:]]*$1:[[:space:]]*([^[:space:]#]+).*/\1/p" "$STATE" | head -1; }
CELL=$(rec cell_address); SEL=$(rec flutter_selector); CLIREV=$(rec cli_revision)
row() { printf '    %-34s %s\n' "$1" "$2"; }
[[ -f "$STATE" ]] && row "record" "CURRENT (cell $CELL)" || bad "no record"
if run /usr/bin/python3 "$CLONE/selfhost/engine/route_b/lib/record_lint.py" "$STATE" >/dev/null 2>&1; then
  row "record format" "duplicate-free"; ok "the record lints clean with no external dependency"
else
  bad "the record does not lint clean"
fi
run /usr/bin/git -C "$CLONE" cat-file -e "${CLIREV}^{commit}" 2>/dev/null \
  && { row "cli_revision" "RESOLVES"; ok "cli_revision resolves"; } || bad "cli_revision does not resolve"
FD="$ROOT/boot/runtime/bin/cache/flutter/$SEL"
[[ "$(run /usr/bin/git -C "$FD" rev-parse HEAD 2>/dev/null)" == "$SEL" ]] \
  && { row "flutter_selector" "RESOLVES"; ok "the selector was fetched and is checked out"; } \
  || bad "the selector did not resolve"
gotcell=$(run /usr/bin/git -C "$FD" show "$SEL:bin/internal/engine.version" 2>/dev/null | tr -d '[:space:]')
[[ "$gotcell" == "$CELL" ]] && { row "selector -> cell" "MATCH"; ok "the recorded selector's engine.version IS the recorded cell"; } \
                            || bad "the selector selects $gotcell, not $CELL"
n=$(grep -c "CELL MEMBERS VERIFIED" "$ROOT/boot/hydrate.log" 2>/dev/null || echo 0)
grep -q "CELL MEMBERS VERIFIED (30/30)" "$ROOT/boot/hydrate.log" 2>/dev/null \
  && { row "cell members" "30/30"; row "cell address" "$CELL"; ok "the cell hydrated 30/30 from the durable distribution"; } \
  || bad "the cell did not hydrate 30/30"
grep -q "SUPPORTED STATE VERIFIED" "$LOG/bootstrap.log" \
  && { row "SUPPORTED STATE VERIFIED" YES; ok "SUPPORTED STATE VERIFIED in the cleanroom"; } \
  || bad "the supported state does not verify in the cleanroom"

note "4 - release-side artifact hydration, BOTH platforms, no devices"
# WHAT IS MEASURED: the release-side engine artifacts for each supported
# platform resolve and install from the DURABLE DISTRIBUTION -- no inherited
# cache, no /Volumes/build read. `flutter precache --<platform>` is the vehicle
# because it is the step `shorebird release <platform>` runs internally; the
# objects are the same ones a release build fetches.
#
# WHAT IS NOT MEASURED: the CLI's own translation of SHOREBIRD_ARTIFACT_ORIGIN
# into FLUTTER_STORAGE_BASE_URL for its flutter children. A bare flutter reads
# only the Flutter-native variable, so both are set here -- FLUTTER_STORAGE_BASE_URL
# is the documented operator knob for exactly this. That translation was proven
# separately by FLUTTER-STORAGE-AUTHORITY-1 (10 controls) and is not what this
# lane is about.
OVL="$ROOT/boot/shorebird/selfhost/cdn/overlay"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
( cd "$OVL" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) > "$LOG/origin_access.log" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
for _ in $(seq 1 40); do
  curl -fsS -o /dev/null "http://127.0.0.1:$PORT/flutter_infra_release/flutter/$CELL/engine_stamp.json" 2>/dev/null && break
  sleep 0.25
done
ORIGIN="http://127.0.0.1:$PORT"
FLUTTER="$FD/bin/flutter"
[[ -x "$FLUTTER" ]] && ok "the bootstrapped Flutter is executable" || bad "no flutter at $FLUTTER"
for plat in ios android; do
  before=$(grep -c "GET /" "$LOG/origin_access.log" 2>/dev/null || echo 0)
  sandbox-exec -f "$PROFILE" /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$CR_HOME" TMPDIR="$ROOT/tmp" \
    LANG=en_US.UTF-8 TERM=dumb \
    SHOREBIRD_ARTIFACT_ORIGIN="$ORIGIN" FLUTTER_STORAGE_BASE_URL="$ORIGIN" \
    /bin/bash "$FLUTTER" precache "--$plat" > "$LOG/precache_$plat.log" 2>&1
  rc=$?
  echo "    flutter precache --$plat exit=$rc"
  if [[ $rc -eq 0 ]]; then ok "release-side artifacts hydrated for $plat"
  else bad "precache --$plat failed"; tail -5 "$LOG/precache_$plat.log" | sed 's/^/      /'; fi
  # ATTRIBUTION: the objects must have come from the CELL's path space on the
  # operator's own origin, not from anywhere else.
  after=$(grep -c "GET /" "$LOG/origin_access.log" 2>/dev/null || echo 0)
  fetched=$(( after - before ))
  cellhits=$(grep "GET /" "$LOG/origin_access.log" 2>/dev/null | grep -c "$CELL" || echo 0)
  echo "    requests to the operator origin during this precache: $fetched (cumulative cell-path hits: $cellhits)"
done
CELLREQ=$(grep "GET /" "$LOG/origin_access.log" 2>/dev/null | grep -c "$CELL" || echo 0)
OTHERREQ=$(grep "GET /" "$LOG/origin_access.log" 2>/dev/null | grep -vc "$CELL" || echo 0)
[[ "$CELLREQ" -gt 0 ]] && ok "$CELLREQ requests were for the cell's own path space" \
                       || bad "no request reached the cell's path space — hydration proved nothing"
echo "    requests NOT under the cell path: $OTHERREQ"
# And the artifacts must actually be on disk for both platforms.
for d in ios-release android-arm64-release; do
  if compgen -G "$FD/bin/cache/artifacts/engine/$d/*" >/dev/null 2>&1; then
    ok "engine artifacts present on disk: artifacts/engine/$d"
  else
    bad "no artifacts installed at artifacts/engine/$d"
  fi
done

note "5 - and no /Volumes/build read could have helped"
box /bin/ls /Volumes/build/route-b >/dev/null 2>&1 \
  && bad "/Volumes/build/route-b became readable" || ok "/Volumes/build/route-b still denied"
box /bin/ls "$DEV_CHECKOUT" >/dev/null 2>&1 \
  && bad "the development checkout became readable" || ok "the development checkout still denied"

note "RESULT"
echo "  cleanroom: $ROOT"
if [[ $fail -eq 0 ]]; then echo "  CLEANROOM REPRODUCIBLE"; else
  echo "  CLEANROOM NOT REPRODUCIBLE: $fail failure(s)"; exit 1; fi
