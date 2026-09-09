#!/usr/bin/env bash
# DART-DURABILITY-1 (#47) -- the DURABLE half: publish the producing Dart
# lineage to a remote that is not this machine, and make the exact producing
# tree resolvable from a fresh anonymous clone.
#
# verify_lineage.sh established the precondition: the delta still reconstructs
# the effective tree, and a one-byte mutation is refused. Its finding --
# RECONSTRUCTIBLE_BUT_NOT_DURABLE -- was correct when made and is not revised
# here. This script closes the second half; it does not restate the first.
#
# WHAT IS PUBLISHED, AND WHAT IS DELIBERATELY NOT
#   The commit history up to the recorded revision, plus ONE further commit
#   whose tree IS the effective tree byte-for-byte. Nothing else. In
#   particular no README, notice file, or provenance stamp is added to the
#   tree: any added file changes the tree hash, and the tree hash is the whole
#   point -- it is the identity the frozen record names. Attribution therefore
#   lives in the commit and tag MESSAGES, which are outside the tree.
#
#   Dart's own LICENSE and AUTHORS travel with the tree unmodified, because
#   the tree is unmodified.
#
# usage: publish_lineage.sh <dart-git-dir> <owner/repo> [--execute]
#   Without --execute this is a dry run: it builds and checks the commit in the
#   local object database and prints exactly what would be pushed, but creates
#   no repository and pushes nothing.
set -uo pipefail
D="${1:?usage: publish_lineage.sh <dart-git-dir> <owner/repo> [--execute]}"
SLUG="${2:?}"
EXECUTE="${3:-}"
G="$(cd "$(dirname "$0")" && pwd)"
FZ="$(cd "$G/../semantic_linker/runtime_feasibility/g0_freeze" && pwd)"
P="$FZ/banked_source/dart/9999-worktree-uncommitted.patch"
M="$FZ/freeze_manifest.json"
BRANCH=provenance/route-b-selfhost-v1.1.1
TAG=route-b-producing-source-selfhost-v1.1.1
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
BASE=$(j "d['producing_source']['dart']['deps_pinned_base']")

