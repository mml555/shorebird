#!/usr/bin/env bash
# cspell:words dartaotruntime gen snapshot
#
# activate_cell.sh -- switch the pinned Flutter checkout to an engine cell, as ONE
# coherent operation.
#
# Writing bin/internal/engine.version is NOT activation. The engine artifacts and
# the host Dart SDK are tracked by independent stamps, and the tool snapshots are
# compiled BY that SDK, so a partial activation leaves a checkout that reports the
# right cell and builds with the wrong compiler. That happened, twice, and neither
# failure looked like what it was:
#
#   * release 1.14.0+1 -- engine.version named the cell, artifacts were still
#     stock, so the release shipped with no patchable call sites and the Route B
#     producer refused to patch it (fail-closed, but far too late);
#   * an app.dill built by a stale host SDK aborted the MANDATORY P4.1
#     snapshot-profile writer at app_snapshot.cc:7868 -- indistinguishable from a
#     Dart serializer bug, while gen_snapshot was byte-identical to known-good.
#
# Usage: activate_cell.sh <cell-sha> [flutter-root]
set -euo pipefail

CELL=${1:?usage: activate_cell.sh <cell-sha> [flutter-root]}
SHOREBIRD_HOME=${SHOREBIRD_HOME:-$HOME/.shorebird}
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -ge 2 ]; then
  FLUTTER_ROOT=$2
else
  REV=$(tr -d '[:space:]' < "$SHOREBIRD_HOME/bin/internal/flutter.version")
  FLUTTER_ROOT="$SHOREBIRD_HOME/bin/cache/flutter/$REV"
fi
[ -d "$FLUTTER_ROOT" ] || { echo "no checkout at $FLUTTER_ROOT" >&2; exit 2; }

: "${FLUTTER_STORAGE_BASE_URL:=http://localhost:8085}"
export FLUTTER_STORAGE_BASE_URL

echo "activating cell $CELL"
echo "  checkout: $FLUTTER_ROOT"

# 1 · select the cell
echo "$CELL" > "$FLUTTER_ROOT/bin/internal/engine.version"

# 2 · invalidate everything derived from the previous engine/SDK. Targeted, not a
# blanket clean: each of these is keyed to the SDK we are replacing.
rm -f "$FLUTTER_ROOT/bin/cache/engine-dart-sdk.stamp" \
      "$FLUTTER_ROOT/bin/cache/flutter_tools.stamp" \
      "$FLUTTER_ROOT/bin/cache/flutter_tools.snapshot" \
      "$SHOREBIRD_HOME/bin/cache/shorebird.snapshot" \
      "$SHOREBIRD_HOME/bin/cache/shorebird.stamp"

# 3 · let Flutter reinstall BOTH the engine artifacts and the host dart-sdk. The
# inner flutter is what refreshes engine-dart-sdk.stamp; the outer shorebird
# bootstrap is gated by its own stamp and will skip this.
echo "  reinstalling artifacts (engine + host dart-sdk)…"
"$FLUTTER_ROOT/bin/flutter" --version >/dev/null

# 4 · refuse to hand back a checkout that is not coherent
echo
bash "$HERE/verify_toolchain_coherence.sh"
