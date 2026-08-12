#!/usr/bin/env bash
# cspell:words rbtrace
#
# assert_diagnostic_engine.sh -- prove the iOS engine published under a hash is
# THE INSTRUMENTED ONE, before any release is cut against it.
#
# WHY THIS IS A GATE AND NOT A GLANCE. `mint_route_b_cell.sh --donor` clones the
# donor's engine artifacts byte-for-byte, on the assumption that the engine binary
# is unchanged. That assumption held for every previous mint and is FALSE for a
# diagnostic build. Measured, not argued: `50d58cc3` and `ee001fd7` ship the
# identical `ios-release/artifacts.zip` -- same sha256, same 14,663,308 bytes.
#
# So without this check the likely outcome is a release cut against an engine with
# no trace in it, a `.routeb.trace` that never appears, and a conclusion that "the
# instrumentation did not work". That is the same failure class this whole goal has
# paid for four times, one layer up: a precondition nobody verified, producing a
# result that looks like data.
#
# THREE CONDITIONS, ALL REQUIRED:
#
#   1 the published artifacts.zip differs from the donor's        (different bytes)
#   2 `rbtrace v=1` appears in the published Flutter binary       (trace present)
#   3 `InterpretCall` still appears in it                         (still Route B)
#
# 1 alone would pass on any unrelated rebuild. 2 alone cannot tell a fresh publish
# from a stale one that happened to contain the string. 3 is the guard against
# "fixed the diagnostic, lost the mechanism" -- a Route B engine that can no longer
# interpret is useless even with a perfect trace.
#
#   assert_diagnostic_engine.sh <engineHash> [donorSha256Prefix]
set -euo pipefail

HASH=${1:?usage: assert_diagnostic_engine.sh <engineHash> [donorSha256]}
DONOR_SHA=${2:-eada0018a3c71a03}
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SELFHOST="$(cd "$HERE/../../.." >/dev/null 2>&1 && pwd)"
OVERLAY=${OVERLAY:-$SELFHOST/cdn/overlay}
ZIP=$OVERLAY/flutter_infra_release/flutter/$HASH/ios-release/artifacts.zip

die() { echo "REFUSED: $*" >&2; exit 1; }
pass=0; fail=0
check() { # <label> <ok?>
  if [ "$2" = 1 ]; then echo "  PASS  $1"; pass=$((pass+1));
  else echo "  FAIL  $1"; fail=$((fail+1)); fi
}

[ -f "$ZIP" ] || die "no published iOS artifacts at $ZIP"

echo "engine hash : $HASH"
echo "artifacts   : $ZIP"

# 1. Different bytes from the donor.
GOT_SHA=$(shasum -a 256 "$ZIP" | cut -c1-16)
echo "  sha256[16]  : $GOT_SHA   (donor $DONOR_SHA)"
[ "$GOT_SHA" != "$DONOR_SHA" ] && differs=1 || differs=0
check "published artifacts.zip is NOT the donor's bytes" "$differs"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
unzip -q -o "$ZIP" -d "$WORK"
BIN=$(find "$WORK" -name Flutter -type f | head -1)
[ -n "$BIN" ] || die "no Flutter binary inside $ZIP"
echo "  binary      : $(wc -c < "$BIN" | tr -d ' ') bytes"

# The COUNT is captured separately from the exit status on purpose: `grep -c`
# exits non-zero on zero matches, and zero matches is a legitimate measurement
# here, not a command failure. Conflating the two is how a real result gets
# reported as a broken tool.
SENTINEL=$(strings -a "$BIN" | grep -c 'rbtrace v=1' || true)
INTERP=$(strings -a "$BIN" | grep -c 'InterpretCall' || true)
echo "  rbtrace v=1 : $SENTINEL"
echo "  InterpretCall: $INTERP"

[ "${SENTINEL:-0}" -gt 0 ] && has_trace=1 || has_trace=0
check "the diagnostic is present in the published binary" "$has_trace"
[ "${INTERP:-0}" -gt 0 ] && has_interp=1 || has_interp=0
check "the Route B interpreter path is still present" "$has_interp"

echo
echo "--------------------------------------------------"
echo "assert_diagnostic_engine: $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
  echo
  echo "STOP. Do not cut a release or touch the device against this hash." >&2
  echo "A device result from a non-diagnostic engine cannot be interpreted, and" >&2
  echo "will read as 'the instrumentation did not work'." >&2
  exit 1
fi
echo "This engine is the instrumented one. Release may proceed."
