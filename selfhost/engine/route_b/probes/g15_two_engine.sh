#!/usr/bin/env bash
# cspell:words PlistBuddy twoengine spawnWithEntrypoint libexec
#
# g15_two_engine.sh -- A GUARD AGAINST REGRESSION OF THE HARNESS SHAPE.
#
# READ THIS FIRST: this probe is NOT evidence that Route B arming works, and a
# green run here must never be reported against `G15`. It asserts that the
# committed two-engine harness still has the shape that makes a later arming
# result attributable. Arming needs our engine, a release and a patch; the harness
# runs on stock Flutter against a simulator and cannot observe arming at all.
#
# The four properties it guards, and what breaks if each one rots:
#
#   1. TWO ENGINES, TWO PROJECTS. One project per engine means two
#      ConfigureShorebird calls, and the second is the case patch `0007` fixes.
#   2. NO SHARED-PROJECT SHORTCUT. FlutterEngineGroup and spawnWithEntrypoint both
#      hand engine two the PARENT's project, which arrives already armed -- so
#      engine two would run patched code even without `0007`. That is a false
#      pass, not a gate.
#   3. THE SECOND ENTRYPOINT IS AOT-SAFE. Without `vm:entry-point` it survives
#      `flutter run` (JIT keeps everything) and is tree-shaken in AOT -- so the
#      harness would work all through development and fail in exactly the
#      release-mode device gate it exists to unblock.
#   4. THE IMPLICIT ENGINE STAYS DEAD. `UIMainStoryboardFile` makes the Runner boot
#      its own engine; with two more constructed the process holds THREE and every
#      per-engine reading is unattributable.
#
# WHY IT STRIPS COMMENTS BEFORE GREPPING, which is a real finding and not
# fussiness: the committed AppDelegate EXPLAINS why FlutterEngineGroup and
# spawnWithEntrypoint are forbidden, so it necessarily contains both words. A
# naive `grep -c` returns 1 and fails a correct file. The assertion has to be
# about USAGE, so comment lines are removed first.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../../../.." >/dev/null 2>&1 && pwd)"
FIXTURE="$REPO/selfhost/fixtures/twoengine_app"
HOST="$FIXTURE/ios_overlay/AppDelegate.swift"
DART="$FIXTURE/lib/main.dart"
PREPARE="$REPO/selfhost/scripts/prepare_twoengine_fixture.sh"

pass=0; fail=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then
    echo "  PASS  $1 -> $2"; pass=$((pass+1))
  else
    echo "  FAIL  $1: got '$2', want '$3'"; fail=$((fail+1))
  fi
}

# Code only: drop whole-line comments and any trailing `// ...`.
code() { sed -e 's|//.*$||' "$1"; }

echo "G15 two-engine harness: is the shape still the one that makes a result attributable?"
echo

for f in "$HOST" "$DART" "$PREPARE"; do
  [ -f "$f" ] || { echo "ERROR: missing $f" >&2; exit 3; }
done

echo "1. two engines, each with its OWN project"
check "FlutterDartProject constructions" \
  "$(code "$HOST" | grep -c 'FlutterDartProject()')" 2
# `= FlutterEngine(`, not `FlutterEngine(`. The loose pattern counts THREE,
# because `didInitializeImplicitFlutterEngine(` contains it as a substring -- so
# the tripwire read as a third engine construction. Found by running this probe
# against a correct harness, which is the cheapest possible place to find it.
check "FlutterEngine constructions (assignments only)" \
  "$(code "$HOST" | grep -c '= FlutterEngine(')" 2
check "the host records whether the projects are distinct" \
  "$(code "$HOST" | grep -c 'projects_distinct')" 1
check "and computes it by identity, not by equality" \
  "$(code "$HOST" | grep -c 'projectOne !== projectTwo')" 1
check "engine two is run by NAME, not by spawn" \
  "$(code "$HOST" | grep -c 'run(withEntrypoint: "engineTwoMain")')" 1

echo "2. no shared-project shortcut (USAGE, comments stripped)"
check "FlutterEngineGroup in code" "$(code "$HOST" | grep -c 'FlutterEngineGroup')" 0
check "spawnWithEntrypoint in code" "$(code "$HOST" | grep -c 'spawnWithEntrypoint')" 0
check "no .spawn( in code" "$(code "$HOST" | grep -c '\.spawn(')" 0
# The absence of a fallback matters as much as the absence of the API: a retry
# with a shared project would turn a failed run into the shape that always looks
# green.
if [ "$(grep -c 'FlutterEngineGroup' "$HOST")" -ge 1 ]; then d=documented; else d=undocumented; fi
check "the forbidden shapes are still EXPLAINED in comments" "$d" documented

echo "3. the second entrypoint survives AOT"
check "engineTwoMain exists" "$(grep -c 'void engineTwoMain()' "$DART")" 1
check "and carries vm:entry-point immediately above it" \
  "$(grep -B1 'void engineTwoMain()' "$DART" | grep -c "vm:entry-point")" 1

echo "4. the implicit engine stays dead"
check "the prepare script deletes UIMainStoryboardFile" \
  "$(grep -c 'Delete :UIMainStoryboardFile' "$PREPARE")" 1
check "the host tripwires on an implicit engine" \
  "$(code "$HOST" | grep -c 'didInitializeImplicitFlutterEngine')" 1
check "and REFUSES rather than interpreting" \
  "$(code "$HOST" | grep -c 'showRefusal')" 2

echo "5. the overlay is committed, not generated"
# The whole reason ios_overlay/ exists: ios/ is gitignored, so a host edited in
# place is deleted by the next materialize.
if git -C "$REPO" check-ignore -q "$HOST"; then ig=ignored; else ig=tracked-path; fi
check "ios_overlay/AppDelegate.swift is not gitignored" "$ig" tracked-path
if git -C "$REPO" check-ignore -q "$FIXTURE/ios/Runner/AppDelegate.swift"; then g=ignored; else g=tracked-path; fi
check "the GENERATED host is gitignored (so the overlay is the source of truth)" \
  "$g" ignored

echo
echo "--------------------------------------------------"
echo "harness shape: $pass passed, $fail failed"
echo
echo "WHAT A GREEN RUN HERE MEANS: the harness still has the shape that would make"
echo "a later arming observation attributable to a specific engine. NOTHING MORE."
echo "The structural boot itself was measured once on the simulator and preserved"
echo "at selfhost/evidence/g15/ (host.marker, engine-{one,two}.marker, simrun.log);"
echo "re-running that is a simulator run, not this probe."
[ "$fail" -eq 0 ] || exit 1
