#!/usr/bin/env bash
# cspell:words imagetools gittag
# Assemble and publish one server release, and refuse anything that would make
# a version name two different sets of bytes.
#
# Order matters here. The retention reference is created FIRST, because it is
# the only name that is write-once by construction (one per source commit) and
# because creating it is what tells us the manifest digest we are about to
# claim a semantic version for. Only then can "is :X.Y.Z already something
# else?" be answered without guessing.
#
# Usage:
#   IMAGE=... MODE=release|traceability|dispatch VERSION=X.Y.Z COMMIT=<sha40>
#   GIT_TAG=<tag or empty> CHILD_DIGESTS="sha256:… sha256:…"
#   publish_release.sh
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=./lib.sh
. "$HERE/lib.sh"

IMAGE=${IMAGE:?}; MODE=${MODE:?}; COMMIT=${COMMIT:?}
VERSION=${VERSION:-}; GIT_TAG=${GIT_TAG:-}; CHILD_DIGESTS=${CHILD_DIGESTS:?}
OUT=${OUT:-/dev/stdout}

[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "COMMIT must be a full 40-hex sha, got '$COMMIT'"
RETAIN="$(retention_ref "$IMAGE" "$COMMIT")"
SEMANTIC=""; [[ "$MODE" == release ]] && SEMANTIC="${IMAGE}:${VERSION}"

children=(); for d in $CHILD_DIGESTS; do
  [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]] || die "child digest '$d' is not a sha256 reference"
  children+=("${IMAGE}@${d}")
done
(( ${#children[@]} > 0 )) || die "no child digests to assemble"

existing_retain="$(resolve_digest "$RETAIN")"
existing_semantic=""; [[ -n "$SEMANTIC" ]] && existing_semantic="$(resolve_digest "$SEMANTIC")"

if [[ -n "$existing_retain" ]]; then
  # This commit has already been released. Never rebuild over its retention
  # reference: those are the bytes some backup's recorded digest points at.
  echo "==> $COMMIT is already released as $existing_retain"
  DIGEST="$existing_retain"
  if [[ -n "$SEMANTIC" && -n "$existing_semantic" && "$existing_semantic" != "$DIGEST" ]]; then
    die "$SEMANTIC already resolves to $existing_semantic, which is not this release ($DIGEST).
   A semantic version is write-once. It is not moved to point at a different
   build, because a backup taken under the old one records the old digest."
  fi
else
  docker buildx imagetools create --tag "$RETAIN" "${children[@]}"
  DIGEST="$(resolve_digest "$RETAIN")"
  [[ -n "$DIGEST" ]] || die "the retention reference did not resolve after creation"
  if [[ -n "$SEMANTIC" && -n "$existing_semantic" && "$existing_semantic" != "$DIGEST" ]]; then
    die "$SEMANTIC already resolves to $existing_semantic; this release is $DIGEST.
   A semantic version is write-once. Publishing this would leave every backup
   that recorded $existing_semantic pointing at bytes the tag no longer names."
  fi
fi

# Aliases, only now that the digest is known and nothing is being displaced.
alias_args=()
[[ -n "$SEMANTIC" && "$existing_semantic" != "$DIGEST" ]] && alias_args+=(--tag "$SEMANTIC")
[[ -n "$GIT_TAG" ]] && alias_args+=(--tag "${IMAGE}:${GIT_TAG}")
# `latest` follows a server release and nothing else: not a distribution tag,
# not a manual build, not a rerun of an older release.
if [[ "$MODE" == release ]]; then
  latest_now="$(resolve_digest "${IMAGE}:latest")"
  [[ "$latest_now" != "$DIGEST" ]] && alias_args+=(--tag "${IMAGE}:latest")
fi
if (( ${#alias_args[@]} > 0 )); then
  docker buildx imagetools create "${alias_args[@]}" "${IMAGE}@${DIGEST}"
fi

# --- post-publish verification -------------------------------------------
# `imagetools create` exiting 0 is not evidence that the registry now serves
# what we think it does. Read every reference back.
fail=0
verify_ref() { # ref, expected
  local got; got="$(resolve_digest "$1")"
  if [[ "$got" == "$2" ]]; then echo "    ok   $1 -> $got"
  else echo "    FAIL $1 -> ${got:-<absent>} (expected $2)"; fail=1; fi
}
echo "==> verifying what the registry actually serves"
verify_ref "$RETAIN" "$DIGEST"
[[ -n "$SEMANTIC" ]] && verify_ref "$SEMANTIC" "$DIGEST"
[[ -n "$GIT_TAG" ]] && verify_ref "${IMAGE}:${GIT_TAG}" "$DIGEST"
[[ "$MODE" == release ]] && verify_ref "${IMAGE}:latest" "$DIGEST"

# Every child architecture the release claims must be inside the manifest the
# registry serves, by digest.
served_children="$(docker buildx imagetools inspect --raw "${IMAGE}@${DIGEST}" \
  | python3 "$HERE/manifest_children.py")"
# A single-child `imagetools create` does not wrap anything: the published
# manifest IS that image manifest, so it has no `manifests[]` and its own
# digest is the one architecture it serves. Treating that as "no children"
# made the check fail on exactly the case it should have passed.
if [[ -z "$served_children" ]]; then
  served_children="$DIGEST $(docker buildx imagetools inspect "${IMAGE}@${DIGEST}" \
    | awk '/^Platform:/{print $2; exit}')"
fi
for d in $CHILD_DIGESTS; do
  if printf '%s\n' "$served_children" | grep -q "^$d "; then
    echo "    ok   child $d ($(printf '%s\n' "$served_children" | awk -v x="$d" '$1==x{print $2}'))"
  else
    echo "    FAIL child $d is not in the published manifest"; fail=1
  fi
done
(( fail == 0 )) || die "the registry does not serve what was just published"

python3 - "$OUT" <<PY
import json, sys
json.dump({
    "git_tag": "${GIT_TAG}",
    "mode": "${MODE}",
    "commit": "${COMMIT}",
    "version": "${VERSION}",
    "image": "${IMAGE}",
    "manifest_digest": "${DIGEST}",
    "child_digests": "${CHILD_DIGESTS}".split(),
    "semantic_tag": "${SEMANTIC}",
    "retention_ref": "${RETAIN}",
}, open(sys.argv[1], "w"), indent=2)
PY
echo "==> released $DIGEST"
echo "    retention reference: $RETAIN"
