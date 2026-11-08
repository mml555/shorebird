#!/usr/bin/env bash
# cspell:words armv onlyone PATCHFILE GNFILE TAGREFS NPAR PREFS DURPAR
# verify_engine_producer_durable.sh -- is the engine revision that produced a
# cell's executable members resolvable from a DURABLE remote, and is it exactly
# the revision we used?
#
# WHY THIS EXISTS. A cell whose executable members were produced by a commit
# that exists only on one machine is not repository-closed: the bytes are
# authenticated by the address, but nobody can ever rebuild or review them. This
# programme has already treated local-only source provenance as a real
# durability defect once.
#
# It deliberately does NOT trust the local checkout. Everything is fetched from
# the remote into a throwaway repository and compared against the bytes actually
# banked in this repo -- so "pushed" is established by reading the remote, not by
# the absence of an error from an earlier push.
#
# And it checks IDENTITY, not ancestry: [[branches-are-not-provenance]]. A branch
# can move. The assertion is on the commit sha, its parent sha, and its tree sha.
#
#   verify_engine_producer_durable.sh [--remote URL] [--rev SHA] [--parent SHA]
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REMOTE=${REMOTE:-https://github.com/mml555/shorebird-flutter.git}
REV=${REV:-f1a59b8a1609c51397601c36d586ad7763d57153}
PARENT=${PARENT:-dfa2b24ac38477f3705ff0357530f33fe09474b8}
PATCHFILE="$HERE/patches/0001-gate-macos-analyze-snapshot-applicability.patch"
GNFILE=engine/src/flutter/lib/snapshot/BUILD.gn
# --exists-only: assert reachability and nothing about content. For a revision
# the record names as a producer but whose DIFF this repo does not bank -- the
# macOS/iOS producer, which is upstream-derived and has no patch of ours.
EXISTS_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote) REMOTE="${2:?}"; shift 2 ;;
    --rev) REV="${2:?}"; shift 2 ;;
    --parent) PARENT="${2:?}"; shift 2 ;;
    --exists-only) EXISTS_ONLY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
fail=0
ok()  { printf '  \033[32mok    \033[0m %s\n' "$1"; }
bad() { printf '  \033[31mFAILED\033[0m %s\n' "$1"; fail=$((fail+1)); }

echo "remote: $REMOTE"
echo "rev:    $REV"

# 1. the remote must ADVERTISE the revision, under at least one ref.
LS=$(git ls-remote "$REMOTE" 2>&1)
[[ -n "$LS" ]] || { echo "cannot reach the remote" >&2; exit 2; }
REFS=$(awk -v r="$REV" '$1==r {print $2}' <<<"$LS" | sort | tr '\n' ' ')
if [[ -n "$REFS" ]]; then ok "the remote advertises $REV at: $REFS"
else bad "no ref on the remote points at $REV (reachable is not durable: a force-push removes reachability, a ref pointing AT the commit does not)"; fi
# An annotated tag's ref points at the TAG object, not the commit, so a tag is
# only counted once it is peeled.
TAGREFS=$(awk '$2 ~ /\^\{\}$/ {print}' <<<"$LS" | awk -v r="$REV" '$1==r {print $2}' | tr '\n' ' ')
[[ -n "$TAGREFS" ]] && ok "and by an annotated tag (peeled): $TAGREFS" \
                    || echo "  note   no annotated tag peels to this commit"

# 2. the PARENT must still be resolvable, at its own ref, unmoved. The 16
#    macOS/iOS members were produced by it and their provenance dies with it.
if [[ "$EXISTS_ONLY" == 0 ]]; then
  PREFS=$(awk -v r="$PARENT" '$1==r {print $2}' <<<"$LS" | tr '\n' ' ')
  # ADVERTISED AT A REF, not merely reachable. GitHub will serve a reachable
  # object to a direct fetch, but reachability is a property of some ref's
  # current tip and a force-push takes it away. Only a ref pointing AT the
  # commit makes it durable.
  [[ -n "$PREFS" ]] && ok "the parent $PARENT is still advertised at: $PREFS" \
                    || bad "the parent revision is not advertised at any ref on the remote"
