#!/usr/bin/env bash
# airgap_acceptance.sh — the payload of the air-gap acceptance run.
#
# From an EMPTY Shorebird cache and isolated host caches (airgap_run.sh sets
# those up), prove the toolchain is fully self-contained:
#
#   stage 1  bootstrap  : rm -rf bin/cache, then `shorebird --version` — clones
#                         the vended Flutter from the LOCAL git mirror, pub-gets
#                         OFFLINE from the seeded cache, downloads Dart/engine
#                         artifacts through the LOCAL mirror only.
#   stage 2  android    : release (apk) + patch against the control plane.
#   stage 3  ios        : release with DEFAULT flags (the DdSupport probe must
#                         auto-disable DD — validated live 2026-08-05) + an
#                         assets-only patch (which must survive the fork-hash
#                         aot-tools.dill 404 with a warning, not a failure).
#   stage 4  post-checks: verify_warm.sh reports zero sealed refusals that a
#                         stage needed; no App.dd_* in the iOS build.
#
# Run it under the enforcement wrapper, with the CDN in SEALED mode:
#   docker compose -f selfhost/cdn/docker-compose.cdn.yaml \
#                  -f selfhost/cdn/docker-compose.cdn.sealed.yaml up -d
#   sudo -v && AIRGAP_PUB_CACHE=... selfhost/scripts/airgap_run.sh -- \
#     selfhost/scripts/airgap_acceptance.sh --ios --app <dir> [--device <udid>]
#
# The same script does the WARM run: unsealed CDN, no wrapper — run it once to
# pull every real dependency through the mirror, seed PUB_CACHE, then seal and
# run it again. "Warm" is defined by executing the full workflows, never by a
# URL list (see selfhost/cdn/README.md).
set -uo pipefail

# --- knobs ---------------------------------------------------------------------
SHOREBIRD_ROOT="${AIRGAP_SHOREBIRD_ROOT:-$HOME/.shorebird}"
FLREV="${AIRGAP_FLUTTER_REV:-c15ef6379403a0a55531a058bdb2c8e55bc05c98}"
ENGINE_HASH="${AIRGAP_ENGINE_HASH:-}"           # set to build on a fork engine
MIRROR="${FLUTTER_STORAGE_BASE_URL:-http://localhost:8085}"
DO_ANDROID=0; DO_IOS=0; APP_DIR=""; DEVICE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --android) DO_ANDROID=1; shift ;;
    --ios) DO_IOS=1; shift ;;
    --app) APP_DIR="${2:?}"; shift 2 ;;
    --device) DEVICE="${2:?}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ "$DO_ANDROID$DO_IOS" != "00" ]] || { echo "pass --android and/or --ios" >&2; exit 2; }
[[ -n "$APP_DIR" ]] || { echo "--app <flutter app dir> is required" >&2; exit 2; }

export FLUTTER_STORAGE_BASE_URL="$MIRROR"
export SHOREBIRD_STORAGE_BASE_URL="$MIRROR"
export SHOREBIRD_STORAGE_BUCKET="${SHOREBIRD_STORAGE_BUCKET:-download.shorebird.dev}"
export SHOREBIRD_FLUTTER_GIT_URL="${SHOREBIRD_FLUTTER_GIT_URL:-file://$(cd "$(dirname "${BASH_SOURCE[0]}")/../cdn/mirrors/flutter.git" 2>/dev/null && pwd)}"
export SHOREBIRD_PUB_OFFLINE=true
: "${SHOREBIRD_HOSTED_URL:?SHOREBIRD_HOSTED_URL must point at the control plane}"
: "${SHOREBIRD_TOKEN:?SHOREBIRD_TOKEN must be set}"

declare -a RESULTS=()
FAIL=0
stage() {  # stage <name> <fn>
  local name="$1"; shift
  echo ""; echo "===== stage: $name ====="
  if "$@"; then
    RESULTS+=("PASS  $name")
  else
    RESULTS+=("FAIL  $name")
    FAIL=1
  fi
}

# --- stage 1: bootstrap from empty cache ----------------------------------------
bootstrap() {
  rm -rf "$SHOREBIRD_ROOT/bin/cache"
  "$SHOREBIRD_ROOT/bin/shorebird" --version || return 1
  # The clone must have come from the local mirror, not github.
  local origin
  origin="$(git -C "$SHOREBIRD_ROOT/bin/cache/flutter/$FLREV" remote get-url origin 2>/dev/null)"
  if [[ "$origin" == *github.com* ]]; then
    echo "bootstrap cloned Flutter from $origin — not the local mirror" >&2
    return 1
  fi
  echo "flutter cloned from: $origin"
}

