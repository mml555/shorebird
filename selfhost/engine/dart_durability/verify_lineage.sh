#!/usr/bin/env bash
# DART-DURABILITY-1 (#47) -- the LOCAL half: prove the banked delta still
# reconstructs the exact producing Dart tree, and that a mutation fails.
#
# WHAT THIS DOES NOT DO. #47's central requirement is publishing the lineage to
# a durable remote. That is an outward-facing, hard-to-reverse action -- it
# creates a public repository containing a Dart SDK tree -- and it has not been
# authorized. This script establishes the PRECONDITION for that step and
# nothing more: that the exact producing source is still reconstructible, and
# that the reconstruction is checkable rather than asserted.
#
# The reconstruction works in the git OBJECT DATABASE with a temporary index,
# never a working tree: `git archive | tar -x` followed by `git add -A` does
# not reproduce tree hashes (it loses modes and ignore behaviour), and an
# earlier attempt that way produced 1f8c25b3 instead of the recorded
# aa55ff96 -- a false negative that would have looked like a lineage defect.
#
# usage: verify_lineage.sh <dart-git-dir>
set -uo pipefail
D="${1:?usage: verify_lineage.sh <dart-git-dir>}"
G="$(cd "$(dirname "$0")" && pwd)"
FZ="$(cd "$G/../semantic_linker/runtime_feasibility/g0_freeze" && pwd)"
P="$FZ/banked_source/dart/9999-worktree-uncommitted.patch"
M="$FZ/freeze_manifest.json"
rc=0
ASSERTIONS=()
want() {
  if [ "$2" = "$3" ]; then ASSERTIONS+=("  pass  $1")
  else ASSERTIONS+=("  FAIL  $1 -- got '$3', expected '$2'"); rc=1; fi
}
j() { python3 -c "import json,sys;d=json.load(open('$M'));print(eval(sys.argv[1],{'d':d}))" "$1"; }

REV=$(j "d['producing_source']['dart']['revision']")
HEAD_TREE=$(j "d['producing_source']['dart']['head_tree']")
EFF_TREE=$(j "d['producing_source']['dart']['effective_tree']")
BANKED_PATCH_SHA=$(j "d['producing_source']['dart']['bank']['9999-worktree-uncommitted.patch']")

