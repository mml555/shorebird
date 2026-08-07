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

# --- the canonical fixture -------------------------------------------------------
# --app used to be mandatory with no default, and the app it pointed at lived in
# a session scratchpad. The scratchpad was cleaned and the path was never
# written down, so the 2026-08-06 pass could not be reproduced. Defaulting to a
# committed fixture is what stops that recurring; the override still exists for
# one-off apps.
if [[ -z "$APP_DIR" ]]; then
  APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../fixtures/airgap_app" 2>/dev/null && pwd || true)"
fi
if [[ -z "$APP_DIR" || ! -f "$APP_DIR/pubspec.yaml" ]]; then
  cat >&2 <<'EOF'
Missing canonical acceptance fixture.
  Run: selfhost/scripts/prepare_airgap_fixture.sh --app-id <id>
  (or pass --app <flutter app dir> for a one-off)
EOF
  exit 2
fi
if grep -q 'REPLACE-ME' "$APP_DIR/shorebird.yaml" 2>/dev/null; then
  cat >&2 <<EOF
Fixture at $APP_DIR has a placeholder app_id.
  app_id is server-generated, so it cannot be committed. Create the app on the
  control plane and re-run:
    selfhost/scripts/prepare_airgap_fixture.sh --app-id <id>
EOF
  exit 2
fi

export FLUTTER_STORAGE_BASE_URL="$MIRROR"
export SHOREBIRD_STORAGE_BASE_URL="$MIRROR"
export SHOREBIRD_STORAGE_BUCKET="${SHOREBIRD_STORAGE_BUCKET:-download.shorebird.dev}"
export SHOREBIRD_FLUTTER_GIT_URL="${SHOREBIRD_FLUTTER_GIT_URL:-file://$(cd "$(dirname "${BASH_SOURCE[0]}")/../cdn/mirrors/flutter.git" 2>/dev/null && pwd)}"
export SHOREBIRD_PUB_OFFLINE=true
: "${SHOREBIRD_HOSTED_URL:?SHOREBIRD_HOSTED_URL must point at the control plane}"
: "${SHOREBIRD_TOKEN:?SHOREBIRD_TOKEN must be set}"

# --- which CLI is actually under test? -------------------------------------------
# The acceptance run exercises $SHOREBIRD_ROOT/bin/shorebird, which is its own
# git checkout — NOT the repo this script lives in. Those drift, silently.
#
# On 2026-08-07 the installed CLI was 18 commits stale and was missing
# acaeda64 ("fail closed when gen_snapshot is not cached yet"). The probe it
# fixes is the one this harness deliberately exercises with default
# --dd-max-bytes, so the run died with "Unrecognized flags:
# print_dd_function_identity_to" — the harness correctly caught a bug that had
# already been fixed, in a CLI nobody had noticed was old. Testing the wrong
# binary is its own reproducibility gap, so name it up front.
cli_revision_check() {
  local repo cli_head repo_head behind
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || return 0
  git -C "$SHOREBIRD_ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "[cli] $SHOREBIRD_ROOT is not a git checkout; cannot verify CLI revision"
    return 0
  }
  cli_head="$(git -C "$SHOREBIRD_ROOT" rev-parse HEAD 2>/dev/null)"
  repo_head="$(git -C "$repo" rev-parse HEAD 2>/dev/null)"
  echo "[cli] under test : ${cli_head:0:9}  ($SHOREBIRD_ROOT)"
  echo "[cli] harness repo: ${repo_head:0:9}  ($repo)"
  [[ "$cli_head" == "$repo_head" ]] && return 0

  # Differing HEADs are fine on their own — only CLI-affecting commits matter.
  behind="$(git -C "$repo" log --oneline "$cli_head..$repo_head" \
              -- packages/shorebird_cli 2>/dev/null)" || return 0
  [[ -n "$behind" ]] || { echo "[cli] revisions differ, but no shorebird_cli commits between them"; return 0; }
  echo "STALE CLI: $SHOREBIRD_ROOT is missing shorebird_cli commits:" >&2
  echo "$behind" | sed 's/^/  /' >&2
  cat >&2 <<EOF
  Sync it, then re-run:
    git -C $SHOREBIRD_ROOT fetch $repo \$(git -C $repo branch --show-current)
    git -C $SHOREBIRD_ROOT checkout FETCH_HEAD
    rm -f $SHOREBIRD_ROOT/bin/cache/shorebird.snapshot
  Set AIRGAP_ALLOW_STALE_CLI=1 to test an intentionally older CLI.
