#!/usr/bin/env bash
# cspell:words FLDIR dists SIGPIPE PIPESTATUS DEFAULTPATH
# accept_android_default.sh — the Android DEFAULT-PATH acceptance run.
#
# One test, no side experiments. It closes two things at once:
#
#   #15                 icon tree-shaking works, because linux-x64/font-subset.zip
#                       now carries OUR const_finder (built with the fork dart).
#   Gradle workaround   the localhost insecure-repo init script is gone and
#                       Gradle resolves the mirror over HTTPS with normal CA
#                       validation.
#
# "Default path" is the point: NO --no-tree-shake-icons, NO init script, NO
# plain-HTTP mirror. If this passes, a stock invocation works against our
# engine, which is the actual claim.
#
# RUN IT ON THE BUILD BOX. Releases must run on Linux — our gen_snapshot is
# linux-x64 only and the mirror deliberately 404s host artifacts we did not
# build, so a release from the Mac cannot work.
#
# Reverse tunnels must already exist (opened from the Mac):
#   -R 18081:localhost:18081   the Mac's code_push_server (cps-android)
#   -R 18443:localhost:8443    the Mac's CDN mirror, HTTPS listener
#
# The device is attached to the MAC, not the box, with
# `adb reverse tcp:18081 tcp:18081`, so one URL satisfies both.
#
#   accept_android_default.sh [--stage release|patch] [--keep-caches]
set -euo pipefail

R=/data/shorebird-engine
FLREV=c15ef6379403a0a55531a058bdb2c8e55bc05c98
EXP=760e3fabffbf31b4e86919a0ef47d6ce5f182991   # current Android engine (has our const_finder)
GRADLE_INIT=/data/gradle-home/init.d/selfhost-allow-insecure-mirror.gradle
STAGE=release
KEEP_CACHES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage) STAGE="${2:?}"; shift 2 ;;
    --keep-caches) KEEP_CACHES=1; shift ;;
    -h|--help) sed -n '3,31p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# shellcheck disable=SC1091
source "$R/env.sh"
export PATH="$R/shorebird/bin:$PATH"
export GRADLE_USER_HOME=/data/gradle-home

# HTTPS, not the 18085 plain-HTTP tunnel the older scripts use. This is what
# makes the Gradle init script unnecessary rather than merely unused.
say() { printf '\n== %s ==\n' "$*"; }
die() { echo "FAIL: $*" >&2; exit 1; }

# Auth. NEVER bake a key into a script — a dev key was leaked into a session
# transcript once and had to be rotated (HANDOFF, 2026-08-05). The token lives
# in a 0600 file on this box only, and is read here without ever being echoed.
TOKEN_FILE="${TOKEN_FILE:-$R/.cps_token}"
if [[ -z "${SHOREBIRD_TOKEN:-}" ]]; then
  [[ -r "$TOKEN_FILE" ]] || die "no SHOREBIRD_TOKEN and no readable $TOKEN_FILE"
  SHOREBIRD_TOKEN="$(cat "$TOKEN_FILE")"
fi
export SHOREBIRD_TOKEN

export SHOREBIRD_HOSTED_URL=http://localhost:18081
export FLUTTER_STORAGE_BASE_URL=https://localhost:18443
export SHOREBIRD_STORAGE_BASE_URL=https://localhost:18443
export SHOREBIRD_STORAGE_BUCKET=download.shorebird.dev

say "preflight"
cp="$(curl -sS -o /dev/null -w '%{http_code}' "$SHOREBIRD_HOSTED_URL/" || echo FAIL)"
[[ "$cp" == "200" ]] || die "control plane $SHOREBIRD_HOSTED_URL -> $cp (tunnel down?)"
echo "  control plane            : $cp"

# CA validation deliberately ENFORCED — no -k. If this needs -k, the whole
# point of removing the init script is lost.
fs_url="$FLUTTER_STORAGE_BASE_URL/flutter_infra_release/flutter/$EXP/linux-x64/font-subset.zip"
mc="$(curl -sS -o /tmp/accept-fs.zip -w '%{http_code}' "$fs_url" || echo FAIL)"
[[ "$mc" == "200" ]] || die "mirror HTTPS -> $mc with CA validation enforced"
echo "  mirror HTTPS (CA enforced): $mc"

