#!/usr/bin/env bash
# MAOT-1 (#65) -- stable declaration and type identity, gated.
#
# Produces evidence/m1.json (the record) and evidence/m1.txt (this log).
# Exits non-zero on any blocking finding, failed case or not-yet-demonstrated arm.
#
# The identity scheme itself lives in the Dart fork, not here:
#   pkg/kernel/lib/maot_identity.dart       the scheme
#   pkg/vm/bin/maot_identity_manifest.dart  the manifest emitter
# This lane drives them, records what they produced, and decides the verdict.
#
#   usage: run_m1.sh
#   env:   MAOT_FORK, DART_SDK, MAOT_PLATFORM
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../../../.." && pwd)"
EVID="$HERE/evidence"; mkdir -p "$EVID"
RAW="$EVID/m1.json"
LOG_FILE="$EVID/m1.txt"
FORK="${MAOT_FORK:-/Volumes/build/maot/dart}"
DURABLE="${MAOT_DURABLE_REMOTE:-https://github.com/mml555/dart-sdk-shorebird-lineage.git}"
BRANCH="${MAOT_DURABLE_BRANCH:-maot/identity}"
rm -f "$LOG_FILE"

# A brace literal with a top-level comma is BRACE-EXPANDED by bash inside
# $(...), silently splitting one Python expression into several shell words.
# zsh does not do this, so it survives interactive testing and fails only under
# the CI shell. Refuse rather than produce wrong answers.
if grep -nE "\\\$\\(([jc]) \"[^\"]*\\{[^}]*,[^}]*\\}" "$0" >/dev/null 2>&1; then
  echo "run_m1.sh contains a bash-expandable brace literal in a shell-passed" >&2
  echo "Python expression. Use set([...]) instead of {...}." >&2
  exit 2
fi

{
echo "MAOT-1 (#65) -- stable declaration and type identity"
echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by run_m1.sh"
echo "repo revision $(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
echo
echo "############ 1. WHAT THIS ISSUE OWNS ############"
cat <<'TXT'
  #65 owns IDENTITY and nothing else. No runtime implementation slot, no
  mutable call lowering, no optimizer change, no dispatch work, no patch
  transaction, no class migration. Those are #66 onward, and the assertions
  below check the boundary from the fork's own diff rather than asserting it.

  Identity is computed in the front end from the program's name space. It may
  not depend on machine-code or object addresses, pool offsets, transient
  class ids, compilation or declaration order, source position, absolute paths
  or build directories. The scheme REFUSES to name a file: library it cannot
  make root-relative: falling back to the absolute path would mint an id
  reproducible only on the machine that made it, and that id would pass every
  test written there.
TXT
echo
echo "############ 2. THE FORK UNDER TEST ############"
} > "$LOG_FILE" 2>&1

{
echo "  worktree      $FORK"
echo "  branch        $(git -C "$FORK" rev-parse --abbrev-ref HEAD 2>/dev/null)"
echo "  commit        $(git -C "$FORK" rev-parse HEAD 2>/dev/null)"
echo "  tree          $(git -C "$FORK" rev-parse HEAD^{tree} 2>/dev/null)"
echo "  dirty files   $(git -C "$FORK" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo
echo "  a branch is transport, not provenance. The commit and tree above are"
echo "  the identity, and the record pins the digests of the two files that"
echo "  define the scheme so an edited worktree cannot pass as the commit."
echo
echo "############ 3. DURABILITY -- THE FORK IS FETCHABLE OFF THIS MACHINE ############"
} >> "$LOG_FILE"

REMOTE_SHA=$(git ls-remote "$DURABLE" "refs/heads/$BRANCH" 2>/dev/null | cut -f1)
LOCAL_SHA=$(git -C "$FORK" rev-parse HEAD 2>/dev/null)
FETCH_TREE=""
if [[ -n "$REMOTE_SHA" ]]; then
  T=$(mktemp -d)
  git init -q "$T/p" 2>/dev/null
  git -C "$T/p" remote add d "$DURABLE" 2>/dev/null
  if timeout 900 git -C "$T/p" fetch -q --depth 1 d "$BRANCH" 2>/dev/null; then
    FETCH_TREE=$(git -C "$T/p" rev-parse FETCH_HEAD^{tree} 2>/dev/null)
  fi
  rm -rf "$T"
fi
LOCAL_TREE=$(git -C "$FORK" rev-parse HEAD^{tree} 2>/dev/null)

{
echo "  remote        $DURABLE"
echo "  ref           refs/heads/$BRANCH"
echo "  remote HEAD   ${REMOTE_SHA:-<absent>}"
echo "  local  HEAD   $LOCAL_SHA"
echo "  fetched TREE  ${FETCH_TREE:-<not fetched>}"
echo "  local   TREE  $LOCAL_TREE"
echo
echo "  The branch is FETCHED BACK independently, not trusted because a push"
echo "  printed progress. A push that is still enumerating objects has not"
echo "  made anything durable."
echo
echo "############ 4. THE RUN ############"
} >> "$LOG_FILE"

python3 "$HERE/lib/gate_m1.py" "$HERE" "$RAW" >>"$LOG_FILE" 2>&1
GATE_RC=$?

echo >> "$LOG_FILE"
echo "############ 5. ASSERTIONS ############" >> "$LOG_FILE"

