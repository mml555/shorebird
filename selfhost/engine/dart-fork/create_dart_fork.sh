#!/usr/bin/env bash
#
# create_dart_fork.sh — build OUR Dart VM fork, the foundation for every
# engine build we do.
#
# Why this exists: Shorebird's DEPS pins engine/src/flutter/third_party/dart to
# the PRIVATE git@github.com:shorebirdtech/dart-sdk. Their engine and framework
# forks are public, but the VM is not, so the captured engine source does not
# compile as-is. See selfhost/ENGINE_BUILD.md.
#
# What we do instead: take the same Dart revision vanilla Flutter 3.44.8 pins
# (dart.googlesource.com/sdk @ d684a576 = "Version 3.12.2", the version
# selfhost/compatibility.yaml records for this pin) and add only what the
# Shorebird engine hooks actually require — two snapshot-size accessors. The
# resulting repo is served to gclient over file://, so nothing needs hosting.
#
# Scope, honestly: this is enough to BUILD the engine. It is NOT parity with
# their fork — it has no AOT linker (pkg/aot_tools) and no interpreter wiring,
# which is what iOS code push needs. Android patches carry real machine code and
# never invoke the linker, so Android is the cell this unblocks.
#
# Usage:
#   selfhost/engine/dart-fork/create_dart_fork.sh [--dest <dir>]
#
#   --dest <dir>   Where to create the fork. Default: /data/shorebird-engine/src/dart-sdk
#
# Prints the resulting commit sha, which is what you put in .gclient:
#   "custom_deps": {
#     "engine/src/flutter/third_party/dart": "file://<dest>@<sha>",
#   }
set -euo pipefail

# The Dart revision vanilla Flutter 3.44.8 pins. Keep in lockstep with
# flutter_revision in selfhost/compatibility.yaml: on a Flutter bump, read the
# new DEPS' dart_revision from flutter/flutter at that release tag.
VANILLA_DART_REV="d684a576a6aa954ae107a03b2b4e1d61c3bebe93"
DART_GIT="https://dart.googlesource.com/sdk.git"

DEST="/data/shorebird-engine/src/dart-sdk"
PATCH_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) DEST="${2:?--dest needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,35p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v git >/dev/null || die "git not found"

if [[ -d "$DEST/.git" ]]; then
  note "Reusing existing checkout at $DEST"
else
  note "Fetching vanilla Dart $VANILLA_DART_REV (shallow) into $DEST"
  mkdir -p "$DEST"
  git -C "$DEST" init -q .
  git -C "$DEST" remote add origin "$DART_GIT"
  # Fetching a bare sha works because it is reachable from a ref upstream.
  nice -n 10 git -C "$DEST" fetch -q --depth=1 origin "$VANILLA_DART_REV"
  git -C "$DEST" checkout -q -b selfhost/experimental FETCH_HEAD
  git -C "$DEST" config user.email "selfhost@localhost"
  git -C "$DEST" config user.name "Shorebird selfhost fork"
fi

BASE="$(git -C "$DEST" rev-parse HEAD)"
note "Base: $BASE"

# Idempotent: if the accessors are already there, don't re-apply.
if grep -q "Dart_SnapshotDataSize" "$DEST/runtime/include/dart_api.h"; then
  note "Patch already applied."
else
  PATCH="$PATCH_DIR/0001-snapshot-size-accessors.patch"
  [[ -f "$PATCH" ]] || die "patch not found: $PATCH"
  note "Applying $(basename "$PATCH")"
  git -C "$DEST" apply --check "$PATCH" \
    || die "patch does not apply cleanly — the Dart revision probably moved. Re-derive it against the new base."
  git -C "$DEST" apply "$PATCH"
  git -C "$DEST" add -A
  git -C "$DEST" commit -q -m "Add snapshot size accessors for code push

Dart_SnapshotDataSize / Dart_SnapshotInstrSize, plus a public
Image::snapshot_size() accessor they need (Image::kHeaderSize is private, so
object_size() + kHeaderSize does not compile outside the class).

The Shorebird engine hooks present vm_data, iso_data, vm_instructions and
iso_instructions to the updater as one contiguous byte stream and need each
blob's length while holding only a non-owned pointer. Both values already exist
in headers the VM writes: Snapshot::length() and the ImageSize header field."
fi

SHA="$(git -C "$DEST" rev-parse HEAD)"
echo
note "Fork ready."
echo "  path: $DEST"
echo "  sha:  $SHA"
echo "  delta vs vanilla:"
git -C "$DEST" diff --stat "$VANILLA_DART_REV" "$SHA" | sed 's/^/    /'
echo
echo "Point the engine checkout's .gclient at it:"
echo "  \"custom_deps\": {"
echo "    \"engine/src/flutter/third_party/dart\": \"file://$DEST@$SHA\","
echo "  },"
