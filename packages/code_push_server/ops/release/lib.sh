# cspell:words imagetools
# Shared helpers for the server release publisher.
#
# A server version must name ONE source revision, ONE manifest digest, and one
# permanently retrievable set of bytes. The publisher this replaces held none
# of those: it fired on `selfhost-v*` as well as `code_push_server-v*`, took the
# image's version from whatever `pubspec.yaml` said in the ref it happened to
# build, and re-tagged unconditionally.
#
# Measured 2026-09-06 against the live registry, which is why these guards
# exist and not as a precaution:
#
#   :code_push_server-v1.3.0 -> sha256:a6e8bde7…  schema 8   (cf74eeda, the release)
#   :1.3.0 = :selfhost-v1.1.1 = :latest
#                            -> sha256:320338b8…  schema 12  (bdb234ab, a distribution tag)
#
# The semantic tag does not name the release it is named after, and `:latest`
# followed it. The original bytes survived only because the git-tag
# traceability tag happened to be applied too — which is the whole argument for
# a retention reference that nothing in normal publishing can move.

# Resolve a reference to its manifest digest, or print nothing if absent.
# `imagetools` is used rather than raw registry HTTP so one code path serves
# GHCR and a throwaway local registry, using whatever credentials are loaded.
# An absent reference is a normal answer, not an error: callers ask precisely
# because they do not know yet. Without the `|| true` the failing inspect
# propagates through `pipefail` and `set -e` kills the publisher silently on
# the very first release, when nothing is published yet.
resolve_digest() {
  docker buildx imagetools inspect "$1" 2>/dev/null \
    | awk '/^Digest:/{print $2; exit}' || true
}

# The reference that must outlive every alias: one per source commit, never
# reused, and never moved by a later release. A backup records the manifest
# digest; this is what keeps those bytes reachable when human-facing aliases
# move on.
retention_ref() { # image, full commit sha
  printf '%s:source-%s' "$1" "$2"
}

die() { echo "RELEASE REFUSED: $*" >&2; exit 1; }