# PROOF that the const_finder about to be used is OURS, recorded before the
# build so it cannot be confused with something the build produced.
CF_SHA="$(unzip -p /tmp/accept-fs.zip const_finder.dart.snapshot | sha256sum | awk '{print $1}')"
echo "  served const_finder sha256: $CF_SHA"
echo "$CF_SHA" > /tmp/accept-const-finder.sha

[[ ! -e "$GRADLE_INIT" ]] \
  || die "$GRADLE_INIT still exists — this run must prove Gradle works WITHOUT it"
echo "  gradle insecure init     : absent (good)"

FLDIR="$R/shorebird/bin/cache/flutter/$FLREV"
[[ -d "$FLDIR" ]] || die "no flutter checkout at $FLDIR"
echo "$EXP" > "$FLDIR/bin/internal/engine.version"
echo "  engine.version           : $(cat "$FLDIR/bin/internal/engine.version")"

if [[ $KEEP_CACHES -eq 0 ]]; then
  say "clearing caches so neither workaround can be reused"
  # Engine artifacts: force a re-fetch through the HTTPS mirror, so the
  # font-subset.zip that lands is provably the one served above.
  rm -rf "$R/shorebird/bin/cache/artifacts/engine"
  rm -f  "$R/shorebird/bin/cache/engine.stamp" "$R/shorebird/bin/cache/engine_stamp.stamp"
  rm -rf "$FLDIR/bin/cache/artifacts/engine"
  rm -f  "$FLDIR/bin/cache/engine.stamp" "$FLDIR/bin/cache/engine_stamp.stamp"
  # Gradle: drop the resolved-module cache so repository resolution really
  # happens again over HTTPS. The wrapper dists are left alone (they are not
  # what is under test and re-downloading them is pure cost).
  rm -rf /data/gradle-home/caches/modules-2 /data/gradle-home/caches/*/scripts
  echo "  cleared engine artifacts + gradle modules-2"
fi

cd "$R/rbtest"

if [[ "$STAGE" == "release" ]]; then
  say "DEFAULT release — no --no-tree-shake-icons, no init script, HTTPS mirror"
  # Deliberately NO `-- --no-tree-shake-icons`. That flag is what #15 removes.
  nice -n 10 shorebird release android --no-confirm --artifact=apk \
    --flutter-version="$FLREV" 2>&1 | tail -40
else
  say "DEFAULT patch"
  # NO --artifact here: it is a `release` flag only, and passing it makes the
  # patch command dump usage and exit 64 with no error line, which reads like a
  # different failure entirely.
  #
  # CORRECTED 2026-08-13. This used to read "NO --no-confirm either — this CLI
  # does not have it on `patch`, hence `yes |`", and the reason given was false:
  # patch_command.dart:115-118 registers addFlag('confirm', hide: true), and
  # addFlag is negatable by default, so `--no-confirm` parses and is read at
  # :215. It is `hide: true`, so it never appears in --help — the likely origin
  # of the mistake. The release invocation twenty lines above already passes it.
  #
  # `yes |` is LEFT IN PLACE deliberately, and not because of that clause. This
  # harness runs unattended on hermes-vps against a device gate that is still
  # owed, and nothing in the correcting session could verify a behavioural
  # change to it. Removing the pipe would also remove the SIGPIPE handling
  # below, which is load-bearing. Whoever next runs this leg on hardware is the
  # one who can safely swap `yes |` for `--no-confirm`.
  #
  # `yes |` makes the exit status 141 (SIGPIPE) once shorebird stops reading,
  # even on success — so take the status from PIPESTATUS, not from $?.
  set +e
  yes | nice -n 10 shorebird patch android \
    --release-version="${RELEASE_VERSION:?set RELEASE_VERSION}" 2>&1 | tail -40
  rc=${PIPESTATUS[1]}
  set -e
  exit "$rc"
fi
