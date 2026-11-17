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
#   dart_patches.sh --dest <dart-checkout> [--deps <DEPS file>] [--strict-fork] [--verify]
#
# --verify (the default, and the only mode) checks that
#   1. the engine DEPS (found by walking up from --dest, or --deps) has a real
#      dart_sdk_revision, not missing and not a placeholder;
#   2. the checkout's HEAD is that commit and tracked files are unmodified;
#   3. the commit is on the Dart fork: origin is the fork repo and, when the
#      checkout has remote-tracking refs, a fork branch contains HEAD (local
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

die() { echo "error: $*" >&2; exit 1; }
fail() { echo "!!! $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) DEST="${2:?--dest needs a value}"; shift 2 ;;
    --deps) DEPS="${2:?--deps needs a value}"; shift 2 ;;
    --strict-fork) STRICT=1; shift ;;
    --verify) shift ;;
    --apply) die "--apply is retired: the Dart changes are commits on $DART_FORK_REPO; pin the commit in the engine DEPS and gclient sync" ;;
    -h|--help) sed -n '2,33p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$DEST" ]] || die "--dest is required (the Dart checkout to check)"
[[ -d "$DEST/.git" || -f "$DEST/.git" ]] || die "not a git checkout: $DEST"
DEST="$(cd "$DEST" && pwd -P)"

if [[ -z "$DEPS" ]]; then
  dir="$DEST"
  while [[ "$dir" != "/" ]]; do
    dir="$(dirname "$dir")"
    if [[ -f "$dir/DEPS" ]] && grep -q 'dart_sdk_revision' "$dir/DEPS"; then DEPS="$dir/DEPS"; break; fi
  done
fi
[[ -n "$DEPS" && -f "$DEPS" ]] || fail "no engine DEPS with dart_sdk_revision found above $DEST (pass --deps)"

echo "==> checkout: $DEST"
echo "==> DEPS:     $DEPS"

want="$(sed -nE "s/^[[:space:]]*['\"]dart_sdk_revision['\"][[:space:]]*:[[:space:]]*['\"]([^'\"]*)['\"].*/\1/p" "$DEPS" | head -1)"
[[ -n "$want" ]] || fail "dart_sdk_revision is missing from $DEPS"
if [[ ! "$want" =~ ^[0-9a-f]{40}$ ]]; then
  fail "dart_sdk_revision is '$want' in $DEPS: a placeholder, not a commit sha"
fi

head="$(git -C "$DEST" rev-parse HEAD)"
if [[ "$head" != "$want" ]]; then
  fail "HEAD is ${head:0:12}, but DEPS pins ${want:0:12}. Run gclient sync (or fix DEPS)."
fi
if [[ -n "$(git -C "$DEST" status --porcelain --untracked-files=no)" ]]; then
  echo "!!! tracked files differ from the pinned commit:" >&2
  git -C "$DEST" status --short --untracked-files=no >&2
  exit 1
fi

origin="$(git -C "$DEST" remote get-url origin 2>/dev/null || true)"
case "$origin" in
  *"$DART_FORK_REPO"|*"$DART_FORK_REPO".git) ;;
  *) fail "origin is '${origin:-none}', not $DART_FORK_REPO" ;;
esac
note=""
if [[ -n "$(git -C "$DEST" for-each-ref refs/remotes 2>/dev/null)" ]]; then
  if [[ -z "$(git -C "$DEST" branch -r --contains "$want" 2>/dev/null)" ]]; then
    msg="${want:0:12} is not on any fetched $DART_FORK_REPO branch (the local refs may be stale: git fetch origin)"
    [[ "$STRICT" == 1 ]] && fail "$msg"
    note=" -- WARNING: $msg"
  fi
else
  note=" (no remote-tracking refs; origin URL only)"
fi
echo
echo "OK: Dart checkout is DEPS' pinned fork commit ${want:0:12}$note."
