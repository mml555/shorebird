#!/usr/bin/env bash
# cspell:words selfhost
#
# dart_patches.sh — verify the engine's Dart checkout is the Dart fork commit
# its own DEPS pins.
#
# Our Dart changes are commits on mml555/dart-sdk-shorebird-lineage. An engine
# tree pins one in its DEPS as `dart_sdk_revision`, so the tree's DEPS is the
# source of truth and nothing is hard-coded here. The old patch-apply flow (a
# .patch series applied onto a vanilla checkout) is retired: there is no --apply.
#
# Supported pairs:
#   main:               engine d0714887, Dart fork b4671ab7 (3.13 lineage)
#   selfhost/dart-3.14: the Flutter 3.50 candidate, Dart fork 0cd04a77 (3.14.0
#                       plus our commits); a candidate until the owner promotes it.
#
# Usage:
#   dart_patches.sh --dest <dart-checkout> [--deps <DEPS file>] [--strict-fork]
#                   [--allow-dirty] [--verify]
#
# --verify (the default, and the only mode) checks that
#   1. the engine DEPS (found by walking up from --dest, or --deps) has a real
#      dart_sdk_revision, not missing and not a placeholder;
#   2. the checkout's HEAD is that commit and tracked files are unmodified.
#      A stock tree must be clean. A Route B tree is patched on purpose (the
#      kill-gate and step-1 patches edit tracked files), so its callers pass
#      --allow-dirty: HEAD, origin and the fork branch are still checked and the
#      modified files are listed, but they do not fail. Cleanliness is `git
#      status`, so files marked assume-unchanged or skip-worktree are invisible
#      to it; the Route B scripts check their own sentinels for those edits;
#   3. the commit is on the Dart fork: origin is the fork repo and, when the
#      checkout has remote-tracking refs, an origin/* branch contains HEAD (local
#      only, no network). A --no-history gclient checkout has no such refs; the
#      origin URL check stands alone there. Refs that predate the commit (not
#      yet fetched) only warn; --strict-fork makes that an error.
# Exits non-zero and says what is wrong. Run it before trusting a build, and
# after any `gclient sync`.
set -euo pipefail

DART_FORK_REPO="mml555/dart-sdk-shorebird-lineage"

DEST=""
DEPS=""
STRICT=0
ALLOW_DIRTY=0

die() { echo "error: $*" >&2; exit 1; }
fail() { echo "!!! $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) DEST="${2:?--dest needs a value}"; shift 2 ;;
    --deps) DEPS="${2:?--deps needs a value}"; shift 2 ;;
    --strict-fork) STRICT=1; shift ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --verify) shift ;;
    --apply) die "--apply is retired: the Dart changes are commits on $DART_FORK_REPO; pin the commit in the engine DEPS and gclient sync" ;;
    -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$DEST" ]] || die "--dest is required (the Dart checkout to check)"
[[ -d "$DEST/.git" || -f "$DEST/.git" ]] || die "not a git checkout: $DEST"
LOGICAL="$(cd "$DEST" && pwd -L)"
DEST="$(cd "$DEST" && pwd -P)"

# One anchored pattern for both the walk-up and the extraction, so a DEPS that
# only mentions the name in a comment is not taken for the pin.
REV_RE="^[[:space:]]*['\"]dart_sdk_revision['\"][[:space:]]*:[[:space:]]*['\"]([^'\"]*)['\"]"
find_deps() { # find_deps <dir>: nearest ancestor DEPS that declares dart_sdk_revision
  local dir="$1"
  while [[ "$dir" != "/" ]]; do
    dir="$(dirname "$dir")"
    if [[ -f "$dir/DEPS" ]] && grep -Eq "$REV_RE" "$dir/DEPS"; then echo "$dir/DEPS"; return; fi
  done
}
if [[ -z "$DEPS" ]]; then
  # third_party/dart may be a symlink (e.g. to an SSD). The engine that owns it
  # is the one on the logical path; if the physical path leads to a different
  # DEPS, refuse rather than verify against the wrong pin.
  d_logical="$(find_deps "$LOGICAL")"
  d_physical="$(find_deps "$DEST")"
  if [[ -n "$d_logical" && -n "$d_physical" && "$(cd "$(dirname "$d_logical")" && pwd -P)" != "$(cd "$(dirname "$d_physical")" && pwd -P)" ]]; then
    fail "$LOGICAL resolves to $DEST, and the DEPS above each differ ($d_logical vs $d_physical); pass --deps"
  fi
  DEPS="${d_logical:-$d_physical}"
fi
[[ -n "$DEPS" && -f "$DEPS" ]] || fail "no engine DEPS with dart_sdk_revision found above $DEST (pass --deps)"

echo "==> checkout: $DEST"
echo "==> DEPS:     $DEPS"

want="$(sed -nE "s/${REV_RE}.*/\1/p" "$DEPS" | head -1)"
[[ -n "$want" ]] || fail "dart_sdk_revision is missing from $DEPS"
if [[ ! "$want" =~ ^[0-9a-f]{40}$ ]]; then
  fail "dart_sdk_revision is '$want' in $DEPS: a placeholder, not a commit sha"
fi

head="$(git -C "$DEST" rev-parse HEAD)"
if [[ "$head" != "$want" ]]; then
  fail "HEAD is ${head:0:12}, but DEPS pins ${want:0:12}. Run gclient sync (or fix DEPS)."
fi
dirty="$(git -C "$DEST" status --porcelain --untracked-files=no)"
if [[ -n "$dirty" ]]; then
  if [[ "$ALLOW_DIRTY" == 1 ]]; then
    echo "==> --allow-dirty: tracked files differ from the pinned commit (expected for a Route B tree):"
    echo "$dirty" | sed 's/^/    /'
  else
    echo "!!! tracked files differ from the pinned commit (pass --allow-dirty for a patched Route B tree):" >&2
    echo "$dirty" >&2
    exit 1
  fi
fi

origin="$(git -C "$DEST" remote get-url origin 2>/dev/null || true)"
# Exactly owner/repo on github.com, https or ssh, optional .git, nothing before
# or after (so evil-mml555/... and mml555/...-x are refused).
origin_re="^(https://([^/@]+@)?github\\.com/|git@github\\.com:|ssh://git@github\\.com/)${DART_FORK_REPO}(\\.git)?/?$"
[[ "$origin" =~ $origin_re ]] || fail "origin is '${origin:-none}', not github.com/$DART_FORK_REPO (https, git@ or ssh://, optional .git)"
note=""
if [[ -n "$(git -C "$DEST" for-each-ref refs/remotes 2>/dev/null)" ]]; then
  if [[ -z "$(git -C "$DEST" branch -r --contains "$want" --list 'origin/*' 2>/dev/null)" ]]; then
    msg="${want:0:12} is not on any fetched $DART_FORK_REPO branch (the local refs may be stale: git fetch origin)"
    [[ "$STRICT" == 1 ]] && fail "$msg"
    note=" -- WARNING: $msg"
  fi
else
  note=" (no remote-tracking refs; origin URL only)"
fi
echo
echo "OK: Dart checkout is DEPS' pinned fork commit ${want:0:12}$note."
