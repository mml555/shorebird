#!/usr/bin/env bash
# Tests check_rp_arms.sh against fixtures/rp_single_release.log, a copy of the
# rp.log of promotion cell f2458551 (one release, so arm 3 exited 0), and
# edited copies of it.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chk="$here/check_rp_arms.sh"
base="$here/fixtures/rp_single_release.log"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
failed=0

# expect <name> <exit> <file>
expect() {
  "$chk" "$3" >"$tmp/out" 2>&1; local rc=$?
  if [ "$rc" -eq "$2" ]; then echo "ok   $1"; else echo "FAIL $1: exit $rc, wanted $2"; sed 's/^/     /' "$tmp/out"; failed=1; fi
}
# variant <name> <sed script>: an edited copy of the real log
variant() { sed -E "$2" "$base" >"$tmp/$1.log"; }

expect passing_log 0 "$base"

variant arm1_release_failed '/arm 1 — release/,/log:/ s/exit: 0/exit: 1/'
expect arm1_release_failed 1 "$tmp/arm1_release_failed.log"
variant arm1_patch_failed '/arm 1 — patch/,/log:/ s/exit: 0/exit: 1/'
expect arm1_patch_failed 1 "$tmp/arm1_patch_failed.log"
variant arm2_prompt '/arm 2/,/verdict/ s/arm 2: 0 \(expected 0\)/arm 2: 3 (expected 0)/'
expect arm2_prompt_reached 1 "$tmp/arm2_prompt.log"
variant arm2_failed '/arm 2 — patch/,/log:/ s/exit: 0/exit: 70/'
expect arm2_failed 1 "$tmp/arm2_failed.log"
variant selftest_a_failed '/self-test A/,/self-test B/ s/exit: 64 \(expected 64\)/exit: 0 (expected 64)/'
expect selftest_a_failed 1 "$tmp/selftest_a_failed.log"
variant selftest_b_silent '/self-test B/,/arm 1/ s/interactive_prompt_required: 1 /interactive_prompt_required: 0 /'
expect selftest_b_silent 1 "$tmp/selftest_b_silent.log"
variant two_failures 's/FAIL — 1 check/FAIL — 2 check/'
expect verdict_two_failures 1 "$tmp/two_failures.log"
variant arm3_ok_but_fail '/arm 3 — patch/,/verdict/ s/exit: 0/exit: 70/'
expect arm3_other_failure 1 "$tmp/arm3_ok_but_fail.log"
variant seal_refused 's/NOTHING refused by the seal/2 artifacts refused/'
expect seal_refused 1 "$tmp/seal_refused.log"

# No arms block at all (the discovery script stopped before the harness ran),
# a truncated block, an empty file, a missing file, and a verdict with no number.
grep -v -e 'arm [12]' -e 'self-test' "$base" >"$tmp/no_arms.log"
expect missing_arms_block 2 "$tmp/no_arms.log"
sed '/== arm 2/,$d' "$base" >"$tmp/truncated.log"
expect truncated_log 2 "$tmp/truncated.log"
: >"$tmp/empty.log"
expect empty_log 2 "$tmp/empty.log"
expect missing_file 2 "$tmp/nope.log"
variant no_count 's/FAIL — 1 check\(s\) failed/FAIL — some checks failed/'
expect verdict_without_count 2 "$tmp/no_count.log"

# A harness that passed outright is accepted; a raw (unprefixed) harness log
# parses like the discovery script's indented one.
printf '== CLOSED — the frozen harness passed under seal with nothing refused ==\n' >"$tmp/closed.log"
expect closed 0 "$tmp/closed.log"
sed -E 's/^[[:space:]]*\| ?//' "$base" >"$tmp/raw.log"
expect raw_harness_log 0 "$tmp/raw.log"

exit "$failed"
