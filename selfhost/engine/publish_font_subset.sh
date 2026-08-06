#!/usr/bin/env bash
# publish_font_subset.sh — publish a fork-compatible darwin-arm64/font-subset.zip.
#
# WHY THIS EXISTS (found by the first cold-cache warm run, 2026-08-06):
#
# `const_finder.dart.snapshot` does NOT ship in artifacts.zip. It ships in
# font-subset.zip. Both archives extract into the SAME cache directory
# (bin/cache/artifacts/engine/darwin-x64 — the legacy macOS host dir name;
# see flutter_cache.dart getBinaryDirs, which maps macOS to cache dir
# 'darwin-x64' but URL 'darwin-$arch/...'). So whichever is extracted LAST
# decides which const_finder the build uses.
#
# font-subset.zip was not owned by the mirror's @must_be_local list, so for a
# fork engine hash it silently fell back to the pinned revision -> upstream
# Flutter -> the STOCK const_finder, which overwrote the fork one that
# artifacts.zip had just delivered. Result: the release dies with
#   IconTreeShakerException: ConstFinder failure: Can't load Kernel binary:
#   Invalid SDK hash
# because const_finder is a KERNEL snapshot and its embedded SDK hash must
# match the Dart SDK loading it. Verified: our dart-sdk 6b58bb3a loads the
# fork const_finder and rejects the stock one with exactly that message.
#
# The working rig never hit this because its const_finder had been placed by
# hand. This script is what stops that from being a hand-injected artifact.
#
# WHAT GOES IN THE ARCHIVE
#   const_finder.dart.snapshot  <- OURS, from the fork's darwin-arm64
#                                  artifacts.zip (kernel; must match our SDK)
#   font-subset                 <- upstream's arm64 binary, unchanged. It is a
#                                  C++ (harfbuzz) tool with NO Dart SDK
#                                  coupling, and it is the correct ARCH for
#                                  this path. It is copied, never aliased from
#                                  another architecture.
#   LICENSE.font_subset.md      <- upstream's, unchanged
#
# Usage:
#   publish_font_subset.sh --overlay <dir> --rev <forkEngineHash> \
#                          [--mirror http://localhost:8085] [--pinned <hash>]
set -euo pipefail

OVERLAY=""; REV=""; PINNED="69f9831c360d9152862ec3897c67fb09ae843f3b"
MIRROR="${FLUTTER_STORAGE_BASE_URL:-http://localhost:8085}"
# Only some fork engine hashes had const_finder injected into their
# artifacts.zip. Every fork engine here is built against the SAME Dart SDK
# (verified: all publish dart-sdk revision 6b58bb3a), and const_finder is a
# kernel keyed by SDK hash, not by engine — so borrowing it from a sibling
# hash is correct. It is an EXPLICIT flag rather than a silent fallback, and
# the dart-sdk revisions are compared before it is used.
CONST_FINDER_FROM=""

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --overlay) OVERLAY="${2:?}"; shift 2 ;;
    --rev) REV="${2:?}"; shift 2 ;;
    --pinned) PINNED="${2:?}"; shift 2 ;;
    --mirror) MIRROR="${2:?}"; shift 2 ;;
    --const-finder-from) CONST_FINDER_FROM="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$OVERLAY" && -n "$REV" ]] || die "--overlay and --rev are required"

SRC_ZIP="$OVERLAY/flutter_infra_release/flutter/$REV/darwin-arm64/artifacts.zip"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT

# A hash that does NOT publish our darwin host toolchain must keep the STOCK
# const_finder: a macOS build against such an engine runs the stock Dart SDK,
# so the stock kernel is the CONSISTENT one. Publish the pinned archive
# verbatim rather than leaving the path unpublished — @must_be_local owns it,
# and an owned-but-absent path is a loud 404.
if [[ ! -f "$OVERLAY/flutter_infra_release/flutter/$REV/dart-sdk-darwin-arm64.zip" ]]; then
  note "$REV publishes no darwin host toolchain; mirroring the pinned font-subset verbatim"
  DEST_DIR="$OVERLAY/flutter_infra_release/flutter/$REV/darwin-arm64"
  mkdir -p "$DEST_DIR"
  curl -sfL -o "$DEST_DIR/font-subset.zip" \
    "$MIRROR/flutter_infra_release/flutter/$PINNED/darwin-arm64/font-subset.zip" \
    || die "could not fetch the pinned font-subset.zip from $MIRROR"
  note "wrote $DEST_DIR/font-subset.zip ($(wc -c < "$DEST_DIR/font-subset.zip" | tr -d ' ') bytes, stock const_finder)"
  exit 0
