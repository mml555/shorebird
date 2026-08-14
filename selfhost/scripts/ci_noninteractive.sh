#!/usr/bin/env bash
# cspell:words noninteractive NOTTY unbuffer nonzero pipestatus canaccept
# ci_noninteractive.sh — G10.2's harness: the real release/patch workflow,
# non-interactive, against OUR control plane.
#
# WHAT THIS EXISTS TO MEASURE, and what it deliberately does not.
#
# The prompt machinery is already BUILT. All four prompts fail fast rather than
# hang: confirm/chooseOne/prompt/promptAny each call _failIfNonInteractive
# (packages/shorebird_cli/lib/src/logging/shorebird_logger.dart :56-57, :65-72,
# :85-91, :99-104), whose guard at :136 is
#
#     if (isInteractive && shorebirdEnv.canAcceptUserInput) return;
#
# The gap G10.2 names is NOT "no CI runs the CLI" — .github/workflows/e2e.yaml
# drives it end to end. The gap is that e2e.yaml:60 and :142 point
# SHOREBIRD_HOSTED_URL at api-dev.shorebird.dev / api.shorebird.dev, i.e.
# UPSTREAM. No workflow exercises packages/code_push_server's release/patch path
# with the CLI. That is what this script does.
#
# A HARNESS THAT DOES NOT BREAK ONE OF THE GUARD'S CONDITIONS MEASURES NOTHING,
# which is why the preflight below is longer than the arms.
#
# THE TWO PREDICATES TEST DIFFERENT STREAMS — this is the trap:
#   isInteractive        (interactive_mode.dart:18-22) tests STDOUT
#   canAcceptUserInput   (shorebird_env.dart:292-293)  tests STDIN
#                        = stdin.hasTerminal && !isRunningOnCI && !isJsonMode
# The guard ANDs them, so an arm that redirects only one stream is not testing
# what its author thinks. This script redirects BOTH and asserts BOTH.
#
# WHY `CI` MUST BE UNSET. isRunningOnCI (shorebird_env.dart:299-324) fires on
# the mere PRESENCE of CI, APPVEYOR, CIRRUS_CI, JENKINS_URL, GITHUB_ACTIONS or
# TF_BUILD (so even CI=false counts), or BOT/TRAVIS/CONTINUOUS_INTEGRATION set
# to "true", or AWS_REGION+CODEBUILD_INITIATOR together. If any of those is set,
# canAcceptUserInput is false FOR THAT REASON and arm 1 no longer shows that the
# TTY predicate carried the run. The preflight refuses rather than silently
# producing a vacuous pass.
#
#   ci_noninteractive.sh --app-dir <dir> [--release-version <ver>] [--out <dir>]
#
# RUN IT ON THE LINUX BUILD BOX. See "HOST" in the preflight — this is a
# verified artifact constraint, not a preference.
set -euo pipefail

APP_DIR=""
OUT_DIR=""
BASE_VERSION=""
SKIP_NEGATIVE_CONTROL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-dir) APP_DIR="${2:?--app-dir needs a value}"; shift 2 ;;
    --release-version) BASE_VERSION="${2:?--release-version needs a value}"; shift 2 ;;
    --out) OUT_DIR="${2:?--out needs a value}"; shift 2 ;;
    --skip-negative-control) SKIP_NEGATIVE_CONTROL=1; shift ;;
    -h|--help) sed -n '3,41p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '\n== %s ==\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die()  { echo "FAIL: $*" >&2; exit 1; }

: "${SHOREBIRD_HOSTED_URL:=http://localhost:18081}"
export SHOREBIRD_HOSTED_URL

OUT_DIR="${OUT_DIR:-${PWD}/ci-noninteractive-out}"
mkdir -p "$OUT_DIR"

NOTTY_LOG="$OUT_DIR/ci_run_notty.log"
JSON_LOG="$OUT_DIR/ci_run_json.log"
NEG_LOG="$OUT_DIR/ci_run_negative_control.log"

# ---------------------------------------------------------------- preflight --
say "preflight"

# HOST. Our gen_snapshot is linux-x64 only. A macOS host doing an Android
# arm64 release downloads android-arm64-release/darwin-x64.zip
# (vendor/flutter/packages/flutter_tools/lib/src/flutter_cache.dart:900); our
# mirror 404s exactly that path while serving the linux-x64 sibling at :909.
# Verified against the mirror 2026-08-13:
#   android-arm64-release/linux-x64.zip  -> 200
#   android-arm64-release/darwin-x64.zip -> 404
# So `shorebird release android` cannot complete off Linux. Refuse loudly here
# rather than fail deep inside a build with a confusing artifact error.
host_os="$(uname -s)"
if [[ "$host_os" != "Linux" ]]; then
  die "host is $host_os; this harness requires Linux.
     Our gen_snapshot is linux-x64 only and the mirror 404s
     android-arm64-release/darwin-x64.zip. Re-verify with:
       curl -sS -o /dev/null -w '%{http_code}\\n' \\
         \"\$FLUTTER_STORAGE_BASE_URL/flutter_infra_release/flutter/<rev>/android-arm64-release/darwin-x64.zip\""
