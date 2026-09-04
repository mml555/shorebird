#!/usr/bin/env bash
# cspell:words armv
# SELFHOST-DISTRIBUTION-1 gate 1: is the qualified Flutter revision what it is
# claimed to be, and can it be made durable WITHOUT rebuilding anything?
#
# The gate's first precondition -- "it is exactly the Flutter checkout used for
# AFS2" -- turns out to need care. AFS2 ran against a CLONE of the qualified
# checkout and committed the selector move there; the promotion step committed
# the same move again in the qualified checkout itself. Two commits, and they
# are not the same sha. What IS the same is the thing that decides behaviour.
set -uo pipefail
Q=${Q:-/Volumes/build/route-b/shorebird-candidate/bin/cache/flutter/e64eb0af52e1c43c3b21a39556d789538d0df9b3}
A=${A:-/Volumes/build/route-b/afs2/cli/bin/cache/flutter/e64eb0af52e1c43c3b21a39556d789538d0df9b3}
BASE=e64eb0af52e1c43c3b21a39556d789538d0df9b3
CELL=f85251f344600ae08196925a174e9cff8f0ff18e
OLDCELL=cd848320d605ff8af5060cabf9a8d1b35853f752
fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note(){ printf '\n\033[1m== %s\033[0m\n' "$1"; }

QREV=$(git -C "$Q" rev-parse HEAD)
AREV=$(git -C "$A" rev-parse HEAD 2>/dev/null)

note "1a - the two candidate revisions"
printf '    %-46s %s\n' "qualified checkout HEAD (SHOREBIRD_ROOT)" "$QREV"
printf '    %-46s %s\n' "the commit the AFS2 run built from"       "${AREV:-<absent>}"
if [[ "$QREV" == "$AREV" ]]; then
  ok "they are the same commit"
else
  echo "    they are DIFFERENT commits — so commit identity alone cannot carry the claim"
fi

note "1b - TREE identity, which is what Flutter's behaviour depends on"
# Flutter reads FILES. `bin/internal/engine.version` is a blob in the tree, and
# the engine a build resolves is decided by that blob -- not by which commit
# object happens to point at the tree. This programme's own rule is to freeze
# TREE objects rather than ancestry, and here the trees can be compared
# directly.
QT=$(git -C "$Q" rev-parse HEAD^{tree})
AT=$(git -C "$A" rev-parse HEAD^{tree} 2>/dev/null)
printf '    %-46s %s\n' "qualified HEAD tree" "$QT"
printf '    %-46s %s\n' "AFS2 HEAD tree"      "${AT:-<absent>}"
if [[ -n "$AT" && "$QT" == "$AT" ]]; then
  ok "IDENTICAL trees — the qualified revision's source is byte-identical to what AFS2 built from"
else
  bad "the trees differ: the qualified revision is NOT the source AFS2 built from"
fi

note "1c - ancestry"
QP=$(git -C "$Q" cat-file -p "$QREV" | awk '$1=="parent"{print $2}')
np=$(printf '%s\n' "$QP" | grep -c . )
[[ "$np" == 1 ]] && ok "exactly one parent (not a merge)" || bad "$np parents"
[[ "$QP" == "$BASE" ]] && ok "parent is exactly the recorded selector $BASE" \
                       || bad "parent is $QP, not $BASE"

note "1d - the delta is ONLY the selector movement"
files=$(git -C "$Q" diff --name-only "$BASE" "$QREV" | tr '\n' ' ')
printf '    files changed: %s\n' "$files"
[[ "$files" == "bin/internal/engine.version " ]] \
  && ok "exactly one file changed, and it is the selector" \
  || bad "the delta touches more than bin/internal/engine.version"
lines=$(git -C "$Q" diff "$BASE" "$QREV" | grep -c '^[+-][^+-]')
[[ "$lines" == 2 ]] && ok "exactly one line replaced (2 changed lines)" || bad "$lines changed lines"
before=$(git -C "$Q" show "$BASE:bin/internal/engine.version" | tr -d '[:space:]')
after=$(git -C "$Q" show "$QREV:bin/internal/engine.version" | tr -d '[:space:]')
printf '    %s -> %s\n' "$before" "$after"
[[ "$before" == "$OLDCELL" ]] && ok "it moved FROM the superseded cell" || bad "unexpected before value"
[[ "$after"  == "$CELL"    ]] && ok "it moved TO the supported cell"    || bad "unexpected after value"

note "1e - the working tree is clean, so HEAD is the whole story"
[[ -z "$(git -C "$Q" status --porcelain)" ]] && ok "qualified Flutter checkout is clean" \
                                             || bad "qualified Flutter checkout has uncommitted changes"

note "RESULT"
echo "  revision to make durable: $QREV"
echo "  its tree:                 $QT"
echo "  AFS2's commit (same tree, different metadata): ${AREV:-<absent>}"
if [[ $fail -eq 0 ]]; then echo "  GATE 1 PRECONDITIONS ESTABLISHED"; else
  echo "  GATE 1: $fail FAILURE(S) — STOP"; exit 1; fi
