#!/usr/bin/env bash
#
# Gates the "sealed release/patch discovery" step of the toolchain promotion
# chain (selfhost/TOOLCHAIN_PROMOTION.md). It reads the log of
# discover_release_closure.sh, which wraps selfhost/scripts/ci_noninteractive.sh.
#
# With a single release on the control plane the harness verdict is FAIL by
# design: arm 3 (patch with no --release-version, the release chooser) has one
# release to pick, so it never prompts and exits 0 instead of the expected 64.
# Gating on "NOTHING refused by the seal" alone also passes a run where arm 1,
# arm 2 or a detector self-test failed. This accepts the log only when:
#
#   - the seal refused nothing ("NOTHING refused by the seal"), or the log is a
#     run that ended "== CLOSED" with no "== STOP" (the harness passed outright);
#   - self-test A and B each exited 64 and fired their detector at least once;
#   - arm 1 (release, then patch) exited 0;
#   - arm 2 exited 0 with interactive_prompt_required 0;
#   - arm 3 exited 0, the expected single-release result, and that is the ONLY
#     failed check ("FAIL — 1 check(s) failed"). A verdict PASS (two or more
#     releases, arm 3 refused the chooser) is accepted too.
#
# Each section must appear once and carry one exit line: a log that holds two
# runs (a `tee -a` into a stale file, two discoveries in one file) is not one
# run's evidence. A failed check is exit 1 even when something else cannot be
# parsed (the harness skips arm 1 patch after a failed arm 1 release, so a real
# arm 1 failure has no patch section). Anything else it cannot find or parse is
# exit 2, never a pass.
#
# COUPLING: the matched strings (section headers, "exit: N  log:", the detector
# counters, "FAIL — N check(s) failed", the em dash) are the wording of
# selfhost/scripts/ci_noninteractive.sh and discover_release_closure.sh. A
# reworded harness gives exit 2 here, not a pass; check_rp_arms_test.sh runs on
# edits to both scripts.
#
# Usage: selfhost/ci/r12/check_rp_arms.sh <rp.log>
#   rp.log is the discovery script's output, e.g.
#   discover_release_closure.sh 2>&1 | tee rp.log
# Exit: 0 the arms block is acceptable, 1 a check failed, 2 unreadable or
# unparseable (including a missing arms block).
set -uo pipefail

[ $# -eq 1 ] && [ -f "$1" ] || { echo "usage: check_rp_arms.sh <rp.log>" >&2; exit 2; }
log=$1
name=check_rp_arms

# The discovery script indents the harness tail with "     | "; strip it so a
# raw harness log parses the same way. CRs go too (a log saved on Windows).
text=$(tr -d '\r' <"$log" | sed -E 's/^[[:space:]]*\|[[:space:]]?//') || exit 2

if grep -q '^== CLOSED — the frozen harness passed under seal' <<<"$text"; then
  if grep -q '^== STOP' <<<"$text"; then
    echo "$name: a CLOSED line and a STOP line in one log: $log" >&2; exit 2
  fi
  echo "$name: ok (harness passed outright, nothing refused)"
  exit 0
fi

bad=0
# miss() is also called inside $(...), so its flag lives in a file.
unparsed_flag=$(mktemp) || exit 2
trap 'rm -f "$unparsed_flag"' EXIT
fail() { echo "$name: FAILED: $*" >&2; bad=1; }
miss() { echo "$name: cannot parse: $*" >&2; echo 1 >>"$unparsed_flag"; }

if ! grep -q 'NOTHING refused by the seal' <<<"$text"; then
  if grep -q '^== STOP' <<<"$text"; then
    fail "the seal refused something, or the run stopped for another reason"
  else
    miss "no STOP or CLOSED line: not a discovery log"
  fi
fi

# The lines of the section whose header matches $1, up to the next header.
section() {
  awk -v pat="$1" '
    /^[[:space:]]*== / { on = ($0 ~ pat); next }
    on { print }' <<<"$text"
}
headers() { grep -cE "$1" <<<"$text"; }
num() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

# The one number captured by sed expression $2 in section $1: empty, with a
# parse failure noted, unless the section is unique and the line occurs once.
one() { # <section pattern> <label> <sed -E s/// capturing \1>
  local n lines
  n=$(headers "$1")
  if [ "$n" -ne 1 ]; then miss "$2: $n sections, expected 1"; return; fi
  lines=$(section "$1" | sed -nE "$3")
  case $(grep -c . <<<"$lines") in
    1) printf '%s' "$lines" ;;
    0) miss "$2: line not found" ;;
    *) miss "$2: line occurs more than once" ;;
  esac
}
exit_line='s/^[[:space:]]*exit: ([0-9]+)[[:space:]]+log:.*/\1/p'
exit_of() { one "$1" "$2 exit" "$exit_line"; }
count_of() { one "$1" "$2" "s/.*$3: ([0-9]+)([^0-9]|\$).*/\\1/p"; }

