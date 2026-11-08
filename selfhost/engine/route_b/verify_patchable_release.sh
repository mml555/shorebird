#!/usr/bin/env bash
# cspell:words LDUR arm64 xcarchive
#
# verify_patchable_release.sh -- is this release actually Route-B-patchable?
#
# WHY THIS IS A DETECTOR AND NOT A CONVENTION. Releases 7.0.0+1 and 8.0.0+1 were
# both built without --patchable_static_calls, and NOTHING reported it. The
# patch delivered, installed, parsed, matched its build ID, resolved its target
# and attached — the engine's own report read "applied 1/1 targets" — and the
# app showed OLD, because AOT had emitted an ordinary direct call that never
# consults Function.entry_point_. A mechanism truthfully reporting success while
# behaviour is unchanged is the worst failure shape in this project, so the
# invariant needs something that cannot be forgotten:
#
#   applied N/N targets  +  OLD on screen  ==  NON-PATCHABLE RELEASE
#
# HOW IT DETECTS. The patchable call form ends in exactly two instructions:
#
#   ldur lr, [r0, #7]     ; Function.entry_point_  (offset 7 = tagged 8)
#   blr  lr
#
# which on arm64 are the fixed words 0xF840701E and 0xD63F03C0. Counting
# adjacent pairs of those in the App binary is a property of the SHIPPED BYTES,
# so it cannot be defeated by a stale build, a forgotten flag, a cached
# artifact, or provenance that says the right thing.
#
# WHY A DENSITY THRESHOLD RATHER THAN "> 0". A non-patchable release still
# contains a few: AOT already dispatches some calls (closures, some tear-offs)
# through entry_point_ regardless of the flag. Measured on the two releases that
# produced the failure and the fix:
#
#   8.0.0+1  non-patchable       8 pairs over 3.99 MB  ->     2 per MB
#   9.0.0+1  --patchable_...  7109 pairs over 4.17 MB  -> 1,704 per MB
#
# Three orders of magnitude apart, so the threshold below is not a fine
# judgement call. Re-measure it if the call form ever changes shape.
set -euo pipefail

THRESHOLD_PER_MB=${THRESHOLD_PER_MB:-100}

usage() { echo "usage: $(basename "$0") <path-to-App-binary | path-to-.app | path-to-.xcarchive>" >&2; exit 2; }
[ $# -ge 1 ] || usage

TARGET="$1"
# Accept whichever level of the bundle the caller happens to have.
if [ -d "$TARGET" ]; then
  for candidate in \
    "$TARGET/Frameworks/App.framework/App" \
    "$TARGET/Products/Applications/Runner.app/Frameworks/App.framework/App"; do
    [ -f "$candidate" ] && { TARGET="$candidate"; break; }
  done
fi
[ -f "$TARGET" ] || { echo "ERROR: no App binary at $1" >&2; exit 2; }

python3 - "$TARGET" "$THRESHOLD_PER_MB" <<'PY'
import struct, sys

path, threshold = sys.argv[1], float(sys.argv[2])
LDUR_LR_R0_7 = 0xF840701E  # ldur lr, [r0, #7]
BLR_LR       = 0xD63F03C0  # blr  lr

data = open(path, 'rb').read()
pairs = 0
for i in range(0, len(data) - 8, 4):
    if (struct.unpack_from('<I', data, i)[0] == LDUR_LR_R0_7 and
            struct.unpack_from('<I', data, i + 4)[0] == BLR_LR):
        pairs += 1

mb = len(data) / (1024 * 1024)
density = pairs / mb if mb else 0.0
print(f"binary          : {path}")
print(f"size            : {len(data):,} bytes ({mb:.2f} MB)")
print(f"patchable sites : {pairs:,}  ({density:,.0f} per MB)")
print(f"threshold       : {threshold:,.0f} per MB")

if density >= threshold:
    print("RESULT: PATCHABLE — this release can be patched by Route B")
    sys.exit(0)

print("RESULT: NOT PATCHABLE")
print()
print("This release was built WITHOUT --patchable_static_calls, so a Route B")
print("patch will attach successfully and change nothing: AOT emitted direct")
print("calls that never consult Function.entry_point_.")
print()
print("Rebuild with:")
print("  shorebird release ios ... -- \\")
print("    --extra-gen-snapshot-options=--patchable_static_calls")
sys.exit(1)
PY