rc=0
A=()
want() {
  if [[ "$2" == "$3" ]]; then A+=("  pass  $1")
  else A+=("  FAIL  $1 -- got '$3', expected '$2'"); rc=1; fi
}
j() { python3 -c "
import json,sys
try: print(eval(sys.argv[1], {'d': json.load(open('$RAW'))}))
except Exception: print('unreadable')" "$1"; }

want 'the gate ran' 0 "${GATE_RC:-1}"
want 'the record was written' 0 "$([[ -s "$RAW" ]] && echo 0 || echo 1)"
want 'no blocking finding stands' 0 \
     "$(j "sum(1 for f in d['findings'] if f['severity']=='blocking')")"

# --- the compiler under test is named exactly
want 'the fork commit is a full sha' True \
     "$(j "len(d['fork_identity']['commit'])==40")"
want 'the fork tree is a full sha' True \
     "$(j "len(d['fork_identity']['tree'])==40")"
want 'the fork worktree is clean' False "$(j "d['fork_identity']['dirty']")"
want 'the two scheme files are digested' 2 \
     "$(j "len(d['fork_identity']['source_digests'])")"

# --- durability, proven by fetching back
want 'the durable branch exists on the remote' True \
     "$([[ -n "$REMOTE_SHA" ]] && echo True || echo False)"
want 'the remote tip is the local commit' "$LOCAL_SHA" "$REMOTE_SHA"
want 'the branch fetches back with the same tree' "$LOCAL_TREE" "$FETCH_TREE"

# --- every required test and surface
want 'every case passes' 0 "$(j "len(d['verdict']['cases_failed'])")"
want 'the case population is non-empty' True \
     "$(j "d['verdict']['cases_run'] > 0")"
want 'every #65 required test has a case or an arm' True \
     "$(j "len(d['verdict']['required_tests']) + len(d['verdict']['required_tests_by_arm']) == 10")"
want 'every named surface has a case' 9 \
     "$(j "len(d['verdict']['required_surfaces'])")"

# --- the properties the scheme claims
want 'ids are identical across two build directories' pass \
     "$(j "[c['result'] for c in d['cases'] if c['id']=='T01'][0]")"
want 'a body-only edit moves no id' pass \
     "$(j "[c['result'] for c in d['cases'] if c['id']=='T02'][0]")"
want 'reordering declarations moves no id' pass \
     "$(j "[c['result'] for c in d['cases'] if c['id']=='T03'][0]")"
want 'a rename mints a new identity' pass \
     "$(j "[c['result'] for c in d['cases'] if c['id']=='T06'][0]")"
want 'private names never alias' pass \
     "$(j "[c['result'] for c in d['cases'] if c['id']=='T07'][0]")"
want 'extension members are identified by declaration, not by lowering' pass \
     "$(j "[c['result'] for c in d['cases'] if c['id']=='TX1'][0]")"
want 'synthesized entities carry a role or are non-addressable' pass \
     "$(j "[c['result'] for c in d['cases'] if c['id']=='T09'][0]")"
want 'a file: library is refused rather than path-named' pass \
     "$(j "[c['result'] for c in d['cases'] if c['id']=='TX6'][0]")"
want 'the app root is never recorded as a path' pass \
     "$(j "[c['result'] for c in d['cases'] if c['id']=='TX7'][0]")"

# --- the manifest binding
want 'the release namespace is a digest' 64 \
     "$(j "len(d['manifests']['release_namespace'])")"
want 'a body edit does not move the namespace' True \
     "$(j "d['manifests']['namespace_equal_under_body_edit']")"

# --- the arms, both directions
want 'every falsification arm is demonstrated' 0 \
     "$(j "len([a for a in d['falsification'] if a['result']!='pass'])")"
want 'the arms include a positive control' pass \
     "$(j "[a['result'] for a in d['falsification'] if a['id']=='P0'][0]")"
want 'a forced collision fails closed' pass \
     "$(j "[a['result'] for a in d['falsification'] if a['id']=='F04'][0]")"
want 'a path-dependent id is refused' pass \
     "$(j "[a['result'] for a in d['falsification'] if a['id']=='F02'][0]")"
want 'a lowered form used as identity is refused' pass \
     "$(j "[a['result'] for a in d['falsification'] if a['id']=='F07'][0]")"
want 'an empty test population is refused' pass \
     "$(j "[a['result'] for a in d['falsification'] if a['id']=='F09'][0]")"

# --- every computed value feeds a decision
want 'every computed value names its consumer' 0 \
     "$(j "len(d['consumers']['unconsumed_or_undeclared'])")"

# --- the stop boundary: #65 owns identity only
want 'the fork delta since the baseline touches only identity files' 2 \
     "$(git -C "$FORK" diff --name-only 9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c..HEAD 2>/dev/null | wc -l | tr -d ' ')"
want 'no runtime, optimizer or dispatch source was touched' 0 \
     "$(git -C "$FORK" diff --name-only 9e8c898a4d2a3b4d0f9c76b973a199859bb1b40c..HEAD -- runtime/ pkg/vm/lib/transformations/ pkg/front_end/ 2>/dev/null | wc -l | tr -d ' ')"
want 'no Shorebird implementation subsystem is modified' 0 \
     "$(git -C "$REPO" status --porcelain -- packages bin scripts \
        selfhost/engine/route_b selfhost/engine/route_b_di \
        selfhost/engine/dart-fork selfhost/engine/semantic_map \
        2>/dev/null | wc -l | tr -d ' ')"

{
  printf '%s\n' "${A[@]}"
  echo
  echo "ASSERTIONS (${#A[@]} checked: $(printf '%s\n' "${A[@]}" | grep -c '^  pass  ') pass, $(printf '%s\n' "${A[@]}" | grep -c '^  FAIL  ') fail)"
  echo
  echo "M1: $([[ "$rc" == 0 ]] && echo "IDENTITY_ESTABLISHED / stable_identity=$(j "d['verdict']['stable_identity']")" || echo GATE_FAILED)"
} >> "$LOG_FILE"

cat "$LOG_FILE"
echo "record: $RAW"
exit "$rc"