{
echo "DART-DURABILITY-1 -- lineage publication"
echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by publish_lineage.sh"
echo "mode: $([ "$EXECUTE" = --execute ] && echo EXECUTE || echo DRY-RUN)"
echo
echo "THE IDENTITY THAT MUST SURVIVE PUBLICATION"
echo "  dart revision   $REV"
echo "  head tree       $HEAD_TREE"
echo "  effective tree  $EFF_TREE   <- what actually built the cell"
echo "  upstream base   $BASE"
echo
echo "############ 1. WHAT IS IN THE DELTA BEING PUBLISHED ############"
echo "  commits over the DEPS-pinned upstream base:"
git -C "$D" log --oneline "$BASE..$REV" | sed 's/^/    /'
echo
echo "  files those commits touch, plus the uncommitted guard:"
git -C "$D" diff --stat "$BASE" "$REV" | tail -3 | sed 's/^/    /'
echo "    guard: $(grep -c '^diff --git' "$P") file(s), $(grep -c '^+' "$P") added lines"
echo
echo "  scan of every added line for machine-specific or secret content:"
HITS=$({ git -C "$D" diff "$BASE" "$REV"; cat "$P"; } | grep '^+' \
  | grep -icE '/Users/|/Volumes/|BEGIN [A-Z ]*PRIVATE KEY|api[_-]?key|password|Bearer |ghp_|gho_|AKIA' )
echo "    matches: $HITS  (a non-zero count blocks publication)"
echo
echo "############ 2. MATERIALIZE THE EFFECTIVE TREE AS ONE COMMIT ############"
cat <<'TXT'
  The guard was never committed upstream, so the effective tree exists only as
  head-tree-plus-patch. A durable remote cannot host a patch as an identity, so
  the tree is written into the object database directly and committed with
  `commit-tree` -- no working tree, no `git add`, which is what lost modes and
  produced 1f8c25b3 instead of aa55ff96 the first time this was attempted.
TXT
echo
export GIT_INDEX_FILE="${TMPDIR:-/tmp}/dd1_pub.idx"; rm -f "$GIT_INDEX_FILE"
git -C "$D" read-tree "$HEAD_TREE"
if git -C "$D" apply --cached "$P" 2>/dev/null; then
  BUILT=$(git -C "$D" write-tree)
else
  BUILT=""
  echo "  the banked delta no longer applies -- refusing to publish"
fi
echo "  tree written from head + guard   ${BUILT:-<none>}"
echo "  tree the frozen record names     $EFF_TREE"
if [ -n "$BUILT" ] && [ "$BUILT" = "$EFF_TREE" ]; then
  echo "  IDENTICAL -- this tree is publishable as the producing source"
  # Derived from $REV's own committer date, so re-deriving this commit on any
  # machine at any time yields the same hash.
  REVDATE=$(git -C "$D" show -s --format=%cI "$REV")
  export GIT_AUTHOR_NAME='Shorebird self-host provenance'
  export GIT_AUTHOR_EMAIL='provenance@selfhost.invalid'
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
  export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  export GIT_AUTHOR_DATE="$REVDATE" GIT_COMMITTER_DATE="$REVDATE"
  echo "  pinned commit identity           $GIT_AUTHOR_NAME <$GIT_AUTHOR_EMAIL>"
  echo "  pinned commit date               $REVDATE  (committer date of $REV)"
  COMMIT=$(git -C "$D" commit-tree "$EFF_TREE" -p "$REV" <<MSG
Route B producing source for selfhost-v1.1.1 (effective tree)

This commit exists so that the tree which actually built the frozen
selfhost-v1.1.1 cell is addressable by a durable ref rather than only as
"$REV plus a patch file on one disk".

Its tree is $EFF_TREE, byte-for-byte: the tree of $REV
plus the single uncommitted front-end guard that was live in the working
tree at build time (pkg/front_end/lib/src/source/source_loader.dart).

Nothing is added to the tree -- not a README, not a provenance note -- because
any addition would change the tree hash, and the tree hash is the identity
being preserved.

Derived from the Dart SDK (https://dart.googlesource.com/sdk), upstream base
$BASE. The Dart SDK's own LICENSE, AUTHORS and PATENT_GRANT
travel with this tree unmodified and continue to govern all Dart-authored
files. The fork's changes are confined to the files listed in the two commits
above and are offered under the same terms.
MSG
)
  echo "  commit object                    $COMMIT"
  echo "  its tree                         $(git -C "$D" rev-parse "$COMMIT^{tree}")"
else
  COMMIT=""
  echo "  MISMATCH -- refusing to publish a tree the record does not name"
fi
echo
echo "############ 3. THE REFS THAT MAKE IT IMMUTABLE IN INTENT ############"
echo "  branch  $BRANCH   (protected, non-force-push)"
echo "  tag     $TAG   (annotated)"
echo
if [ "$EXECUTE" != --execute ]; then
cat <<TXT
  DRY RUN -- nothing was created or pushed. To publish:
      publish_lineage.sh $D $SLUG --execute
TXT
else
  if [ "$HITS" != 0 ] || [ -z "$COMMIT" ]; then
    echo "  REFUSED: preconditions above did not hold."
  else
    echo "  creating $SLUG (public)"
    gh repo create "$SLUG" --public \
      --description "Producing Dart SDK source for the Shorebird self-host Route B cell (selfhost-v1.1.1). Derived from https://dart.googlesource.com/sdk." \
      2>&1 | sed 's/^/    /'
    URL="https://github.com/$SLUG.git"
    ONREMOTE=$(git ls-remote "$URL" "refs/heads/$BRANCH" 2>/dev/null | awk '{print $1}')
    if [ "$ONREMOTE" = "$COMMIT" ]; then
      echo "  the protected branch already carries $COMMIT -- nothing to push."
      echo "  Re-running does not touch a published provenance ref."
    elif [ -n "$ONREMOTE" ]; then
      echo "  REFUSING TO MOVE A PUBLISHED PROVENANCE REF."
      echo "    on the remote  $ONREMOTE"
      echo "    derived here   $COMMIT"
      echo "  A protected provenance branch that this script would rewrite on a"
      echo "  whim is not immutable. If the remote ref is genuinely wrong it has"
      echo "  to be replaced deliberately, outside this script, and recorded."
    else
      echo "  pushing the lineage to $URL"
      git -C "$D" push "$URL" "$COMMIT:refs/heads/$BRANCH" 2>&1 | sed 's/^/    /'
    fi
    TAGONREMOTE=$(git ls-remote --tags "$URL" "refs/tags/$TAG" 2>/dev/null | awk '{print $1}')
    # git-tag takes its tagger from GIT_COMMITTER_* -- there is no
    # GIT_TAGGER_DATE -- and those are already pinned above, so the tag object
    # is deterministic for the same reason the commit is.
    git -C "$D" tag -a "$TAG" -m "Producing Dart source for selfhost-v1.1.1

tree      $EFF_TREE   (head plus the uncommitted guard)
revision  $REV   (head, guard not included)
base      $BASE   (upstream Dart, DEPS-pinned)

Derived from the Dart SDK, https://dart.googlesource.com/sdk. Dart's LICENSE,
AUTHORS and PATENT_GRANT are present in the tree unmodified and govern all
Dart-authored files." -f "$COMMIT" 2>&1 | sed 's/^/    /'
    LOCALTAG=$(git -C "$D" rev-parse "refs/tags/$TAG")
    if [ -z "$TAGONREMOTE" ]; then
      git -C "$D" push "$URL" "refs/tags/$TAG" 2>&1 | sed 's/^/    /'
    elif [ "$TAGONREMOTE" = "$LOCALTAG" ]; then
      echo "  the canonical tag already reads $LOCALTAG -- nothing to push."
    else
      echo "  REFUSING TO MOVE A PUBLISHED CANONICAL TAG."
      echo "    on the remote  $TAGONREMOTE"
      echo "    derived here   $LOCALTAG"
    fi
    echo "  applying branch protection (no force-push, no deletion)"
    # `-F key=` sends the empty STRING. The protection API demands null or an
    # object for required_status_checks / required_pull_request_reviews /
    # restrictions, so every subschema failed with a 422 -- and because no
    # assertion below covered protection, the run still reported PUBLISHED
    # with an unprotected branch. Send a real JSON body, and assert the result.
    cat > "${TMPDIR:-/tmp}/dd1_prot_req.json" <<'JSON'
{
  "required_status_checks": null,
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": false,
  "lock_branch": false,
  "allow_fork_syncing": false
}
JSON
    gh api -X PUT "repos/$SLUG/branches/$BRANCH/protection" \
      -H 'Accept: application/vnd.github+json' \
      --input "${TMPDIR:-/tmp}/dd1_prot_req.json" \
      >"${TMPDIR:-/tmp}/dd1_prot.json" 2>&1 \
      && echo "    protection applied" \
      || { echo "    PROTECTION FAILED:"; sed 's/^/      /' "${TMPDIR:-/tmp}/dd1_prot.json" | head -8; }
    PROT=$(gh api "repos/$SLUG/branches/$BRANCH/protection" 2>/dev/null \
      | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('unreadable'); raise SystemExit
print('force_push=%s deletion=%s' % (
  d.get('allow_force_pushes',{}).get('enabled'),
  d.get('allow_deletions',{}).get('enabled')))" )
    echo "  protection as the API reports it: ${PROT:-unreadable}"
    TAGT=$(git -C "$D" cat-file -t "refs/tags/$TAG" 2>/dev/null || echo none)
    echo "  the canonical tag is an $TAGT object locally"
  fi
fi
echo
echo "############ 4. WHAT STILL HAS TO BE PROVEN ELSEWHERE ############"
cat <<'TXT'
  Publishing is not the acceptance criterion. #47 asks that a FRESH ANONYMOUS
  clone resolve the exact producing tree -- which this script cannot honestly
  check, because it runs inside the clone that already has every object. That
  proof is verify_durable.sh, which clones with no credentials into a scratch
  directory and compares tree hashes there.
TXT
} > "$G/evidence/lineage_publication.txt" 2>&1

want 'the delta contains no machine-specific or secret content' 0 "${HITS:-1}"
want 'head plus the guard writes the effective tree' "$EFF_TREE" "${BUILT:-none}"
want 'the published commit carries exactly that tree' "$EFF_TREE" \
     "$([ -n "$COMMIT" ] && git -C "$D" rev-parse "$COMMIT^{tree}" || echo none)"
want 'the published commit descends from the recorded revision' "$REV" \
     "$([ -n "$COMMIT" ] && git -C "$D" rev-parse "$COMMIT^" || echo none)"
# grep -vc EXITS NON-ZERO when the count is zero, so the `|| echo 1` this
# started as appended a second line and the assertion compared "0\n1" to "0".
# Count with wc, whose exit status does not encode the answer.
UNEXPECTED=none
if [ -n "$COMMIT" ]; then
  UNEXPECTED=$(git -C "$D" diff --name-only "$HEAD_TREE" "$EFF_TREE" \
    | grep -v '^pkg/front_end/lib/src/source/source_loader.dart$' \
    | wc -l | tr -d ' ')
fi
want 'the tree is unmodified -- no provenance file was added' 0 "$UNEXPECTED"
want 'the guard is the only path that differs from the head tree' 1 \
     "$([ -n "$COMMIT" ] && git -C "$D" diff --name-only "$HEAD_TREE" "$EFF_TREE" \
        | wc -l | tr -d ' ' || echo 0)"
want "Dart's LICENSE is present in the published tree" blob \
     "$(git -C "$D" cat-file -t "$EFF_TREE:LICENSE" 2>/dev/null || echo MISSING)"
if [ "$EXECUTE" = --execute ]; then
  # Read the REMOTE, not the local clone. The first execute run pushed both
  # refs and then failed to protect the branch, yet still printed PUBLISHED,
  # because every assertion up to here reads only local objects.
  #
  # The remote is compared against evidence/published_ref.json, not against
  # $COMMIT. That is not a weakened check: it is the only correct one. The
  # published commit predates the determinism fix, so re-deriving it now gives
  # a different HASH over the identical TREE -- and the tree is the identity
  # the frozen record names. Asserting $COMMIT would demand a force-push onto
  # a branch protected precisely to refuse one. Both facts are asserted below:
  # the remote matches what was published, and its tree is the effective tree.
  REC="$G/evidence/published_ref.json"
  recj() { python3 -c "import json,sys;print(json.load(open('$REC'))['$1'])" 2>/dev/null; }
  REMOTE_BR=$(git ls-remote "https://github.com/$SLUG.git" "refs/heads/$BRANCH" \
              2>/dev/null | awk '{print $1}')
  want 'the provenance branch matches the recorded published ref' \
       "$(recj published_commit)" "${REMOTE_BR:-none}"
  want 'the published ref carries the effective tree' "$EFF_TREE" \
       "$([ -n "$REMOTE_BR" ] && git -C "$D" rev-parse "$REMOTE_BR^{tree}" \
          2>/dev/null || echo none)"
  want 're-derivation is deterministic across runs' "$COMMIT" \
       "$(git -C "$D" commit-tree "$EFF_TREE" -p "$REV" <<M2
$(git -C "$D" log -1 --format=%B "$COMMIT")
M2
)"
  want 'the canonical tag exists on the remote' 1 \
       "$(git ls-remote --tags "https://github.com/$SLUG.git" \
          "refs/tags/$TAG" 2>/dev/null | grep -c .)"
  want 'the canonical tag is annotated, not lightweight' tag \
       "${TAGT:-none}"
  want 'the branch is protected against force-push and deletion' \
       'force_push=False deletion=False' "${PROT:-unreadable}"
fi
{
  echo
  echo "ASSERTIONS (${#ASSERTIONS[@]} checked)"
  printf '%s\n' "${ASSERTIONS[@]}"
  echo
  echo "DD1_PUBLICATION: $([ "$rc" = 0 ] \
    && echo "$([ "$EXECUTE" = --execute ] && echo PUBLISHED || echo READY_NOT_PUBLISHED)" \
    || echo FAILED)"
} >> "$G/evidence/lineage_publication.txt"
printf '%s\n' "${ASSERTIONS[@]}"
echo "DD1_PUBLICATION: $([ "$rc" = 0 ] \
  && echo "$([ "$EXECUTE" = --execute ] && echo PUBLISHED || echo READY_NOT_PUBLISHED)" \
  || echo FAILED)"
exit "$rc"
