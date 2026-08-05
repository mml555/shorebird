#!/usr/bin/env bash
# cspell:words precompiler tearoff tearoffs selfhost
#
# dart_patches.sh — apply or verify the Dart-tree patch series.
#
# WHY THIS EXISTS: the Dart checkout our engine builds against is NOT in git
# (it lives on an external SSD under the engine's gclient tree), so the patches
# it carries were previously only documented in prose. That makes recreating a
# build host a manual recovery procedure. This script makes it reproducible:
# one pinned base commit, one ordered series, and a verify mode that fails
# loudly when a hunk is missing.
#
# Usage:
#   dart_patches.sh --dest <dart-checkout> [--apply | --verify]
#
#   --apply    Apply every patch that is not already applied (idempotent).
#   --verify   Check the base commit and that every patch is fully applied.
#              Exits non-zero and names what is missing. This is the mode to
#              run in CI or before trusting a rebuilt engine.
#
# The default is --verify, because checking is always safe and applying is not.
set -euo pipefail

# The vanilla Dart commit the whole toolchain is pinned to. This is the commit
# `refs/tags/3.12.2` points at — that tag is ANNOTATED, so `git ls-remote` shows
# the tag object (704629bc…) and not this commit. Do not "correct" one to the
# other; see UPSTREAM_INDEPENDENCE.md.
PINNED_DART_COMMIT="d684a576a6aa954ae107a03b2b4e1d61c3bebe93"

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# Order matters only in that each patch must apply to the pinned base; they
# touch disjoint files today, but keep them in series order anyway.
#
# Deliberately NOT in this list:
#   0002 — flutter tree (GN), not the Dart tree.
#   0003 — diagnostic only; see the header of that file.
PATCHES=(
  "$HERE/dart-fork/0001-snapshot-size-accessors.patch"
  "$HERE/0004-dart-tearoff-selector-guard.patch"
  "$HERE/0005-dart-precompiler-link-info-and-tearoffs.patch"
  "$HERE/0006-dart-no-dispatch-call-for-hash-slots.patch"
)

DEST=""
MODE="verify"

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) DEST="${2:?--dest needs a value}"; shift 2 ;;
    --apply) MODE="apply"; shift ;;
    --verify) MODE="verify"; shift ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$DEST" ]] || die "--dest is required (the Dart checkout to act on)"
[[ -d "$DEST/.git" ]] || die "not a git checkout: $DEST"

# `git apply` is run from the checkout root so the patches' a/ b/ prefixes line
# up regardless of where this script was invoked from.
applied() { git -C "$DEST" apply --reverse --check "$1" >/dev/null 2>&1; }
can_apply() { git -C "$DEST" apply --check "$1" >/dev/null 2>&1; }

echo "==> checkout: $DEST"

# The base check catches "someone recreated this on the wrong revision", which
# is the failure mode that costs a day rather than an hour.
#
# gclient syncs this tree with --no-history, so the pinned commit is usually NOT
# present as an object even when the tree is correct. A shallow checkout
# therefore downgrades this to a warning and relies on the per-patch checks
# below, which compare actual file contents.
if git -C "$DEST" cat-file -e "$PINNED_DART_COMMIT^{commit}" 2>/dev/null; then
  echo "==> pinned base present: ${PINNED_DART_COMMIT:0:12}"
elif [[ "$(git -C "$DEST" rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
  echo "==> shallow checkout; cannot confirm base ${PINNED_DART_COMMIT:0:12}"
  echo "    (relying on the per-patch content checks below)"
else
  echo "!!! pinned base ${PINNED_DART_COMMIT:0:12} is NOT in this checkout and" >&2
  echo "    it is not shallow, so this is the wrong Dart revision." >&2
  [[ "$MODE" == "verify" ]] && exit 1
  die "refusing to apply patches to an unknown base"
fi

missing=0
for patch in "${PATCHES[@]}"; do
  name="$(basename "$patch")"
  [[ -f "$patch" ]] || die "patch not found: $patch"

  if applied "$patch"; then
    echo "    [applied]  $name"
    continue
  fi

  if [[ "$MODE" == "verify" ]]; then
    # Distinguish "not applied yet" from "cannot apply", because the second one
    # means the patch has drifted from the tree and needs re-deriving.
    if can_apply "$patch"; then
      echo "    [MISSING]  $name" >&2
    else
      echo "    [CONFLICT] $name — does not apply cleanly; re-derive it" >&2
    fi
    missing=$((missing + 1))
    continue
  fi

  can_apply "$patch" || die "$name does not apply cleanly; re-derive it"
  git -C "$DEST" apply "$patch"
  echo "    [applied]  $name  (just now)"
done

if [[ "$MODE" == "verify" ]]; then
  if (( missing )); then
    echo
    echo "FAIL: $missing of ${#PATCHES[@]} patches are not applied." >&2
    echo "Run with --apply, then rebuild. An engine built from this checkout" >&2
    echo "as-is is NOT the engine our device proofs were made against." >&2
    exit 1
  fi
  echo
  echo "OK: all ${#PATCHES[@]} patches applied on the pinned base."
fi
