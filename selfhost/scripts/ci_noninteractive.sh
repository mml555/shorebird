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
# WHY `CI` MUST BE UNSET — the honest version. isRunningOnCI
# (shorebird_env.dart:299-324) fires on the mere PRESENCE of CI (:305),
# APPVEYOR (:308), CIRRUS_CI (:311), JENKINS_URL (:318), GITHUB_ACTIONS (:321)
# or TF_BUILD (:324) — so even CI=false counts — or on BOT/TRAVIS/
# CONTINUOUS_INTEGRATION set to "true" (:300-304), or AWS_REGION +
# CODEBUILD_INITIATOR together (:314-315). Requiring all of them unset does NOT
# make arm 1 discriminating (see arm 1's own comment — it reaches no prompt
# either way). What it buys is ATTRIBUTION: with them unset, the only reason the
# CLI is non-interactive is that the two streams are not terminals. That is the
# condition the SELF-TEST below measures, and it is the one a GitHub runner
# cannot produce.
#
#   ci_noninteractive.sh --app-dir <dir> [--release-version <ver>] [--out <dir>]
#   ci_noninteractive.sh --self-test-only            # no app, no build, any host
#
# RUN THE ARMS ON THE LINUX BUILD BOX. See "HOST" in the preflight — this is a
# verified artifact constraint, not a preference. The detector self-test runs
# first and is host-independent, on purpose; --self-test-only stops after it, so
# any host can check that this harness can still see a prompt.
set -euo pipefail

APP_DIR=""
OUT_DIR=""
BASE_VERSION=""
SELF_TEST_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-dir) APP_DIR="${2:?--app-dir needs a value}"; shift 2 ;;
    --release-version) BASE_VERSION="${2:?--release-version needs a value}"; shift 2 ;;
    --out) OUT_DIR="${2:?--out needs a value}"; shift 2 ;;
    --self-test-only) SELF_TEST_ONLY=1; shift ;;
    -h|--help) sed -n '3,49p' "${BASH_SOURCE[0]}"; exit 0 ;;
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
SELFTEST_LOG="$OUT_DIR/detector_selftest.log"
SELFTEST_JSON_LOG="$OUT_DIR/detector_selftest_json.log"

# ---------------------------------------------------------------- preflight --
say "preflight"

if [[ "$SELF_TEST_ONLY" -eq 1 ]]; then
  note "mode                     : --self-test-only (no app, no build, no arms)"
else
  [[ -n "$APP_DIR" ]] || die "--app-dir is required (or pass --self-test-only).
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
fi

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

# CI must be unset — for ATTRIBUTION, not for arm 1 (see header).
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
     false for the CI reason, so the self-test's refusal could no longer be
     attributed to the streams. Unset them and re-run. THIS IS WHY THIS HARNESS
     IS NOT A GITHUB WORKFLOW: GITHUB_ACTIONS is always set on a runner (:321)."
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
     An empty token is its own G10.2 arm (PARITY.md:2377) — run it deliberately,
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

# ----------------------------------------------- runner used by every stage --
# Every invocation redirects BOTH streams. `set -e` is suspended around them so
# a nonzero exit is DATA, not a crash.
run_in() {
  local dir="$1" label="$2" log="$3"; shift 3
  say "$label"
  note "cmd: (cd $dir && shorebird $*)"
  local rc=0
  ( cd "$dir" && shorebird "$@" ) < /dev/null > "$log" 2>&1 || rc=$?
  note "exit: $rc  log: $log"
  return "$rc"
}

fail_count=0