{
echo "DART-DURABILITY-1 -- lineage reconstruction check"
echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by verify_lineage.sh"
echo
echo "THE LINEAGE THE FROZEN RECORD NAMES"
echo "  dart revision   $REV"
echo "  head tree       $HEAD_TREE"
echo "  effective tree  $EFF_TREE   (head plus the uncommitted guard)"
echo "  banked delta    $BANKED_PATCH_SHA"
echo
echo "############ 1. IS THE NAMED LINEAGE RESOLVABLE, AND FROM WHERE? ############"
for obj in "$REV" "$HEAD_TREE" "$EFF_TREE"; do
  printf '  %s  %s\n' "${obj:0:12}" \
    "$(git -C "$D" cat-file -t "$obj" 2>/dev/null || echo UNRESOLVABLE)"
done
echo
echo "  remotes configured in that checkout:"
git -C "$D" remote -v 2>/dev/null | sed 's/^/    /'
echo
echo "  remote branches containing the named revision:"
CONTAINED=$(git -C "$D" branch -r --contains "$REV" 2>/dev/null | wc -l | tr -d ' ')
if [ "$CONTAINED" = 0 ]; then
  echo "    NONE -- this is the durability defect #47 exists to close."
  echo "    The objects resolve, but only out of a local clone whose origin is"
  echo "    a file:// path on one machine."
else
  git -C "$D" branch -r --contains "$REV" | sed 's/^/    /'
fi
echo
echo "############ 2. DOES THE BANKED DELTA RECONSTRUCT THE EXACT TREE? ############"
export GIT_INDEX_FILE="${TMPDIR:-/tmp}/dd1.idx"; rm -f "$GIT_INDEX_FILE"
git -C "$D" read-tree "$HEAD_TREE"
BEFORE=$(git -C "$D" write-tree)
echo "  index at head tree        $BEFORE"
if git -C "$D" apply --cached "$P" 2>/dev/null; then
  AFTER=$(git -C "$D" write-tree)
  echo "  index after the delta     $AFTER"
  echo "  manifest effective tree   $EFF_TREE"
  [ "$AFTER" = "$EFF_TREE" ] && echo "  RECONSTRUCTED EXACTLY" || echo "  MISMATCH"
else
  AFTER=""; echo "  the banked delta no longer applies to the head tree"
fi
echo
echo "############ 3. NEGATIVE CONTROL -- A ONE-BYTE MUTATION MUST FAIL ############"
python3 - "$P" "${TMPDIR:-/tmp}/dd1_mut.patch" <<'PY'
import pathlib, sys
b = pathlib.Path(sys.argv[1]).read_bytes()
i = b.index(b'\n+') + 2          # first byte of the first added line
pathlib.Path(sys.argv[2]).write_bytes(b[:i] + bytes([b[i] ^ 0x01]) + b[i + 1:])
print(f"  one byte flipped at offset {i}, inside an added line")
PY
MUT="${TMPDIR:-/tmp}/dd1_mut.patch"
rm -f "$GIT_INDEX_FILE"; git -C "$D" read-tree "$HEAD_TREE"
if git -C "$D" apply --cached "$MUT" 2>/dev/null; then
  MR=$(git -C "$D" write-tree)
  if [ "$MR" = "$EFF_TREE" ]; then
    echo "  CONTROL FAILED: the mutated delta still produced the effective tree"
    MUT_OK=no
  else
    echo "  applied, but produced ${MR:0:16} -- refused by tree comparison"
    MUT_OK=yes
  fi
else
  echo "  refused at apply time"
  MUT_OK=yes
fi
echo "  banked delta digest   ${BANKED_PATCH_SHA:0:16}"
echo "  mutated delta digest  $(shasum -a 256 "$MUT" | awk '{print substr($1,1,16)}')"
echo
echo "############ 4. WHAT REMAINS, AND WHY IT IS NOT DONE HERE ############"
cat <<'TXT'
  #47 asks for the lineage to be fetchable from a durable remote, with an
  immutable-intent ref, provable by a FRESH ANONYMOUS CLONE. Every check above
  reads a clone that already exists on this machine, so it establishes the
  precondition and not the acceptance criterion.

  Creating that remote publishes a Dart SDK tree to a host outside this
  machine. That is outward-facing and hard to reverse, and #47 has never been
  authorized -- it has been held off the SEMANTIC-MAP critical path throughout.
  So it is reported, not performed.
TXT
} > "$G/evidence/lineage_check.txt" 2>&1

want 'the banked delta digest matches the manifest' "$BANKED_PATCH_SHA" \
     "$(shasum -a 256 "$P" | awk '{print $1}')"
want 'the named revision resolves in the local clone' commit \
     "$(git -C "$D" cat-file -t "$REV" 2>/dev/null || echo UNRESOLVABLE)"
want 'the banked delta reconstructs the effective tree' "$EFF_TREE" "${AFTER:-none}"
want 'a one-byte mutation is refused' yes "${MUT_OK:-no}"
want 'no remote branch contains the named revision' 0 "$CONTAINED"
{
  echo
  echo "ASSERTIONS (${#ASSERTIONS[@]} checked)"
  printf '%s\n' "${ASSERTIONS[@]}"
  echo
  echo "DD1_LINEAGE: $([ "$rc" = 0 ] && echo RECONSTRUCTIBLE_BUT_NOT_DURABLE || echo FAILED)"
} >> "$G/evidence/lineage_check.txt"
printf '%s\n' "${ASSERTIONS[@]}"
echo "DD1_LINEAGE: $([ "$rc" = 0 ] && echo RECONSTRUCTIBLE_BUT_NOT_DURABLE || echo FAILED)"
exit "$rc"