fi

[[ -f "$SRC_ZIP" ]] || die "no fork artifacts.zip at $SRC_ZIP (publish the engine first)"

CF_REV="$REV"
if ! unzip -o -q "$SRC_ZIP" const_finder.dart.snapshot -d "$STAGE" 2>/dev/null; then
  [[ -n "$CONST_FINDER_FROM" ]] \
    || die "$REV/darwin-arm64/artifacts.zip has no const_finder.dart.snapshot; pass --const-finder-from <siblingHash>"
  # Borrowing is only valid when both hashes ship the SAME Dart SDK, because
  # const_finder is keyed by SDK hash. Prove it before using it.
  sdk_rev_of() {
    unzip -p "$OVERLAY/flutter_infra_release/flutter/$1/dart-sdk-darwin-arm64.zip" \
      dart-sdk/revision 2>/dev/null | tr -d '[:space:]'
  }
  a="$(sdk_rev_of "$REV")"; b="$(sdk_rev_of "$CONST_FINDER_FROM")"
  [[ -n "$a" && "$a" == "$b" ]] \
    || die "dart-sdk mismatch: $REV has '${a:-none}', $CONST_FINDER_FROM has '${b:-none}' — refusing to borrow const_finder"
  note "dart-sdk match confirmed ($a); borrowing const_finder from $CONST_FINDER_FROM"
  CF_REV="$CONST_FINDER_FROM"
  unzip -o -q \
    "$OVERLAY/flutter_infra_release/flutter/$CONST_FINDER_FROM/darwin-arm64/artifacts.zip" \
    const_finder.dart.snapshot -d "$STAGE" \
    || die "$CONST_FINDER_FROM/darwin-arm64/artifacts.zip has no const_finder either"
fi
note "const_finder sourced from $CF_REV"

note "fetching upstream font-subset (arm64, not Dart-coupled) via the mirror"
curl -sfL -o "$STAGE/upstream.zip" \
  "$MIRROR/flutter_infra_release/flutter/$PINNED/darwin-arm64/font-subset.zip" \
  || die "could not fetch the pinned font-subset.zip from $MIRROR"
unzip -o -q "$STAGE/upstream.zip" font-subset LICENSE.font_subset.md -d "$STAGE" \
  || die "upstream font-subset.zip is missing expected members"

# Refuse to ship a cross-architecture binary under an arm64 path.
ARCH="$(file -b "$STAGE/font-subset" | grep -oE 'arm64|x86_64' | head -1)"
[[ "$ARCH" == "arm64" ]] || die "font-subset is $ARCH, expected arm64 — refusing to publish"
note "font-subset arch verified: $ARCH"

# Refuse to ship a const_finder our own SDK cannot load.
DART="${DART:-}"
if [[ -n "$DART" && -x "$DART" ]]; then
  if "$DART" "$STAGE/const_finder.dart.snapshot" 2>&1 | grep -q 'Invalid SDK hash'; then
    die "const_finder does not match $DART — refusing to publish"
  fi
  note "const_finder SDK-hash verified against $DART"
else
  note "DART not set; skipping the SDK-hash load check (set DART=<dart-sdk>/bin/dart)"
fi

DEST_DIR="$OVERLAY/flutter_infra_release/flutter/$REV/darwin-arm64"
mkdir -p "$DEST_DIR"
DEST_DIR="$(cd "$DEST_DIR" && pwd)"   # zip runs from $STAGE; needs an absolute path
ZIP="$DEST_DIR/font-subset.zip"
rm -f "$ZIP"
( cd "$STAGE" && zip -q "$ZIP" const_finder.dart.snapshot font-subset LICENSE.font_subset.md )

note "wrote $ZIP ($(wc -c < "$ZIP" | tr -d ' ') bytes)"
unzip -l "$ZIP" | sed 's/^/    /'
