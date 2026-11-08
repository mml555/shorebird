#!/usr/bin/env bash
# publish_font_subset.sh — publish a fork-compatible <host>/font-subset.zip.
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
#                          [--host darwin-arm64|linux-x64] \
#                          [--const-finder <file>] \
#                          [--mirror http://localhost:8085] [--pinned <hash>]
set -euo pipefail

OVERLAY=""; REV=""; PINNED="69f9831c360d9152862ec3897c67fb09ae843f3b"
MIRROR="${FLUTTER_STORAGE_BASE_URL:-http://localhost:8085}"
# Which host cell's font-subset.zip to publish. The two supported cells source
# their const_finder DIFFERENTLY, which is the whole reason this is a flag:
#
#   darwin-arm64  the fork's own artifacts.zip already carries
#                 const_finder.dart.snapshot, so it is extracted from there.
#   linux-x64     it does NOT. The fork's linux-x64/artifacts.zip has neither
#                 const_finder nor font-subset, so the snapshot has to be BUILT
#                 and handed in with --const-finder.
#
# Building it: run upstream's own command (engine
# build/dart/internal/application_snapshot.gni) but with OUR dart as the
# compiler, because the kernel's SDK hash comes from the COMPILING VM:
#
#   <fork-sdk>/bin/dart --packages=<engine>/flutter/.dart_tool/package_config.json \
#     --snapshot=<out>.dill --snapshot-kind=kernel -Dsdk_hash=<first10 of rev> \
#     <engine>/flutter/tools/const_finder/bin/main.dart
#
# `-Dsdk_hash` is a program DEFINE, not the stamp — passing it while compiling
# with the prebuilt dart (d684a576) still yields a kernel our fork SDK rejects.
# Verified 2026-08-07: ninja's own output was rejected; the same command run
# with the fork dart produced a byte-different, same-sized kernel that loads.
HOST="darwin-arm64"
CONST_FINDER_FILE=""
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
    --host) HOST="${2:?}"; shift 2 ;;
    --const-finder) CONST_FINDER_FILE="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$OVERLAY" && -n "$REV" ]] || die "--overlay and --rev are required"
case "$HOST" in
  darwin-arm64) WANT_ARCH="arm64";  SDK_ZIP="dart-sdk-darwin-arm64.zip" ;;
  linux-x64)    WANT_ARCH="x86-64"; SDK_ZIP="dart-sdk-linux-x64.zip" ;;
  *) die "unsupported --host '$HOST' (expected darwin-arm64 or linux-x64)" ;;
esac

SRC_ZIP="$OVERLAY/flutter_infra_release/flutter/$REV/$HOST/artifacts.zip"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT

# A hash that does NOT publish our darwin host toolchain must keep the STOCK
# const_finder: a macOS build against such an engine runs the stock Dart SDK,
# so the stock kernel is the CONSISTENT one. Publish the pinned archive
# verbatim rather than leaving the path unpublished — @must_be_local owns it,
# and an owned-but-absent path is a loud 404.
if [[ ! -f "$OVERLAY/flutter_infra_release/flutter/$REV/$SDK_ZIP" ]]; then
  note "$REV publishes no $HOST host toolchain; mirroring the pinned font-subset verbatim"
  DEST_DIR="$OVERLAY/flutter_infra_release/flutter/$REV/$HOST"
  mkdir -p "$DEST_DIR"
  curl -sfL -o "$DEST_DIR/font-subset.zip" \
    "$MIRROR/flutter_infra_release/flutter/$PINNED/$HOST/font-subset.zip" \
    || die "could not fetch the pinned font-subset.zip from $MIRROR"
  note "wrote $DEST_DIR/font-subset.zip ($(wc -c < "$DEST_DIR/font-subset.zip" | tr -d ' ') bytes, stock const_finder)"
  exit 0
fi

CF_REV="$REV"
if [[ -n "$CONST_FINDER_FILE" ]]; then
  [[ -r "$CONST_FINDER_FILE" ]] || die "--const-finder $CONST_FINDER_FILE is unreadable"
  cp -f "$CONST_FINDER_FILE" "$STAGE/const_finder.dart.snapshot"
  CF_REV="$CONST_FINDER_FILE"
elif [[ ! -f "$SRC_ZIP" ]]; then
  die "no fork artifacts.zip at $SRC_ZIP (publish the engine first), and no --const-finder given"
elif ! unzip -o -q "$SRC_ZIP" const_finder.dart.snapshot -d "$STAGE" 2>/dev/null; then
  [[ -n "$CONST_FINDER_FROM" ]] \
    || die "$REV/$HOST/artifacts.zip has no const_finder.dart.snapshot; pass --const-finder-from <siblingHash> or --const-finder <file>"
  # Borrowing is only valid when both hashes ship the SAME Dart SDK, because
  # const_finder is keyed by SDK hash. Prove it before using it.
  sdk_rev_of() {
    unzip -p "$OVERLAY/flutter_infra_release/flutter/$1/$SDK_ZIP" \
      dart-sdk/revision 2>/dev/null | tr -d '[:space:]'
  }
  a="$(sdk_rev_of "$REV")"; b="$(sdk_rev_of "$CONST_FINDER_FROM")"
  [[ -n "$a" && "$a" == "$b" ]] \
    || die "dart-sdk mismatch: $REV has '${a:-none}', $CONST_FINDER_FROM has '${b:-none}' — refusing to borrow const_finder"
  note "dart-sdk match confirmed ($a); borrowing const_finder from $CONST_FINDER_FROM"
  CF_REV="$CONST_FINDER_FROM"
  unzip -o -q \
    "$OVERLAY/flutter_infra_release/flutter/$CONST_FINDER_FROM/$HOST/artifacts.zip" \
    const_finder.dart.snapshot -d "$STAGE" \
    || die "$CONST_FINDER_FROM/$HOST/artifacts.zip has no const_finder either"
fi
note "const_finder sourced from $CF_REV"

note "fetching upstream font-subset ($WANT_ARCH, not Dart-coupled) via the mirror"
curl -sfL -o "$STAGE/upstream.zip" \
  "$MIRROR/flutter_infra_release/flutter/$PINNED/$HOST/font-subset.zip" \
  || die "could not fetch the pinned font-subset.zip from $MIRROR"
unzip -o -q "$STAGE/upstream.zip" font-subset LICENSE.font_subset.md -d "$STAGE" \
  || die "upstream font-subset.zip is missing expected members"

# Refuse to ship a cross-architecture binary under an arm64 path.
ARCH="$(file -b "$STAGE/font-subset" | grep -oE 'arm64|x86_64|x86-64' | head -1)"
[[ "$ARCH" == "$WANT_ARCH" ]] || die "font-subset is $ARCH, expected $WANT_ARCH for $HOST — refusing to publish"
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

DEST_DIR="$OVERLAY/flutter_infra_release/flutter/$REV/$HOST"
mkdir -p "$DEST_DIR"
DEST_DIR="$(cd "$DEST_DIR" && pwd)"   # zip runs from $STAGE; needs an absolute path
ZIP="$DEST_DIR/font-subset.zip"
rm -f "$ZIP"
( cd "$STAGE" && zip -q "$ZIP" const_finder.dart.snapshot font-subset LICENSE.font_subset.md )

note "wrote $ZIP ($(wc -c < "$ZIP" | tr -d ' ') bytes)"
unzip -l "$ZIP" | sed 's/^/    /'
