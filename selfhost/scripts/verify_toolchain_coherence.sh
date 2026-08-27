#!/usr/bin/env bash
# cspell:words dartaotruntime dart-sdk gen snapshot
#
# verify_toolchain_coherence.sh -- assert that a Flutter checkout is running the
# host Dart SDK belonging to the cell it claims to use.
#
# WHY THIS EXISTS. `bin/internal/engine.version` selects the cell, but the engine
# artifacts and the HOST DART SDK are tracked by two INDEPENDENT stamps:
#
#     bin/cache/engine.stamp            -> engine artifacts
#     bin/cache/engine-dart-sdk.stamp   -> host dart-sdk
#
# Refreshing one without the other leaves a mixed toolchain: the cell's
# gen_snapshot with a stock kernel producer. That is not a theoretical hazard --
# it produced an `app.dill` that aborted the MANDATORY P4.1 snapshot-profile
# writer at app_snapshot.cc:7868, and it looked for all the world like a Dart
# serializer bug. gen_snapshot was byte-identical to the known-good one the whole
# time; only the kernel producer differed.
#
# It also produced release 1.14.0+1, where engine.version named the cell while
# the artifacts were still stock, so the release shipped without patchable call
# sites and the Route B producer refused to patch it. Fail-closed worked, but the
# incoherence should never have got that far.
#
# Checks, in order of how badly each one bites:
#   1. engine.version == engine.stamp == engine-dart-sdk.stamp
#   2. the checkout's dartaotruntime is byte-identical to the one in the cell's
#      published dart-sdk zip  (the check that would have caught this)
#   3. gen_snapshot for each iOS mode carries --patchable_static_calls
#   4. the CLI snapshot actually runs under the current SDK
set -uo pipefail

FLUTTER_ROOT=${FLUTTER_ROOT:-}
OVERLAY=${OVERLAY:-/Users/mendell/shorebird/selfhost/cdn/overlay/flutter_infra_release/flutter}
SHOREBIRD_HOME=${SHOREBIRD_HOME:-$HOME/.shorebird}

if [ -z "$FLUTTER_ROOT" ]; then
  REV=$(tr -d '[:space:]' < "$SHOREBIRD_HOME/bin/internal/flutter.version" 2>/dev/null || true)
  [ -n "$REV" ] || { echo "FAIL: cannot determine the pinned flutter revision"; exit 2; }
  FLUTTER_ROOT="$SHOREBIRD_HOME/bin/cache/flutter/$REV"
fi
[ -d "$FLUTTER_ROOT" ] || { echo "FAIL: no checkout at $FLUTTER_ROOT"; exit 2; }

fails=0
ok()   { printf '  OK   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fails=$((fails+1)); }
h()    { [ -f "$1" ] && shasum -a 256 "$1" | cut -d' ' -f1 || echo ABSENT; }
stamp(){ tr -d '[:space:]' < "$1" 2>/dev/null || echo ABSENT; }

echo "checkout: $FLUTTER_ROOT"
EV=$(stamp "$FLUTTER_ROOT/bin/internal/engine.version")
ES=$(stamp "$FLUTTER_ROOT/bin/cache/engine.stamp")
EDS=$(stamp "$FLUTTER_ROOT/bin/cache/engine-dart-sdk.stamp")
echo "  engine.version          $EV"
echo "  engine.stamp            $ES"
echo "  engine-dart-sdk.stamp   $EDS"
echo

# 1 ---------------------------------------------------------------- stamps agree
[ "$EV" = "$ES" ]  && ok "engine artifacts match engine.version" \
                   || bad "engine.stamp ($ES) != engine.version ($EV) — engine artifacts are stale"
[ "$EV" = "$EDS" ] && ok "host dart-sdk matches engine.version" \
                   || bad "engine-dart-sdk.stamp ($EDS) != engine.version ($EV) — MIXED TOOLCHAIN: cell engine with a foreign kernel producer"

# 2 -------------------------------------------- host SDK bytes match the cell's
ZIP="$OVERLAY/$EV/dart-sdk-darwin-arm64.zip"
if [ -f "$ZIP" ]; then
  W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
  if unzip -q -o "$ZIP" -d "$W" 'dart-sdk/bin/dartaotruntime' 'dart-sdk/revision' 2>/dev/null; then
    A=$(h "$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dartaotruntime")
    B=$(h "$W/dart-sdk/bin/dartaotruntime")
    AR=$(stamp "$FLUTTER_ROOT/bin/cache/dart-sdk/revision"); BR=$(stamp "$W/dart-sdk/revision")
    if [ "$A" = "$B" ]; then
      ok "dartaotruntime is the cell's (${A:0:16}, rev ${BR:0:12})"
    else
      bad "dartaotruntime is NOT the cell's: checkout ${A:0:16} rev ${AR:0:12} vs cell ${B:0:16} rev ${BR:0:12}"
    fi
  else
    bad "could not read dartaotruntime out of $ZIP"
  fi
else
  bad "no published dart-sdk zip for $EV at $ZIP — cannot verify the host SDK"
fi

# 3 ------------------------------------------------- gen_snapshot is a Route B one
for mode in ios ios-profile ios-release; do
  GS="$FLUTTER_ROOT/bin/cache/artifacts/engine/$mode/gen_snapshot_arm64"
  if [ -f "$GS" ]; then
    # the flag NAME in the binary, not `--version`, which exits 0 whatever flags
    # precede it and once certified a stock binary as Route B capable
    n=$(strings -a "$GS" | grep -c '^patchable_static_calls$' || true)
    [ "${n:-0}" -ge 1 ] && ok "$mode gen_snapshot carries patchable_static_calls" \
                        || bad "$mode gen_snapshot is STOCK — a release built with it cannot be patched"
  else
    bad "$mode/gen_snapshot_arm64 missing"
  fi
done

# 4 ------------------------------------- the CLI snapshot runs under this SDK
SNAP="$SHOREBIRD_HOME/bin/cache/shorebird.snapshot"
DART="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
if [ -f "$SNAP" ] && [ -x "$DART" ]; then
  out=$("$DART" "$SNAP" --version 2>&1 || true)
  case "$out" in
    *"Wrong full snapshot version"*)
      bad "shorebird.snapshot was built by a DIFFERENT Dart SDK — delete it and its stamp so it rebuilds" ;;
    *) ok "shorebird.snapshot runs under the current SDK" ;;
  esac
else
  ok "shorebird.snapshot not present (will be built on next run)"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "COHERENT: $fails failure(s)"
else
  echo "INCOHERENT: $fails failure(s) — do NOT cut a release from this checkout"
fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
