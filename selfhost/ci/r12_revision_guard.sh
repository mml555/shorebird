#!/usr/bin/env bash
# cspell:words gensnapshot
#
# r12_revision_guard.sh -- refuse to use a producer revision that was not obtained
# whole from an immutable source.
#
# WHY THIS EXISTS. During the R12 preflight I needed the Route B Android cell's
# revision, had only the 8-character prefix `fc184af6` from an evidence file, and
# PADDED IT to 40 characters. The invented revision 404'd for BOTH host slices,
# which looks exactly like "the blocker has changed" -- and the very file I took
# the prefix from warns that "probing the wrong revision produces a symmetric
# answer that resembles a finding". I walked into a documented trap minutes after
# reading the documentation of it.
#
# A note in an evidence file did not prevent that, so this is a check instead.
#
#   r12_revision_guard.sh <revision>
#
# Exit 0 only if the revision is 40 lowercase hex AND resolves to a real cell in
# the overlay AND that cell actually publishes the linux-x64 producer slice.
set -uo pipefail

REV=${1:-}
OVERLAY=${OVERLAY:-/Users/mendell/shorebird/selfhost/cdn/overlay/flutter_infra_release/flutter}
CDN=${CDN:-http://localhost:8085}

die() { printf '  REFUSE: %s\n' "$*" >&2; exit 1; }
ok()  { printf '  ok      %s\n' "$*"; }

[[ -n "$REV" ]] || die "no revision given"

# 1 -- shape. A prefix is not a revision.
[[ ${#REV} -eq 40 ]] || die "revision is ${#REV} characters, not 40. A PREFIX IS NOT A REVISION -- go and read the full value from its source, do not pad it."
[[ "$REV" =~ ^[0-9a-f]{40}$ ]] || die "revision is not 40 lowercase hex characters: $REV"
ok "shape: 40 lowercase hex"

# 2 -- immutable provenance. The overlay directory IS the published cell; a
# revision that exists nowhere on disk was invented or mistyped.
[[ -d "$OVERLAY/$REV" ]] || die "no cell at $OVERLAY/$REV -- this revision does not exist locally, so it cannot be the one to test"
ok "resolves to a published cell in the overlay"

# 3 -- it must actually carry what R12 needs. A cell that exists but publishes no
# linux-x64 producer would 404 for a reason that has nothing to do with the
# blocker under test, which is precisely the confusion this guard prevents.
SLICE="$OVERLAY/$REV/android-arm64-release/linux-x64.zip"
[[ -f "$SLICE" ]] || die "cell $REV publishes no android-arm64-release/linux-x64.zip -- wrong cell for R12 (an iOS cell never carries one, and BOTH slices 404 for it, which resembles a finding and is not one)"
ok "publishes android-arm64-release/linux-x64.zip ($(du -h "$SLICE" | cut -f1))"

# 4 -- and it must be served, not merely present on disk.
CODE=$(curl -sS -o /dev/null -w "%{http_code}" "$CDN/flutter_infra_release/flutter/$REV/android-arm64-release/linux-x64.zip" 2>/dev/null)
[[ "$CODE" == "200" ]] || die "the CDN returns $CODE for this cell's linux-x64 slice; expected 200"
ok "CDN serves it: HTTP 200"

printf '  REVISION ACCEPTED  %s\n' "$REV"