# Point the vended Flutter at the fork engine AND refresh its toolchain.
# Writing engine.version alone is not enough: the cached Dart SDK still
# belongs to the previous engine, and the dart_sdk_compatibility guard
# (correctly) refuses to build a fork engine against a stock host SDK —
# caught live on the first warm run. Deleting the stamps makes the next
# flutter invocation re-fetch the matching dart-sdk + engine artifacts
# through the mirror, which is itself part of warming.
switch_engine() {
  [[ -n "$ENGINE_HASH" ]] || return 0
  local fl="$SHOREBIRD_ROOT/bin/cache/flutter/$FLREV"
  echo "$ENGINE_HASH" > "$fl/bin/internal/engine.version"
  # Drop the ENTIRE cached artifact set, not just the Dart SDK stamp. Every
  # piece of the host toolchain is stamped with the Dart that built it, so a
  # partial refresh leaves e.g. a stock const_finder beside a fork dart-sdk
  # and the build dies with "ConstFinder failure: Can't load Kernel binary:
  # Invalid SDK hash" (observed live, 2026-08-06). Re-fetching all of it
  # through the mirror is also exactly what warming wants.
  rm -rf "$fl/bin/cache/artifacts" "$fl/bin/cache/dart-sdk"
  rm -f "$fl"/bin/cache/*.stamp "$SHOREBIRD_ROOT/bin/cache/shorebird.stamp"
  "$fl/bin/flutter" --version >/dev/null || return 1
  # Deliberately NO `flutter precache` here. It was tried and removed the same
  # day: `precache --android` pulls EVERY Android ABI, and the run died
  # fetching android-x86/artifacts.zip — an artifact no release needs and the
  # mirror was never warmed for. Let the build fetch exactly what it uses,
  # which is also the honest cold-cache path. (Precache was originally added
  # so capability probes would not run against a gen_snapshot that is not on
  # disk yet; that is now handled correctly in the CLI, which fails closed
  # when the binary is absent.)
}

# --- stage 2: android release + patch --------------------------------------------
android_release_patch() {
  cd "$APP_DIR"
  switch_engine || return 1
  "$SHOREBIRD_ROOT/bin/shorebird" release android --no-confirm --artifact=apk \
    --flutter-version="$FLREV" -- --no-tree-shake-icons || return 1
  "$SHOREBIRD_ROOT/bin/shorebird" patch android --no-confirm --allow-asset-diffs || return 1
}

# --- stage 3: ios release (default flags) + assets-only patch --------------------
ios_release_patch() {
  cd "$APP_DIR"
  switch_engine || return 1
  # DEFAULT --dd-max-bytes on purpose: the DdSupport probe must auto-disable
  # DD on a vanilla-Dart engine. Passing 0 here would mask a broken probe.
  "$SHOREBIRD_ROOT/bin/shorebird" release ios --no-confirm --verbose \
    ${AIRGAP_IOS_EXPORT_ARGS:---export-method development} \
    --flutter-version="$FLREV" || return 1
  # No DD artifacts may exist (probe must have disabled the pass).
  if find build/ios -name "App.dd*" 2>/dev/null | grep -q .; then
    echo "App.dd_* artifacts present — DdSupport probe failed open" >&2
    return 1
  fi
  "$SHOREBIRD_ROOT/bin/shorebird" patch ios --no-confirm --assets-only \
    --allow-asset-diffs || return 1
}

# --- stage 4: post-checks ---------------------------------------------------------
post_checks() {
  local vw
  vw="$(cd "$(dirname "${BASH_SOURCE[0]}")/../cdn" && pwd)/verify_warm.sh"
  # In a sealed run, refusals mean something needed a cold path. verify_warm
  # exits 1 and lists them; surface but judge: a refusal for aot-tools.dill on
  # a fork hash is EXPECTED (loud 404 by design happens before the seal).
  "$vw" --since 4h && return 0
  echo "(review the refusal list above — fork-hash aot-tools.dill is expected)" >&2
  return 1
}

stage bootstrap bootstrap
[[ "$DO_ANDROID" == "1" ]] && stage android android_release_patch
[[ "$DO_IOS" == "1" ]] && stage ios ios_release_patch
stage post-checks post_checks

echo ""
echo "===== AIRGAP ACCEPTANCE SUMMARY ====="
echo "engine: ${ENGINE_HASH:-(pinned)}  flutter: $FLREV"
echo "mirror: $MIRROR   control plane: $SHOREBIRD_HOSTED_URL"
for r in "${RESULTS[@]}"; do echo "  $r"; done
if [[ "$FAIL" == "0" ]]; then
  echo "AIRGAP ACCEPTANCE: PASS"
else
  echo "AIRGAP ACCEPTANCE: FAIL"
fi
exit $FAIL
