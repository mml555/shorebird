#!/usr/bin/env bash
# cspell:words delibrate sentance dotcheck
#
# cspell_scope_control.sh -- proves the SCOPE of the full-tree spelling command.
#
# WHAT THIS EXISTS TO PIN DOWN. "Tree-wide" was an undocumented approximation
# until 2026-08-16. cspell does NOT traverse into dot-named files when handed a
# directory, so `npx cspell … selfhost` silently skipped every one of them --
# including selfhost/engine/.gclient.template, authored, never checked, and
# carrying two real findings the moment it was looked at. A green result under
# that command meant "clean across whatever the traversal happened to reach",
# which is not a claim anybody would knowingly promote to a gate.
#
# THE COMMAND THIS PROVES is the one the CI job runs, verbatim:
#
#   npx cspell --dot --no-progress --no-summary selfhost packages/code_push_server/lib
#
# `--dot` is the whole correction: it includes dot-named files and directories
# when matching globs. Generated dot-directories (.dart_tool, .idea, .generated)
# sit under fixtures/, which ignorePaths already excludes, so the flag adds
# authored content and not noise.
#
# TWO CONTROLS, because the scope has two halves and one of them was the hole:
#   ORDINARY  a typo in a normally-named file must fail the command;
#   DOTFILE   a typo in a DOT-NAMED file must fail it too.
# Before 2026-08-16 the second passed silently. That is the regression this
# script exists to catch if anyone ever drops --dot.
#
# Both specimens are removed afterwards and the tree is asserted clean again.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
cd "$REPO"

ORDINARY="selfhost/plans/scope_control_specimen.md"
DOTFILE="selfhost/plans/.scope_control_specimen.md"
cleanup() { rm -f "$REPO/$ORDINARY" "$REPO/$DOTFILE"; }
trap cleanup EXIT
cleanup

pass=0; fail=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "  PASS  $1 -> $2"; pass=$((pass+1))
  else echo "  FAIL  $1 -> got [$2] want [$3]"; fail=$((fail+1)); fi
}

run() { # -> sets RC and OUT
  OUT=$(mktemp); RC=0
  npx cspell --dot --no-progress --no-summary selfhost packages/code_push_server/lib \
    > "$OUT" 2>&1 || RC=$?
}

echo "== scope control: the exact command the full-tree CI job runs =="

run
check "clean tree is GREEN" "$([ "$RC" -eq 0 ] && echo green || echo red)" "green"
rm -f "$OUT"

printf 'this sentance has a delibrate typo\n' > "$ORDINARY"
run
check "ORDINARY file typo fails the command" "$([ "$RC" -ne 0 ] && echo red || echo green)" "red"
check "  …and is reported by name" \
  "$(grep -cF "$ORDINARY:" "$OUT" > /dev/null && echo yes || echo no)" "yes"
rm -f "$OUT" "$ORDINARY"

printf 'this sentance has a delibrate typo\n' > "$DOTFILE"
run
check "DOTFILE typo fails the command" "$([ "$RC" -ne 0 ] && echo red || echo green)" "red"
check "  …and is reported by name" \
  "$(grep -cF "$DOTFILE:" "$OUT" > /dev/null && echo yes || echo no)" "yes"
rm -f "$OUT" "$DOTFILE"

run
check "tree restored to GREEN" "$([ "$RC" -eq 0 ] && echo green || echo red)" "green"
rm -f "$OUT"

echo
echo "SCOPE CONTROL PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