fi
note "host                     : $host_os"

[[ -n "$APP_DIR" ]] || die "--app-dir is required.
     Do NOT point it at selfhost/fixtures/airgap_app — that is R6, the sharpest
     serializer, and its version counter belongs to the device lane."
[[ -d "$APP_DIR" ]] || die "--app-dir '$APP_DIR' is not a directory"
case "$(cd "$APP_DIR" && pwd)" in
  *selfhost/fixtures/airgap_app*)
    die "refusing to run against airgap_app (R6). Use a fixture this lane owns." ;;
esac
[[ -f "$APP_DIR/pubspec.yaml" ]] || die "no pubspec.yaml in '$APP_DIR'"
[[ -d "$APP_DIR/android" ]] || die "'$APP_DIR' has no android/ — materialize it first
     (see prepare_airgap_fixture.sh:70-73 for the 'flutter create --platforms' pattern)"
note "app dir                  : $APP_DIR"

# THE VACUITY GUARD. If either stream is a TTY the arms prove nothing, because
# the guard would have let a prompt through and simply not been reached. Never
# run this under `script`, `unbuffer`, or a tmux pane: those make stdout a
# terminal via Stdout.hasTerminal or the stdioType fallback
# (interactive_mode.dart:20-21).
if [[ -t 1 ]]; then
  die "stdout is a TTY. Redirect it:  $0 ... > run.log 2>&1
     Never under script/unbuffer/tmux — those defeat the whole measurement."
fi
if [[ -t 0 ]]; then
  die "stdin is a TTY. Redirect it:  $0 ... < /dev/null > run.log 2>&1
     canAcceptUserInput (shorebird_env.dart:292-293) tests stdin, not stdout."
fi
note "stdout is a TTY          : no"
note "stdin  is a TTY          : no"

# CI must be unset, or arm 1 stops discriminating (see header).
ci_offenders=()
for v in CI APPVEYOR CIRRUS_CI JENKINS_URL GITHUB_ACTIONS TF_BUILD; do
  [[ -n "${!v+x}" ]] && ci_offenders+=("$v (present)")
done
for v in BOT TRAVIS CONTINUOUS_INTEGRATION; do
  [[ "${!v:-}" == "true" ]] && ci_offenders+=("$v=true")
done
if [[ -n "${AWS_REGION+x}" && -n "${CODEBUILD_INITIATOR+x}" ]]; then
  ci_offenders+=("AWS_REGION+CODEBUILD_INITIATOR")