check_exit() { # <section pattern> <label> <expected exit>
  local rc; rc=$(exit_of "$1" "$2")
  if num "$rc" && [ "$rc" -ne "$3" ]; then fail "$2 exited $rc, expected $3"; fi
}
check_detector() { # <section pattern> <label> <counter text>
  local rc n
  rc=$(exit_of "$1" "$2"); n=$(count_of "$1" "$2 detector" "$3")
  if num "$rc" && [ "$rc" -ne 64 ]; then fail "$2 exited $rc, expected 64"; fi
  if num "$n" && [ "$n" -lt 1 ]; then fail "$2: detector fired $n times, expected at least 1"; fi
}

check_detector '^[[:space:]]*== self-test A'  'self-test A' "'non-interactive context' lines"
check_detector '^[[:space:]]*== self-test B'  'self-test B' 'interactive_prompt_required'
check_exit '^[[:space:]]*== arm 1 .*release' 'arm 1 release' 0
check_exit '^[[:space:]]*== arm 1 .*patch'   'arm 1 patch' 0
check_exit '^[[:space:]]*== arm 2'           'arm 2' 0
n=$(count_of '^[[:space:]]*== arm 2' 'arm 2 prompt count' 'interactive_prompt_required in arm 2')
if num "$n" && [ "$n" -ne 0 ]; then fail "arm 2 reached a prompt (interactive_prompt_required $n)"; fi

# The harness words each failed check "... FAILED" or "REACHED A PROMPT".
wording='(arm [0-9][^:]* FAILED|REACHED A PROMPT|did not fire)'
if grep -qE "$wording" <<<"$text"; then
  fail "the harness reported a failed arm: $(grep -E "$wording" <<<"$text" | head -3 | tr '\n' ';')"
fi

rc3=$(exit_of '^[[:space:]]*== arm 3' 'arm 3')
v='^[[:space:]]*== verdict'
if [ "$(headers "$v")" -ne 1 ]; then
  miss "verdict: $(headers "$v") sections, expected 1"
else
  verdict_lines=$(section "$v" | sed -nE 's/^[[:space:]]*(PASS|FAIL) — .*/&/p')
  if [ "$(grep -c . <<<"$verdict_lines")" -ne 1 ]; then miss "verdict: not exactly one PASS/FAIL line"
  elif [[ $verdict_lines =~ ^[[:space:]]*PASS ]]; then
    if num "$rc3" && [ "$rc3" -ne 64 ]; then fail "verdict PASS but arm 3 exited $rc3"; fi
  else
    failed_checks=$(sed -nE 's/^[[:space:]]*FAIL — ([0-9]+) check\(s\) failed.*/\1/p' <<<"$verdict_lines")
    if ! num "$failed_checks"; then miss "verdict: no failed-check count"
    elif [ "$failed_checks" -ne 1 ] || { num "$rc3" && [ "$rc3" -ne 0 ]; }; then
      fail "verdict FAIL with $failed_checks check(s) failed and arm 3 exit $rc3: only arm 3's single-release exit 0 is expected"
    fi
  fi
fi

[ "$bad" -eq 0 ] || exit 1
if [ -s "$unparsed_flag" ]; then echo "$name: unparseable, treating as not passed: $log" >&2; exit 2; fi
echo "$name: ok (arms 1 and 2 and both self-tests pass; arm 3 is the expected single-release exit 0)"
