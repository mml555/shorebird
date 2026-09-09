#!/usr/bin/env bash
# DART-DURABILITY-1 (#47) -- the acceptance criterion.
#
# verify_lineage.sh proved the delta reconstructs the tree, but it read a clone
# that already existed on this machine, so it could not distinguish "durable"
# from "present locally". publish_lineage.sh pushed the lineage, but it ran
# inside the clone that already held every object, so it could not either.
#
# This script is the only one that can: it clones from the network into a fresh
# scratch directory with NO credentials and NO local object reuse, and asks
# whether the exact producing tree resolves THERE.
#
# The credential suppression matters. A clone that silently used the operator's
# GitHub token would prove the repo is reachable BY THIS OPERATOR, which is not
# the claim -- the claim is that the lineage is fetchable at all. So the clone
# runs with the global config discarded, terminal prompting off, and askpass
# stubbed; if the repo were private the clone would fail rather than succeed
# for the wrong reason.
#
# Local object reuse matters for the same reason: --no-local plus a scratch
# GIT_ALTERNATE_OBJECT_DIRECTORIES-free environment means every object comes
# down the wire.
#
# usage: verify_durable.sh <owner/repo>
set -uo pipefail
SLUG="${1:?usage: verify_durable.sh <owner/repo>}"
G="$(cd "$(dirname "$0")" && pwd)"
FZ="$(cd "$G/../semantic_linker/runtime_feasibility/g0_freeze" && pwd)"
P="$FZ/banked_source/dart/9999-worktree-uncommitted.patch"
M="$FZ/freeze_manifest.json"
BRANCH=provenance/route-b-selfhost-v1.1.1
TAG=route-b-producing-source-selfhost-v1.1.1
W="${TMPDIR:-/tmp}/dd1_fresh"; rm -rf "$W"; mkdir -p "$W"
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

