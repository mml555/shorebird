#!/usr/bin/env bash
# cspell:words pubspec
# Bind a release to exactly one source revision, and refuse if the git tag and
# the package manifest disagree about what version this is.
#
# The old publisher read `version:` from whatever ref it was told to build and
# published that as the semantic tag. Three tags in this repository carry a
# pubspec that says 1.3.0 (code_push_server-v1.3.0, selfhost-v1.1.0,
# selfhost-v1.1.1) and only one of them is the 1.3.0 release, so reading the
# version was never enough to know which release was being cut.
#
# Usage: resolve_release.sh <git-tag>
# Emits KEY=VALUE lines for the caller to eval or append to $GITHUB_OUTPUT.
set -euo pipefail
cd "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
# shellcheck source=./lib.sh
. ops/release/lib.sh

TAG=${1:?usage: resolve_release.sh <git-tag>}

case "$TAG" in
  code_push_server-v*) MODE=release; VERSION="${TAG#code_push_server-v}" ;;
  selfhost-v*)         MODE=traceability; VERSION="" ;;
  *)                   MODE=dispatch; VERSION="" ;;
esac

COMMIT="$(git rev-list -n1 "$TAG" 2>/dev/null || git rev-parse "$TAG" 2>/dev/null || true)"
[[ -n "$COMMIT" ]] || die "cannot resolve '$TAG' to a commit"

PUBSPEC_VERSION="$(git show "$COMMIT:packages/code_push_server/pubspec.yaml" \
  | sed -n 's/^version: *//p' | head -1)"
[[ -n "$PUBSPEC_VERSION" ]] || die "no version in pubspec.yaml at $COMMIT"

if [[ "$MODE" == release ]]; then
  # Semantic versions only. A pre-release or build suffix would give the same
  # release two names and defeat the write-once check below it.
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "'$TAG' does not name a plain X.Y.Z version"
  [[ "$PUBSPEC_VERSION" == "$VERSION" ]] || die \
"the git tag and the package disagree about this release.
     tag says     : $VERSION   (from $TAG)
     pubspec says : $PUBSPEC_VERSION   (at $COMMIT)
   A version names one source revision. Fix pubspec.yaml or the tag."
fi

echo "mode=$MODE"
echo "commit=$COMMIT"
echo "version=$VERSION"
echo "pubspec_version=$PUBSPEC_VERSION"
