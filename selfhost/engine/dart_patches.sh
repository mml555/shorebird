#!/usr/bin/env bash
# cspell:words selfhost
#
# dart_patches.sh — verify the engine's Dart checkout is our pinned Dart fork.
#
# The Dart changes we carry live as commits on a branch of
# mml555/dart-sdk-shorebird-lineage (selfhost/dart-3.14), on top of stock Dart
# 3.14.0. The engine's DEPS pins that commit as `dart_sdk_revision`, so the fork
# repo is the source of truth. The old patch-apply flow (a series of .patch
# files applied onto a vanilla checkout) is retired: there is no --apply.
#
# Usage:
#   dart_patches.sh --dest <dart-checkout> [--verify]
#
# --verify (the default, and the only mode) checks that the checkout's HEAD is
# the pinned fork commit and that its tracked files are unmodified. Exits
# non-zero and says what is wrong. Run it before trusting a build, and after any
# `gclient sync`, which can replace the tree.
set -euo pipefail

# Final commit of selfhost/dart-3.14 (Dart 3.14.0 fa8c1270 plus our commits).
PINNED_DART_COMMIT="0cd04a7717f20d5f9ae64014cb2239a3f961f895"
DART_STOCK_BASE="fa8c1270c374c1346931583a17c3b7f278d3822d"
DART_FORK_REPO="mml555/dart-sdk-shorebird-lineage"

DEST=""

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) DEST="${2:?--dest needs a value}"; shift 2 ;;
    --verify) shift ;;
    --apply) die "--apply is retired: the Dart changes are commits on $DART_FORK_REPO; pin the commit in DEPS and sync" ;;
    -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$DEST" ]] || die "--dest is required (the Dart checkout to check)"
[[ -d "$DEST/.git" || -f "$DEST/.git" ]] || die "not a git checkout: $DEST"

echo "==> checkout: $DEST"
head="$(git -C "$DEST" rev-parse HEAD)"
if [[ "$head" != "$PINNED_DART_COMMIT" ]]; then
  echo "!!! HEAD is ${head:0:12}, expected ${PINNED_DART_COMMIT:0:12} ($DART_FORK_REPO, stock base ${DART_STOCK_BASE:0:8})." >&2
  echo "    Set dart_sdk_revision in the engine DEPS to the pinned commit and run gclient sync." >&2
  exit 1
fi
if [[ -n "$(git -C "$DEST" status --porcelain --untracked-files=no)" ]]; then
  echo "!!! tracked files in $DEST differ from the pinned commit:" >&2
  git -C "$DEST" status --short --untracked-files=no >&2
  exit 1
fi
echo
echo "OK: Dart checkout is the pinned fork commit ${PINNED_DART_COMMIT:0:12}."