fi
if [[ ${#ci_offenders[@]} -gt 0 ]]; then
  die "CI-detection variables are set: ${ci_offenders[*]}
     isRunningOnCI (shorebird_env.dart:299-324) would make canAcceptUserInput
     false for the CI reason, so arm 1 could not show the TTY predicate carried
     the run. Unset them and re-run. THIS IS WHY THIS HARNESS IS NOT A GITHUB
     WORKFLOW: GITHUB_ACTIONS is always set on a GitHub runner (:321)."
fi
note "CI detection vars        : none set"

# Auth. NEVER bake a key into a script — a dev key was leaked into a session
# transcript once and had to be rotated (HANDOFF, 2026-08-05). Read, never echo.
TOKEN_FILE="${TOKEN_FILE:-$HOME/.cps_token}"
if [[ -z "${SHOREBIRD_TOKEN:-}" ]]; then
  [[ -r "$TOKEN_FILE" ]] || die "no SHOREBIRD_TOKEN and no readable $TOKEN_FILE"
  SHOREBIRD_TOKEN="$(cat "$TOKEN_FILE")"
fi
[[ -n "$SHOREBIRD_TOKEN" ]] || die "SHOREBIRD_TOKEN is empty.
     An empty token is its own G10.2 arm (PARITY.md:2364) — run it deliberately,
     not by accident, or this harness measures the auth path instead of the guard."
export SHOREBIRD_TOKEN
note "SHOREBIRD_TOKEN          : set (${#SHOREBIRD_TOKEN} chars, not echoed)"

# Control plane must be OURS, and this is checked BEFORE the reachability probe
# so that a misconfigured run never sends even one request to upstream.
case "$SHOREBIRD_HOSTED_URL" in
  *shorebird.dev*)
    die "SHOREBIRD_HOSTED_URL points at upstream ($SHOREBIRD_HOSTED_URL).
     The entire point of G10.2 is that this runs against OUR control plane
     (e2e.yaml:60,:142 already cover upstream; that is the gap, not the goal)." ;;
esac
cp_code="$(curl -sS -o /dev/null -m 10 -w '%{http_code}' "$SHOREBIRD_HOSTED_URL/" || echo FAIL)"
[[ "$cp_code" == "200" ]] || die "control plane $SHOREBIRD_HOSTED_URL -> $cp_code"
note "control plane            : $SHOREBIRD_HOSTED_URL -> $cp_code"

command -v shorebird >/dev/null || die "shorebird not on PATH"
note "shorebird                : $(command -v shorebird)"

# --------------------------------------------------------------- versioning --
# Two releases, so the release-selection prompt is not skipped by
# release_chooser.dart:80-82, which short-circuits when exactly one release
# exists. The negative control depends on there being a real choice to make.
if [[ -z "$BASE_VERSION" ]]; then
  BASE_VERSION="$(sed -nE 's/^version:[[:space:]]*([^[:space:]#]+).*/\1/p' "$APP_DIR/pubspec.yaml" | head -1)"
fi
[[ -n "$BASE_VERSION" ]] || die "could not determine a release version from $APP_DIR/pubspec.yaml"
note "release version          : $BASE_VERSION"

# ------------------------------------------------------------------- arms ----
# Each arm redirects BOTH streams. `set -e` is suspended around the arms so a
# nonzero exit is DATA, not a crash.
run_arm() {
  local label="$1" log="$2"; shift 2
  say "$label"
  note "cmd: shorebird $*"
  local rc=0
  ( cd "$APP_DIR" && shorebird "$@" ) < /dev/null > "$log" 2>&1 || rc=$?
  note "exit: $rc  log: $log"
  return "$rc"
}

fail_count=0

# ---- arm 1: no --json. Proves the TTY predicate itself carried the run.
rc1=0
run_arm "arm 1 — release+patch, NO --json" "$NOTTY_LOG" \
  release android --no-confirm --release-version "$BASE_VERSION" || rc1=$?
if [[ "$rc1" -ne 0 ]]; then
  note "arm 1 release FAILED (exit $rc1)"; fail_count=$((fail_count + 1))
else
  rc1=0
  run_arm "arm 1 — patch, NO --json" "$NOTTY_LOG.patch" \
    patch android --no-confirm --release-version "$BASE_VERSION" || rc1=$?
  [[ "$rc1" -eq 0 ]] || { note "arm 1 patch FAILED (exit $rc1)"; fail_count=$((fail_count + 1)); }
fi

# ---- arm 2: with --json. The only arm where interactive_prompt_required can
# appear at all. A --json-only harness cannot distinguish "no TTY" from
# "--json", because interactive_mode.dart:19 short-circuits before any TTY test.
rc2=0
run_arm "arm 2 — patch, WITH --json" "$JSON_LOG" \
  --json patch android --no-confirm --release-version "$BASE_VERSION" || rc2=$?
[[ "$rc2" -eq 0 ]] || { note "arm 2 FAILED (exit $rc2)"; fail_count=$((fail_count + 1)); }

hits="$(grep -c 'interactive_prompt_required' "$JSON_LOG" || true)"
note "interactive_prompt_required in arm 2: $hits (expected 0)"
[[ "$hits" == "0" ]] || { note "arm 2 REACHED A PROMPT"; fail_count=$((fail_count + 1)); }

# ---- negative control. WITHOUT this, "0 hits" is indistinguishable from a
# broken grep or a harness that never reached the CLI. Omit --release-version
# so the release chooser (release_chooser.dart:76,92,102) MUST prompt; the
# guard must then convert it to ExitCode.usage (64) and, under --json, emit
# interactive_prompt_required (json_output.dart:54, runner :297 -> :315).
# A harness that cannot detect the failure it screens for is not a harness.
if [[ "$SKIP_NEGATIVE_CONTROL" -eq 0 ]]; then
  rcn=0
  run_arm "negative control — patch, --json, NO --release-version" "$NEG_LOG" \
    --json patch android --no-confirm || rcn=$?
  neg_hits="$(grep -c 'interactive_prompt_required' "$NEG_LOG" || true)"
  note "exit: $rcn (expected 64)   interactive_prompt_required: $neg_hits (expected >=1)"
  if [[ "$rcn" -ne 64 || "$neg_hits" == "0" ]]; then
    note "NEGATIVE CONTROL DID NOT FIRE — arm 2's clean result is UNINTERPRETABLE."
    note "Either the chooser was skipped (only one release exists?) or the guard"
    note "has a hole. Do not bank arm 2 until this is understood."
    fail_count=$((fail_count + 1))
  fi
fi

# ----------------------------------------------------------------- verdict ----
say "verdict"
if [[ "$fail_count" -eq 0 ]]; then
  note "PASS — both arms completed with no TTY against $SHOREBIRD_HOSTED_URL,"
  note "and the negative control proved a prompt WOULD have been detected."
  note ""
  note "This earns BUILT and nothing more. PROVEN for G10.2 requires the patch"
  note "from this CI-shaped invocation RUNNING ON A DEVICE (PARITY.md:3254-3261)."
  exit 0
fi
note "FAIL — $fail_count check(s) failed. Logs in $OUT_DIR"
exit 1
