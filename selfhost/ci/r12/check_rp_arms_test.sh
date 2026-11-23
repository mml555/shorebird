#!/usr/bin/env bash
# Tests check_rp_arms.sh against fixtures/rp_single_release.log, a copy of the
# rp.log of promotion cell f2458551 (one release, so arm 3 exited 0), and
# edited copies of it. That fixture is the `tail -40` capture the discovery
# script printed at the time (the script now prints 120 lines); do not
# complete it with earlier harness lines. rp_arm1_release_failed.log is the
# real a377ecb7 run 1, where arm 1 release failed and arm 1 patch never ran.
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
variant selftest_a_failed '/self-test A/,/self-test B/ s/exit: 64  log:/exit: 0  log:/'
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

# A harness that passed outright, in the discovery script's real wording
# (say() prints a blank line, then "== ... ==").
printf '\n== CLOSED — the frozen harness passed under seal with nothing refused ==\n' >"$tmp/closed.log"
expect closed 0 "$tmp/closed.log"
{ cat "$here/fixtures/rp_arm1_release_failed.log"; printf 'CLOSED — the frozen harness passed under seal\n'; } >"$tmp/closed_forged.log"
expect closed_substring_not_a_shortcut 1 "$tmp/closed_forged.log"
{ cat "$base"; cat "$tmp/closed.log"; } >"$tmp/closed_and_stop.log"
expect closed_with_stop 2 "$tmp/closed_and_stop.log"

# The real arm 1 failure: the harness skipped arm 1 patch. A failed check is 1.
expect real_arm1_release_failed 1 "$here/fixtures/rp_arm1_release_failed.log"
# drop_section <file> <header regex>: the file without that section.
drop_section() { awk -v pat="$2" '/^[[:space:]]*[|]?[[:space:]]*== /{skip=($0 ~ pat)} !skip' "$1"; }
drop_section "$tmp/arm1_release_failed.log" 'arm 1 — patch' >"$tmp/no_patch_section.log"
expect arm1_release_failed_patch_section_removed 1 "$tmp/no_patch_section.log"
# The patch section missing with nothing failed is unparseable, not a pass.
drop_section "$base" 'arm 1 — patch' >"$tmp/patch_gone.log"
expect patch_section_missing 2 "$tmp/patch_gone.log"

# One run per log.
{ cat "$tmp/arm1_release_failed.log"; cat "$base"; } >"$tmp/two_runs.log"
expect two_runs_in_one_log 2 "$tmp/two_runs.log"
{ cat "$base"; cat "$base"; } >"$tmp/twice.log"
expect same_run_twice 2 "$tmp/twice.log"
sed -E '/arm 1 — release/{p;s/exit: 0/exit: 0/;}' "$base" >"$tmp/dup_header.log"
expect duplicate_section_header 2 "$tmp/dup_header.log"
awk '/arm 1 — release/{f=1} f && /exit: 0  log:/ && !d {print; d=1} {print}' "$base" >"$tmp/dup_exit.log"
expect duplicate_exit_line 2 "$tmp/dup_exit.log"

# The harness's own wording alone is enough, with every exit line clean.
sed -E 's/^([[:space:]]*\|[[:space:]]*)(exit: 0  log: \/r12out\/disc\/ci_run_notty.log.patch)/\1\2\n\1arm 1 patch FAILED (exit 1)/' "$base" >"$tmp/wording_only.log"
expect harness_wording_only 1 "$tmp/wording_only.log"

# Log formats: CRLF, and the prefix bar with no space after it.
sed 's/$/\r/' "$base" >"$tmp/crlf.log"
expect crlf 0 "$tmp/crlf.log"
sed -E 's/^([[:space:]]*\|) /\1/' "$base" >"$tmp/nospace.log"
expect bar_without_space 0 "$tmp/nospace.log"

# Room for the harness to grow: 11 extra lines before self-test A.
sed -E '/self-test A/i\
     |    (note added by a later harness)' "$base" >"$tmp/ignored.log"
for _ in 1 2 3 4 5 6 7 8 9 10; do sed -E '/self-test A/i\
     |    (note added by a later harness)' "$tmp/ignored.log" >"$tmp/ignored2.log"; mv "$tmp/ignored2.log" "$tmp/ignored.log"; done
expect longer_preamble 0 "$tmp/ignored.log"

# A raw (unprefixed) harness log parses like the discovery script's indented one.
sed -E 's/^[[:space:]]*\| ?//' "$base" >"$tmp/raw.log"
expect raw_harness_log 0 "$tmp/raw.log"

exit "$failed"