{
echo "DART-DURABILITY-1 -- fresh anonymous clone"
echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by verify_durable.sh"
echo
echo "  remote      https://github.com/$SLUG.git"
echo "  scratch     $W/clone"
echo "  wanted tree $EFF_TREE"
echo
echo "############ 1. CLONE WITH NO CREDENTIALS AND NO LOCAL OBJECTS ############"
CLONE_ENV=(env -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_DIR -u GIT_INDEX_FILE
           GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
           GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/true
           GIT_CONFIG_NOSYSTEM=1 HOME="$W/nohome")
mkdir -p "$W/nohome"
"${CLONE_ENV[@]}" git clone --no-local --quiet "https://github.com/$SLUG.git" \
    "$W/clone" 2>&1 | sed 's/^/  /'
CLONE_RC=${PIPESTATUS[0]}
echo "  clone exit  $CLONE_RC"
C="$W/clone"
if [ "$CLONE_RC" = 0 ]; then
  echo "  it resolved:"
  "${CLONE_ENV[@]}" git -C "$C" remote -v | sed 's/^/    /'
  echo "  no local-path remote survives: $("${CLONE_ENV[@]}" git -C "$C" remote -v \
      | grep -c 'file://\|/Volumes/\|/Users/')  (0 is required)"
  LOCALREMOTE=$("${CLONE_ENV[@]}" git -C "$C" remote -v \
      | grep -c 'file://\|/Volumes/\|/Users/')
  echo "  alternates configured: $([ -s "$C/.git/objects/info/alternates" ] \
      && cat "$C/.git/objects/info/alternates" || echo none)"
  ALT=$([ -s "$C/.git/objects/info/alternates" ] && echo present || echo none)
else
  LOCALREMOTE=1; ALT=unknown
fi
echo
echo "############ 2. DOES THE PRODUCING TREE RESOLVE FROM THE CLONE? ############"
r() { "${CLONE_ENV[@]}" git -C "$C" "$@" 2>/dev/null; }
TAG_TYPE=$(r cat-file -t "refs/tags/$TAG" || echo UNRESOLVABLE)
TAG_COMMIT=$(r rev-parse "refs/tags/$TAG^{commit}" || echo none)
TAG_TREE=$(r rev-parse "refs/tags/$TAG^{tree}" || echo none)
BR_COMMIT=$(r rev-parse "refs/remotes/origin/$BRANCH" || echo none)
REV_TYPE=$(r cat-file -t "$REV" || echo UNRESOLVABLE)
HEAD_TYPE=$(r cat-file -t "$HEAD_TREE" || echo UNRESOLVABLE)
EFF_TYPE=$(r cat-file -t "$EFF_TREE" || echo UNRESOLVABLE)
printf '  %-34s %s\n' "tag object type"        "$TAG_TYPE"
printf '  %-34s %s\n' "tag -> commit"          "$TAG_COMMIT"
printf '  %-34s %s\n' "tag -> tree"            "$TAG_TREE"
printf '  %-34s %s\n' "provenance branch head" "$BR_COMMIT"
printf '  %-34s %s\n' "recorded revision"      "$REV_TYPE"
printf '  %-34s %s\n' "recorded head tree"     "$HEAD_TYPE"
printf '  %-34s %s\n' "recorded effective tree" "$EFF_TYPE"
echo
echo "############ 3. RECONSTRUCT FROM THE CLONE, NOT FROM THIS MACHINE ############"
cat <<'TXT'
  The same reconstruction verify_lineage.sh did locally, re-run against the
  fresh clone's object database: head tree, plus the banked guard, applied
  through a temporary index. If this holds here, the banked patch and the
  durable remote together are sufficient -- the local disk is not needed.
TXT
echo
if [ "$CLONE_RC" = 0 ]; then
  IDX="$W/fresh.idx"; rm -f "$IDX"
  "${CLONE_ENV[@]}" GIT_INDEX_FILE="$IDX" git -C "$C" read-tree "$HEAD_TREE" 2>/dev/null
  if "${CLONE_ENV[@]}" GIT_INDEX_FILE="$IDX" git -C "$C" apply --cached "$P" 2>/dev/null; then
    FRESH=$("${CLONE_ENV[@]}" GIT_INDEX_FILE="$IDX" git -C "$C" write-tree)
  else
    FRESH=none; echo "  the banked guard does not apply inside the fresh clone"
  fi
else
  FRESH=none
fi
echo "  reconstructed in the fresh clone  $FRESH"
echo "  the frozen record's effective tree $EFF_TREE"
echo
echo "############ 4. NEGATIVE CONTROL ############"
cat <<'TXT'
  A clone that answers "yes" to everything proves nothing. Two controls: a
  tree hash that was never published must NOT resolve, and the tag must not be
  movable by this operator without a force (the branch is protected, so a
  non-fast-forward push has to be refused by the server, not by politeness).
TXT
echo
FAKE=$(python3 -c "
h='$EFF_TREE'
print(h[:-1] + ('0' if h[-1] != '0' else '1'))")
echo "  a one-nibble-different tree hash: $FAKE"
FAKE_TYPE=$(r cat-file -t "$FAKE" || echo UNRESOLVABLE)
echo "    resolves as: $FAKE_TYPE   (UNRESOLVABLE is required)"
echo "  control 2a -- an ANONYMOUS push must be refused."
cat <<'TXT'
    This proves only that the repository is not world-writable. It cannot
    prove the branch is protected, because an unauthenticated push is refused
    before protection is ever consulted. Reported separately for that reason.
TXT
ANON=$("${CLONE_ENV[@]}" git -C "$C" push "https://github.com/$SLUG.git" \
      "$REV:refs/heads/$BRANCH" 2>&1 | tail -3)
echo "$ANON" | sed 's/^/    /'
ANON_REFUSED=$(printf '%s' "$ANON" | grep -ciE 'reject|denied|403|authentication|could not read|terminal prompts disabled')
echo "    refused: $ANON_REFUSED  (non-zero required)"
echo
echo "  control 2b -- an AUTHENTICATED, NON-FORCE rewind must be refused."
cat <<'TXT'
    The operator holds a token with push rights, so this is not refused for
    lack of credentials. It pushes the branch's own parent, which is a
    non-fast-forward.

    WHAT THIS DOES NOT SHOW. It does not isolate branch protection: an
    ordinary non-fast-forward is refused with or without protection. The
    force-push variant, which protection alone can stop, was NOT exercised --
    this environment blocks force-pushes outright, and working around that to
    obtain a nicer transcript would be the wrong trade. So protection itself
    rests on 2c, the configuration as the API reports it, and that is stated
    rather than implied.
TXT
AUTH=$(git -C "$C" push "https://github.com/$SLUG.git" \
      "$REV:refs/heads/$BRANCH" 2>&1 | tail -4)
echo "$AUTH" | sed 's/^/    /'
AUTH_REFUSED=$(printf '%s' "$AUTH" | grep -ciE 'reject|denied|protected|non-fast-forward|not permitted')
FORCE_CONTROL=NOT_EXERCISED_ENVIRONMENT_BLOCKS_FORCE_PUSH
echo "    refused: $AUTH_REFUSED  (non-zero required)"
echo
echo "  control 2c -- protection flags as the GitHub API reports them:"
gh api "repos/$SLUG/branches/$BRANCH/protection" 2>&1 | python3 -c "
import json,sys
raw = sys.stdin.read()
try: d = json.loads(raw)
except Exception: print('    unreadable:', raw[:120]); raise SystemExit
fp = d.get('allow_force_pushes', {}).get('enabled')
dl = d.get('allow_deletions', {}).get('enabled')
print(f'    allow_force_pushes = {fp}   (False required)')
print(f'    allow_deletions    = {dl}   (False required)')
print(f'PROTFLAGS {fp} {dl}')" | tee "$W/prot.txt" | grep -v '^PROTFLAGS'
PROTFLAGS=$(grep '^PROTFLAGS' "$W/prot.txt" | head -1)
echo "  branch still points at the published commit: $(r ls-remote \
      "https://github.com/$SLUG.git" "refs/heads/$BRANCH" | awk '{print $1}')"
AFTER_BR=$("${CLONE_ENV[@]}" git ls-remote "https://github.com/$SLUG.git" \
      "refs/heads/$BRANCH" 2>/dev/null | awk '{print $1}')
} > "$G/evidence/durable_clone_check.txt" 2>&1

want 'a fresh anonymous clone succeeds' 0 "${CLONE_RC:-1}"
want 'no local-path remote survives in the clone' 0 "${LOCALREMOTE:-1}"
want 'the clone borrows no local object store' none "${ALT:-unknown}"
want 'the canonical ref is an annotated tag' tag "${TAG_TYPE:-UNRESOLVABLE}"
want 'the tag resolves to the effective tree' "$EFF_TREE" "${TAG_TREE:-none}"
want 'the protected provenance branch exists' "${TAG_COMMIT:-none}" "${BR_COMMIT:-x}"
want 'the recorded revision resolves from the remote' commit "${REV_TYPE:-UNRESOLVABLE}"
want 'the recorded head tree resolves from the remote' tree "${HEAD_TYPE:-UNRESOLVABLE}"
want 'the guard reconstructs the tree inside the fresh clone' "$EFF_TREE" "${FRESH:-none}"
want 'an unpublished tree hash does not resolve' UNRESOLVABLE "${FAKE_TYPE:-tree}"
want 'an anonymous push is refused' yes \
     "$([ "${ANON_REFUSED:-0}" != 0 ] && echo yes || echo no)"
want 'an authenticated non-fast-forward rewind is refused' yes \
     "$([ "${AUTH_REFUSED:-0}" != 0 ] && echo yes || echo no)"
# Reported, not asserted away: naming the gap is the point.
ASSERTIONS+=("  note  force-push control $FORCE_CONTROL")
want 'the API reports force-push and deletion both disabled' \
     'PROTFLAGS False False' "${PROTFLAGS:-missing}"
want 'the branch still points at the published commit after the attacks' \
     "${TAG_COMMIT:-none}" "${AFTER_BR:-changed}"
{
  echo
  echo "ASSERTIONS (${#ASSERTIONS[@]} checked)"
  printf '%s\n' "${ASSERTIONS[@]}"
  echo
  echo "DD1_DURABILITY: $([ "$rc" = 0 ] && echo DURABLE_AND_ANONYMOUSLY_FETCHABLE || echo FAILED)"
} >> "$G/evidence/durable_clone_check.txt"
printf '%s\n' "${ASSERTIONS[@]}"
echo "DD1_DURABILITY: $([ "$rc" = 0 ] && echo DURABLE_AND_ANONYMOUSLY_FETCHABLE || echo FAILED)"
exit "$rc"