# -------------------------------------------------- detector self-test -------
# WITHOUT THIS, "0 hits of interactive_prompt_required in arm 2" is
# indistinguishable from a broken grep, a misnamed log, or a harness that never
# reached the CLI at all. This stage reaches a REAL prompt site and requires it
# to be refused for the right reason.
#
# WHY IT IS *NOT* THE RELEASE CHOOSER. The obvious control — `patch android`
# with --release-version omitted, so the release chooser must prompt — CANNOT
# FIRE ON ANY HOST. patch_command.dart:396-404 reaches promptForRelease (:403)
# only from the `else if (shorebirdEnv.canAcceptUserInput)` arm at :402, and
# canAcceptUserInput is `stdin.hasTerminal && !isRunningOnCI && !isJsonMode`
# (shorebird_env.dart:292-293). Every way of making a run non-interactive —
# redirected stdin, a CI variable, or --json — also makes :402 false, so control
# falls through to the plain `else` at :404, warns, and does a SPECULATIVE BUILD
# to infer the version. The prompt is unreachable by construction. The other
# prompt in that path, patch_command.dart:1064's "Would you like to continue?",
# is gated the same way (`confirm && shorebirdEnv.canAcceptUserInput`).
#
# WHAT IS REACHABLE. preview_command.dart:152-158's flavor chooser has NO
# canAcceptUserInput gate and runs before any network call:
#     } else if (shorebirdYaml != null && flavors != null) {
#       final chosenFlavor = logger.chooseOne<String>('Which app flavor?', ...)
# `preview` validates only checkUserIsAuthenticated (preview_command.dart:129-131
# -> shorebird_validator.dart:79-89), and auth.dart:357-360 accepts an `sb_api_`
# key by shape alone, so this stage needs no project, no build, and no server
# round trip. It reaches chooseOne, hits shorebird_logger.dart:136, and the
# runner converts it at shorebird_cli_command_runner.dart:297-315 to
# ExitCode.usage (64) — plus, under --json, the JsonErrorCode
# `interactive_prompt_required` (json_output.dart:54) that arm 2 greps for.
#
# THIS IS ALSO THE ONLY STAGE THAT MEASURES THE TTY PREDICATE. CI vars are
# unset (asserted above) and the no-json run passes no --json, so the ONLY
# reason isInteractive and canAcceptUserInput are false is that stdout and stdin
# are not terminals. Arm 1 cannot show this; this can.
#
# It is host-independent by design, so it runs BEFORE the Linux host gate: a Mac
# can prove the detector works even though it cannot run the arms.
SELFTEST_DIR="$OUT_DIR/detector_selftest_app"
mkdir -p "$SELFTEST_DIR"
# Two flavors so `flavors != null` and the chooser is entered. app_id is
# deliberately not a real app: the chooser throws before any request. base_url
# points at OUR control plane so that even a future code change that did make a
# call could not reach upstream.
cat > "$SELFTEST_DIR/shorebird.yaml" <<EOF
# Generated by ci_noninteractive.sh. Throwaway: never released, never patched.
app_id: ci-noninteractive-detector-selftest
flavors:
  foo: ci-noninteractive-detector-selftest
  bar: ci-noninteractive-detector-selftest
base_url: $SHOREBIRD_HOSTED_URL
EOF

rcs=0
run_in "$SELFTEST_DIR" "self-test A — preview, NO --json (TTY predicate only)" \
  "$SELFTEST_LOG" preview || rcs=$?
sel_hits="$(grep -c 'running in a non-interactive context' "$SELFTEST_LOG" || true)"
note "exit: $rcs (expected 64)   'non-interactive context' lines: $sel_hits (expected >=1)"
if [[ "$rcs" -ne 64 || "$sel_hits" == "0" ]]; then
  note "SELF-TEST A DID NOT FIRE. Without --json the refusal is the human-readable"
  note "branch at shorebird_cli_command_runner.dart:305-313, NOT the JSON code."
  note "If this fails, the streams are not what the preflight thinks they are."
  fail_count=$((fail_count + 1))
fi

rcsj=0
run_in "$SELFTEST_DIR" "self-test B — preview, WITH --json (arm 2's exact grep)" \
  "$SELFTEST_JSON_LOG" --json preview || rcsj=$?
selj_hits="$(grep -c 'interactive_prompt_required' "$SELFTEST_JSON_LOG" || true)"
note "exit: $rcsj (expected 64)   interactive_prompt_required: $selj_hits (expected >=1)"
if [[ "$rcsj" -ne 64 || "$selj_hits" == "0" ]]; then
  note "SELF-TEST B DID NOT FIRE — arm 2's grep is NOT KNOWN TO WORK, so a clean"
  note "arm 2 would be uninterpretable. Do not bank arm 2 until this passes."
  fail_count=$((fail_count + 1))
fi

if [[ "$fail_count" -ne 0 ]]; then
  say "verdict"
  note "FAIL — the detector self-test did not fire. Nothing downstream is"
  note "interpretable, so the arms are not run. Logs in $OUT_DIR"
  exit 1
fi

if [[ "$SELF_TEST_ONLY" -eq 1 ]]; then
  say "verdict"
  note "SELF-TEST ONLY — the detector fires: a reached prompt exits 64 and is"
  note "named, in both output modes. The ARMS DID NOT RUN, so this says nothing"
  note "about the release/patch workflow. PARITY :2375/:2376 are untouched."
  exit 0
fi

