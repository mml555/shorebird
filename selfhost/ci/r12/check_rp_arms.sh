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
#   - the seal refused nothing ("NOTHING refused by the seal"), or the harness
#     passed outright ("CLOSED");
#   - self-test A and B each exited 64 and fired their detector at least once;
#   - arm 1 (release, then patch) exited 0;
#   - arm 2 exited 0 with interactive_prompt_required 0;
#   - arm 3 exited 0, the expected single-release result, and that is the ONLY
#     failed check ("FAIL — 1 check(s) failed"). A verdict PASS (two or more
#     releases, arm 3 refused the chooser) is accepted too.
#
# Anything it cannot find or parse is exit 2, never a pass.
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
# raw harness log parses the same way.
text=$(sed -E 's/^[[:space:]]*\|[[:space:]]?//' "$log") || exit 2

if grep -q 'CLOSED — the frozen harness passed under seal' <<<"$text"; then
  echo "$name: ok (harness passed outright, nothing refused)"
  exit 0
fi

bad=0
unparsed=0
fail() { echo "$name: FAILED: $*" >&2; bad=1; }
miss() { echo "$name: cannot parse: $*" >&2; unparsed=1; }

grep -q 'NOTHING refused by the seal' <<<"$text" \
  || fail "the seal refused something, or the run stopped for another reason"

# The lines of the section whose header matches $1, up to the next header.
section() {
  awk -v pat="$1" '
    /^[[:space:]]*== / { on = ($0 ~ pat); next }
    on { print }' <<<"$text"
}
# The N of the last "<label> N" in section $1, empty if absent.
exit_of() { section "$1" | sed -nE 's/^[[:space:]]*exit: ([0-9]+).*/\1/p' | tail -1; }
count_of() { section "$1" | sed -nE "s/.*$2: ([0-9]+) .*/\\1/p" | tail -1; }
num() { [[ ${1:-} =~ ^[0-9]+$ ]]; }

check_exit() { # <section pattern> <label> <expected exit>
  local rc; rc=$(exit_of "$1")
  if ! num "$rc"; then miss "$2: no exit line"; elif [ "$rc" -ne "$3" ]; then fail "$2 exited $rc, expected $3"; fi
}
check_detector() { # <section pattern> <label> <counter text>
  local rc n; rc=$(exit_of "$1"); n=$(count_of "$1" "$3")
  if ! num "$rc" || ! num "$n"; then miss "$2: no exit or detector count"; return; fi
  [ "$rc" -eq 64 ] || fail "$2 exited $rc, expected 64"
  [ "$n" -ge 1 ] || fail "$2: detector fired $n times, expected at least 1"
}

check_detector '^[[:space:]]*== self-test A'  'self-test A' "'non-interactive context' lines"
check_detector '^[[:space:]]*== self-test B'  'self-test B' 'interactive_prompt_required'
check_exit '^[[:space:]]*== arm 1 .*release' 'arm 1 release' 0
check_exit '^[[:space:]]*== arm 1 .*patch'   'arm 1 patch' 0
check_exit '^[[:space:]]*== arm 2'           'arm 2' 0
n=$(count_of '^[[:space:]]*== arm 2' 'interactive_prompt_required in arm 2')
if ! num "$n"; then miss "arm 2: no interactive_prompt_required count"
elif [ "$n" -ne 0 ]; then fail "arm 2 reached a prompt (interactive_prompt_required $n)"; fi

# The harness words each failed check "... FAILED" or "REACHED A PROMPT".
if grep -qE '(arm [0-9][^:]* FAILED|REACHED A PROMPT|did not fire)' <<<"$text"; then
  fail "the harness reported a failed arm: $(grep -E '(arm [0-9][^:]* FAILED|REACHED A PROMPT|did not fire)' <<<"$text" | head -3 | tr '\n' ';')"
fi

rc3=$(exit_of '^[[:space:]]*== arm 3')
verdict=$(sed -nE 's/^[[:space:]]*(PASS|FAIL) — .*/\1/p' <<<"$(section '^[[:space:]]*== verdict')" | head -1)
failed_checks=$(section '^[[:space:]]*== verdict' | sed -nE 's/^[[:space:]]*FAIL — ([0-9]+) check\(s\) failed.*/\1/p' | head -1)
if ! num "$rc3"; then miss "arm 3: no exit line"
elif [ "$verdict" = PASS ]; then
  [ "$rc3" -eq 64 ] || fail "verdict PASS but arm 3 exited $rc3"
elif [ "$verdict" = FAIL ]; then
  if ! num "$failed_checks"; then miss "verdict: no failed-check count"
  elif [ "$rc3" -ne 0 ] || [ "$failed_checks" -ne 1 ]; then
    fail "verdict FAIL with $failed_checks check(s) failed and arm 3 exit $rc3: only arm 3's single-release exit 0 is expected"
  fi
else
  miss "verdict: neither PASS nor FAIL"
fi

if [ "$unparsed" -ne 0 ]; then echo "$name: unparseable, treating as not passed: $log" >&2; exit 2; fi
[ "$bad" -eq 0 ] || exit 1
echo "$name: ok (arms 1 and 2 and both self-tests pass; arm 3 is the expected single-release exit 0)"