fi

# 2b. --exists-only stops here: reachability is the whole claim for a revision
#     whose content this repo does not bank.
if [[ "$EXISTS_ONLY" == 1 ]]; then
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  git init -q "$T/probe"
  git -C "$T/probe" remote add origin "$REMOTE" >/dev/null
  if git -C "$T/probe" fetch -q --depth 1 origin "$REV" 2>/dev/null; then
    ok "the revision fetches from the remote into a fresh repository"
  else
    bad "the revision does not fetch from the remote"
  fi
  echo
  if [[ $fail -eq 0 ]]; then echo "ENGINE PRODUCER REACHABLE: $REV"; exit 0; else
    echo "ENGINE PRODUCER NOT DURABLE: $fail failure(s)"; exit 1; fi
fi

# 3. fetch it from the remote into a throwaway repo and read the object graph
#    there. Nothing below consults the local engine checkout.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git init -q "$T/probe"
git -C "$T/probe" remote add origin "$REMOTE" >/dev/null
if git -C "$T/probe" fetch -q --depth 2 origin "$REV" 2>/dev/null; then
  ok "the revision fetches from the remote into a fresh repository"
else
  bad "the revision does not fetch from the remote"; echo; exit 1
fi
GOT_PARENT=$(git -C "$T/probe" cat-file -p "$REV" | awk '$1=="parent"{print $2}')
NPAR=$(wc -w <<<"$GOT_PARENT" | tr -d ' ')
[[ "$NPAR" == 1 ]] && ok "exactly one parent (not a merge)" || bad "$NPAR parents"
[[ "$GOT_PARENT" == "$PARENT" ]] \
  && ok "the parent AS PUBLISHED is exactly $PARENT" \
  || bad "the published parent is $GOT_PARENT, not $PARENT"

# 4. the source of the one changed file, byte-for-byte against the patch this
#    repo banked. This is the step that makes "the pushed commit is the commit
#    we used" a measurement rather than an assumption: a rebuilt or amended
#    commit with the same message would fail here.
git -C "$T/probe" fetch -q --depth 2 origin "$PARENT" 2>/dev/null
D=$(git -C "$T/probe" diff "$PARENT" "$REV" -- "$GNFILE" | grep -c '^[+-][^+-]')
[[ "$D" -gt 0 ]] && ok "the published commit changes $GNFILE ($D changed lines)" \
                 || bad "the published commit does not change $GNFILE"
FILES=$(git -C "$T/probe" diff --name-only "$PARENT" "$REV" | tr '\n' ' ')
[[ "$FILES" == "$GNFILE " ]] && ok "and changes NOTHING else: $FILES" \
                             || bad "the published commit touches: $FILES"
if [[ -f "$PATCHFILE" ]]; then
  # Compare the +/- payload, not the whole patch: the banked file carries a
  # git-format-patch header whose hashes and dates are not part of the source.
  a=$(git -C "$T/probe" diff "$PARENT" "$REV" -- "$GNFILE" | grep '^[+-][^+-]' | shasum -a 256 | cut -c1-40)
  b=$(grep '^[+-][^+-]' "$PATCHFILE" | shasum -a 256 | cut -c1-40)
  [[ "$a" == "$b" ]] && ok "the published diff equals the banked patch ($a)" \
                     || bad "the published diff ($a) differs from the banked patch ($b)"
else
  bad "no banked patch at $PATCHFILE to compare against"
fi

# 5. the gate itself must be Dart's applicability predicate, read from the
#    PUBLISHED source. A durable commit that no longer carries the reviewed
#    change would satisfy everything above.
PUB=$(git -C "$T/probe" show "$REV:$GNFILE")
n=$(grep -c 'target_cpu == "x64" || target_cpu == "arm64" ||' <<<"$PUB")
[[ "$n" == 2 ]] && ok "both gate sites present in the published source" \
               || bad "$n gate site(s) in the published source, expected 2"

echo
if [[ $fail -eq 0 ]]; then echo "ENGINE PRODUCER DURABLE: $REV"; else
  echo "ENGINE PRODUCER NOT DURABLE: $fail failure(s)"; exit 1; fi