# ------------------------------------------------------------------- host ----
# Checked AFTER the self-test so the self-test is available on every host.
# Our gen_snapshot is linux-x64 only. A macOS host doing an Android arm64
# release downloads android-arm64-release/darwin-x64.zip
# (vendor/flutter/packages/flutter_tools/lib/src/flutter_cache.dart:900); our
# mirror 404s exactly that path while serving the linux-x64 sibling at :909.
# Probed against the mirror 2026-08-13:
#   android-arm64-release/linux-x64.zip  -> 200
#   android-arm64-release/darwin-x64.zip -> 404
# NOTE THE EVIDENCE CLASS: that is a probe of the MIRROR, not an observation of
# these arms failing at the artifact stage. No run on this Mac has ever reached
# the artifact fetch — invocations here die earlier, at token parsing (exit 70,
# auth.dart:373-381). So the gate below encodes a PREDICTED blocker, refusing
# early rather than failing deep inside a build with a confusing artifact error.
host_os="$(uname -s)"
if [[ "$host_os" != "Linux" ]]; then
  die "host is $host_os; the ARMS require Linux (the self-test above already ran).
     Our gen_snapshot is linux-x64 only and the mirror 404s
     android-arm64-release/darwin-x64.zip. Re-verify with:
       curl -sS -o /dev/null -w '%{http_code}\\n' \\
         \"\$FLUTTER_STORAGE_BASE_URL/flutter_infra_release/flutter/<rev>/android-arm64-release/darwin-x64.zip\""
fi
note "host                     : $host_os"

# --------------------------------------------------------------- versioning --
if [[ -z "$BASE_VERSION" ]]; then
  BASE_VERSION="$(sed -nE 's/^version:[[:space:]]*([^[:space:]#]+).*/\1/p' "$APP_DIR/pubspec.yaml" | head -1)"
fi
[[ -n "$BASE_VERSION" ]] || die "could not determine a release version from $APP_DIR/pubspec.yaml"
note "release version          : $BASE_VERSION"

# ------------------------------------------------------------------- arms ----
# ---- arm 1: no --json.
# WHAT ARM 1 SHOWS: that the real release+patch workflow RUNS TO COMPLETION
# against our control plane with neither stream a terminal and without --json —
# i.e. nothing on the happy path needs a prompt, and the non-interactive output
# path (static Progress, shorebird_logger.dart:118-128, no ANSI) does not break
# it.
# WHAT ARM 1 DOES NOT SHOW: that the TTY predicate carried the run. It passes
# --release-version (taken at patch_command.dart:396, before :402) and
# --no-confirm (which makes :1064's `confirm &&` false), so NO prompt site is
# reached whatever the predicate says. A pass here is equally consistent with
# the predicate doing nothing. The detector self-test above is what exercises
# the predicate.
# NOTE: `--release-version` is a PATCH flag. `release android` rejects it with
# "The \"--release-version\" flag is only supported for aar and ios-framework
# releases." and exits 64 — which this harness previously reported as an arm
# failure, indistinguishable at a glance from the guard firing. Measured on
# hermes-vps 2026-08-14. A release takes its version from pubspec.yaml, which is
# where $BASE_VERSION was read from in the first place.
rc1=0
run_in "$APP_DIR" "arm 1 — release, NO --json" "$NOTTY_LOG" \
  release android --no-confirm || rc1=$?
if [[ "$rc1" -ne 0 ]]; then
  note "arm 1 release FAILED (exit $rc1)"; fail_count=$((fail_count + 1))
else
  rc1=0
  run_in "$APP_DIR" "arm 1 — patch, NO --json" "$NOTTY_LOG.patch" \
    patch android --no-confirm --release-version "$BASE_VERSION" || rc1=$?
  [[ "$rc1" -eq 0 ]] || { note "arm 1 patch FAILED (exit $rc1)"; fail_count=$((fail_count + 1)); }
fi

# ---- arm 2: with --json. The only arm where interactive_prompt_required can
# appear at all. A --json-only harness cannot distinguish "no TTY" from
# "--json", because interactive_mode.dart:19 short-circuits before any TTY test.
rc2=0
run_in "$APP_DIR" "arm 2 — patch, WITH --json" "$JSON_LOG" \
  --json patch android --no-confirm --release-version "$BASE_VERSION" || rc2=$?
[[ "$rc2" -eq 0 ]] || { note "arm 2 FAILED (exit $rc2)"; fail_count=$((fail_count + 1)); }

hits="$(grep -c 'interactive_prompt_required' "$JSON_LOG" || true)"
note "interactive_prompt_required in arm 2: $hits (expected 0)"
[[ "$hits" == "0" ]] || { note "arm 2 REACHED A PROMPT"; fail_count=$((fail_count + 1)); }

# ----------------------------------------------------------------- verdict ----
say "verdict"
if [[ "$fail_count" -eq 0 ]]; then
  note "PASS — the detector self-test fired (so a prompt WOULD have been seen),"
  note "and both arms completed with no TTY against $SHOREBIRD_HOSTED_URL."
  note ""
  note "PARITY.md:2375 names exactly this arm as what its row requires; :2376 is"
  note "its patch twin. A green run here is the evidence for them — it is NOT"
  note "self-certifying. PROVEN means the real product workflow completed and the"
  note "observable result was verified (PARITY.md:3582-3583); a script printing"
  note "PASS is not that verification. Record the logs and let the row be moved"
  note "by whoever reads them."
  exit 0
fi
note "FAIL — $fail_count check(s) failed. Logs in $OUT_DIR"
exit 1
