#!/usr/bin/env bash
# cspell:words caffeinate routebios interpretcall
#
# assert_mint_ready.sh -- may the cell be minted from this build?
#
# THE INVARIANT, and it is the whole file:
#
#   Mint only from VERDICT=success, where success requires BOTH the recorded ninja
#   exit AND the expected Flutter framework artifact. Anything else -- including
#   `unknown` -- means no mint.
#
# WHY THIS IS NOT JUST `echo $?`. `build_ios_release.sh` wraps its body in
# `{ ... } >>"$LOG" 2>&1` and the last statement inside that block is an `echo`.
# With `set -uo pipefail` and no `-e` it therefore exits 0 WHETHER OR NOT ninja
# succeeded. A mint gated on that status would be cut from a stale or partial
# out/ios_release and every downstream device gate would be measuring the wrong
# toolchain -- while every check reported success.
#
# WHY THIS RE-DERIVES RATHER THAN TRUSTING A SUMMARY LINE. The driver writes its own
# VERDICT= line, and this deliberately does not take that as the answer. It reads the
# PRIMITIVES the invariant names -- the ninja exit code the build recorded with `$?`
# and nothing piped, and the existence of the framework binary -- and decides again.
# A summary that disagrees with its own primitives is itself a finding, reported here
# rather than silently preferred either way.
#
#   assert_mint_ready.sh [path/to/mint_build.status]
#
# exit 0  ready: VERDICT=success
# exit 1  not ready, and it says which primitive failed
# exit 2  the build has not finished, or no status exists at all
set -uo pipefail

STATUS=${1:-/Volumes/build/route-b/logs/mint_build.status}

say() { printf '%s\n' "$*"; }

if [ ! -f "$STATUS" ]; then
  say "status  : MISSING ($STATUS)"
  say "VERDICT=failed"
  say
  say "No build status exists. Absence is not success: either the detached build was"
  say "never started, or it died before writing anything."
  exit 2
fi

# Read the file rather than pipe it, so a truncated read cannot look like a value.
state=$(sed -n 's/^state=//p' "$STATUS" | tail -1)
ninja_rc=$(sed -n 's/^ninja_rc=//p' "$STATUS" | tail -1)
framework=$(sed -n 's/^framework=//p' "$STATUS" | tail -1)
recorded=$(sed -n 's/^VERDICT=//p' "$STATUS" | tail -1)
log=$(sed -n 's/^log=//p' "$STATUS" | tail -1)
symbols=$(sed -n 's/^interpretcall_symbols=//p' "$STATUS" | tail -1)

say "status  : $STATUS"
say "state   : ${state:-<none>}"
say "log     : ${log:-<none>}"

if [ "$state" != "finished" ]; then
  say "VERDICT=failed"
  say
  say "The build has not finished (state=${state:-<none>}). Nothing to mint from yet,"
  say "and out/ios_release must stay frozen until it does."
  exit 2
fi

ok=1
if [ "$ninja_rc" = "0" ]; then
  say "ninja   : exit 0"
else
  say "ninja   : exit ${ninja_rc:-unknown}   <- NOT SUCCESS"
  ok=0
fi

if [ -n "$framework" ] && [ "$framework" != "<none>" ] && [ -f "$framework" ]; then
  live_bytes=$(wc -c < "$framework" | tr -d ' ')
  say "artifact: $framework"
  say "          ${live_bytes} bytes, interpretcall symbols ${symbols:-?}"

  # STALENESS GUARD. Everything above this line except "the file exists" comes
  # from the STATUS FILE, so without this check the answer is about whatever
  # build wrote that file -- not about the artifact on disk now.
  #
  # The failure it prevents is not hypothetical and is the expensive kind: run
  # build_ios_release.sh directly (the documented detached invocation does
  # exactly that) and the status file is NOT rewritten. If that build fails, the
  # previous run's `state=finished, ninja_rc=0` is still sitting there, the
  # framework from the PREVIOUS build is still on disk, and this script would
  # say "the cell may be minted from this out/ios_release" -- minting the old
  # engine while believing it is the new one. A stale green is worse than a red,
  # because a mint is what the whole cell address rests on.
  #
  # Caught 2026-08-14 in exactly that configuration: status recorded
  # framework_bytes=19071568 from the prior day while the live artifact was
  # 19072784. The build had genuinely succeeded, so the verdict was right by
  # luck; the reasoning that produced it was not.
  recorded_bytes=$(sed -n 's/^framework_bytes=//p' "$STATUS" | tail -1)
  if [ -n "$recorded_bytes" ] && [ "$recorded_bytes" != "$live_bytes" ]; then
    say "          <- STALE STATUS: recorded ${recorded_bytes} bytes, on disk ${live_bytes}"
    say
    say "The status file describes a DIFFERENT build than the artifact on disk."
    say "Every check above except file existence is read from that status, so"
    say "this verdict would be about the wrong build. Re-run through"
    say "run_mint_build.sh so the status matches, then ask again."
    ok=0
  fi
else
  say "artifact: MISSING (${framework:-<none>})   <- NOT SUCCESS"
  ok=0
fi

# The recorded summary is compared, never preferred. `ok` is this driver's own
# spelling of success; the invariant's spelling is `success`.
case "$recorded" in
  ok|success) recorded_says=success ;;
  *)          recorded_says="${recorded:-<none>}" ;;
esac
say "recorded: ${recorded:-<none>} (normalised: $recorded_says)"

derived=failed
[ "$ok" = 1 ] && derived=success
if [ "$recorded_says" != "$derived" ]; then
  say
  say "DISAGREEMENT: the build's own summary says '$recorded_says' while its"
  say "primitives say '$derived'. That is a defect in the driver, not a mint"
  say "decision -- resolve it before minting either way."
  say "VERDICT=failed"
  exit 1
fi

say
if [ "$derived" = success ]; then
  say "VERDICT=success"
  say
  say "Both primitives hold: ninja exited 0 and the framework exists. The cell may be"
  say "minted from this out/ios_release."
  exit 0
fi

say "VERDICT=failed"
say
say "No mint. Fix the build first; a cell minted from this tree would make every"
say "device gate downstream measure the wrong toolchain."
exit 1
