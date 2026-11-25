#!/usr/bin/env bash
# make_selector.sh -- build the Flutter selector commit for a cell: a commit whose parent is the engine
# commit E and whose only change is bin/internal/engine.version = the cell address. Local only: it makes a
# branch in SEL_CLONE and pushes nothing (publish_cell.sh pushes it).
#
#   MINT_ENV=<env file> bash make_selector.sh          # PLAN
#   MINT_ENV=<env file> bash make_selector.sh --run
#
# SEL_CLONE is a clone of the engine repo that holds E. The branch is <SELECTOR_BRANCH_PREFIX><A8>.
# The commit is made with git plumbing (hash-object, read-tree, commit-tree), so no working tree is touched.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); . "$HERE/lib.sh"; load_env
RUN=0; case "${1:-}" in --run) RUN=1;; "") ;; *) die "usage: $0 [--run]";; esac
C=${SEL_CLONE:?set SEL_CLONE=<engine repo clone that holds E> in $MINT_ENV}
[[ -f $OUT/ADDRESS ]] || die "no $OUT/ADDRESS: run stage_mint.sh --run first"
A=$(cat "$OUT/ADDRESS"); hex40 address "$A"; BR=$SELECTOR_BRANCH_PREFIX${A:0:8}
git -C "$C" cat-file -e "$E^{commit}" 2>/dev/null || die "$E is not in $C (fetch it)"
old=$(git -C "$C" show "$E:bin/internal/engine.version") || die "no bin/internal/engine.version at $E"
if git -C "$C" rev-parse -q --verify "refs/heads/$BR" >/dev/null; then
  have=$(git -C "$C" rev-parse "refs/heads/$BR")
  [[ "$(git -C "$C" rev-parse "$have^")" == "$E" && "$(git -C "$C" show "$have:bin/internal/engine.version")" == "$A" ]] \
    && { echo "branch $BR already holds the selector $have"; exit 0; }
  die "branch $BR exists in $C and is not the selector for $A"
fi
say "selector: parent $E, bin/internal/engine.version $old -> $A, branch $BR in $C"
[[ $RUN == 1 ]] || { echo "PLAN ONLY. Add --run."; exit 0; }
idx=$(mktemp -u); trap 'rm -f "$idx"' EXIT
blob=$(printf '%s\n' "$A" | git -C "$C" hash-object -w --stdin)
GIT_INDEX_FILE=$idx git -C "$C" read-tree "$E"
GIT_INDEX_FILE=$idx git -C "$C" update-index --cacheinfo "100644,$blob,bin/internal/engine.version"
tree=$(GIT_INDEX_FILE=$idx git -C "$C" write-tree)
sel=$(git -C "$C" commit-tree "$tree" -p "$E" -m "Select cell ${A:0:8} ($CELL) over engine $E8" -m "bin/internal/engine.version = $A. Nothing else changes.")
[[ "$(git -C "$C" diff --name-only "$E" "$sel")" == bin/internal/engine.version ]] || die "the selector changes more than engine.version"
git -C "$C" update-ref "refs/heads/$BR" "$sel"
echo "SELECTOR $sel on $BR"