EOF
  [[ -n "${AIRGAP_ALLOW_STALE_CLI:-}" ]]
}

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
# Guard for every destructive path in this script.
#
# Added after a real incident (2026-08-07): this harness was invoked as a
# "does it parse" check and stage 1 promptly deleted ~/.shorebird/bin/cache,
# taking the 309dd6573 Flutter checkout — the rollback pin from
# compatibility.yaml — with it. Nothing about `airgap_acceptance.sh --ios`
# announces that it starts by wiping a cache.
#
# So: say exactly what is about to be deleted, and refuse anything that is not
# a Shorebird cache under a plausible harness root. AIRGAP_I_KNOW is the escape
# hatch for a genuinely unusual root, and it has to be typed on purpose.
rm_cache() {  # rm_cache <dir>
  local target="$1" root
  [[ -n "$target" ]] || { echo "rm_cache: empty target" >&2; return 1; }
  # Resolve without requiring existence: a missing path is a no-op, not a risk.
  [[ -e "$target" ]] || { echo "  (nothing to delete at $target)"; return 0; }
  root="$(cd "$target" >/dev/null 2>&1 && pwd -P)" || {
    echo "rm_cache: cannot resolve $target" >&2; return 1; }

  case "$root" in
    */bin/cache|*/bin/cache/*) ;;
    *) echo "REFUSING to delete '$root': not a .../bin/cache path" >&2; return 1 ;;
  esac
  # A bare "/" or a home directory can never match the above, but be explicit
  # about the shortest plausible accident anyway.
  [[ ${#root} -gt 12 ]] || { echo "REFUSING to delete suspiciously short path '$root'" >&2; return 1; }
  if [[ "$root" != "$SHOREBIRD_ROOT"/* && -z "${AIRGAP_I_KNOW:-}" ]]; then
    echo "REFUSING: '$root' is outside SHOREBIRD_ROOT ($SHOREBIRD_ROOT)." >&2
    echo "          Set AIRGAP_I_KNOW=1 if that is genuinely intended." >&2
    return 1
  fi

  echo "  DELETING $root  ($(du -sh "$root" 2>/dev/null | awk '{print $1}'))"
  rm -rf "$root"
}

bootstrap() {
  # Stage 1 is destructive BY DESIGN — an empty cache is the whole premise of
  # the test — but it should never be a surprise. See rm_cache above.
  echo "stage 1 starts by emptying the Shorebird cache:"
  rm_cache "$SHOREBIRD_ROOT/bin/cache" || return 1
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
  rm_cache "$fl/bin/cache/artifacts" || return 1
  rm_cache "$fl/bin/cache/dart-sdk" || return 1
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

# The release version the app will publish, e.g. "31.0.0+1" from pubspec.
# `shorebird patch` must be told which release to patch: without it the CLI
# prompts "Which release would you like to patch?" and --no-confirm does not
# answer that prompt, so the stage hangs then fails (observed live).
app_release_version() {
  sed -nE 's/^version:[[:space:]]*([^[:space:]#]+).*/\1/p' "$APP_DIR/pubspec.yaml" | head -1
}

# --- stage 2: android release + patch --------------------------------------------
android_release_patch() {
  cd "$APP_DIR"
  switch_engine || return 1
  # DEFAULT FLAGS as of 2026-08-07 — no --no-tree-shake-icons.
  #
  # That flag used to be mandatory here: icon tree shaking runs const_finder, a
  # kernel stamped with the SDK hash of whatever Dart built it, and no fork
  # linux-x64 const_finder was published, so the stock one loaded and the build
  # died with "Invalid SDK hash". We now build and publish our own inside
  # 760e3fab's linux-x64/font-subset.zip (engine/publish_font_subset.sh
  # --host linux-x64), proven on device by the default-path acceptance run.
  #
  # Keeping the flag would make this gate weaker than the shipping path, which
  # is the opposite of what it is for.
  "$SHOREBIRD_ROOT/bin/shorebird" release android --no-confirm --artifact=apk \
    --flutter-version="$FLREV" || return 1
  local rel; rel="$(app_release_version)"
  [[ -n "$rel" ]] || { echo "could not read version: from $APP_DIR/pubspec.yaml" >&2; return 1; }
  "$SHOREBIRD_ROOT/bin/shorebird" patch android --no-confirm --allow-asset-diffs \
    --release-version="$rel" || return 1
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
  local rel; rel="$(app_release_version)"
  [[ -n "$rel" ]] || { echo "could not read version: from $APP_DIR/pubspec.yaml" >&2; return 1; }
  "$SHOREBIRD_ROOT/bin/shorebird" patch ios --no-confirm --assets-only \
    --allow-asset-diffs --release-version="$rel" || return 1
}

# --- stage 4: post-checks ---------------------------------------------------------
post_checks() {
  # AIRGAP_VERIFY_WARM lets a caller that runs this script from outside the
  # repo (e.g. an immutable copy in /tmp, so a mid-run sync cannot clobber the
  # file bash is still reading) point at verify_warm.sh explicitly. Without it
  # the relative lookup resolves against the copy's directory and silently
  # fails the stage.
  local vw="${AIRGAP_VERIFY_WARM:-}"
  if [[ -z "$vw" ]]; then
    vw="$(cd "$(dirname "${BASH_SOURCE[0]}")/../cdn" 2>/dev/null && pwd)/verify_warm.sh"
  fi
  [[ -x "$vw" ]] || { echo "verify_warm.sh not found at '$vw'; set AIRGAP_VERIFY_WARM" >&2; return 1; }
  # The mirror is often on another host (the Linux leg reaches the Mac's
  # mirror over an SSH tunnel), so let the caller point the check at it:
  #   AIRGAP_VERIFY_ARGS="--ssh user@host:port"
  # Without this the remote leg can only report "container is not running",
  # which is not a verdict.
  # shellcheck disable=SC2086
  "$vw" --since 4h ${AIRGAP_VERIFY_ARGS:-} && return 0
  echo "(review the refusal list above — fork-hash aot-tools.dill is expected)" >&2
  return 1
}


stage cli-revision cli_revision_check
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
