#!/usr/bin/env bash
# cspell:words SBRBPTCH killgate
#
# verify_container_reader.sh -- Route B 4b: the ENGINE-side container reader's
# rejection taxonomy.
#
# WHY THIS EXISTS RATHER THAN A gtest TARGET. The natural home for these is
# `flutter/shell/common/shorebird:shorebird_unittests`, and the assertions ARE
# written there (route_b_patch_unittests.cc). That target cannot link on this
# host: it pulls in runtime/shorebird/patch_cache.cc, which calls
# `Shorebird_ReadLinkHeader` -- a symbol only Shorebird's private Dart fork
# defines. So on a vanilla-Dart tree the whole unittest binary fails to build
# for reasons that have nothing to do with Route B.
#
# Rather than leave the taxonomy unexercised until someone gets a fork build,
# this compiles the REAL route_b_patch.cc against a stub and runs the same
# cases. No copy of the parser exists here; if the parser changes, this changes
# with it or fails.
#
# WHAT IT CANNOT COVER: kWrongRelease. That comparison needs a live isolate to
# read the running snapshot's build ID, so it is proven on device, in the
# milestone-1 sequence, not here.
set -uo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

READER="$SRC/flutter/shell/common/shorebird/route_b_patch.cc"
[ -f "$READER" ] || { echo "ERROR: no reader at $READER" >&2; exit 1; }

# The system toolchain, not the engine's bundled clang: buildtools' clang ships
# a libc++ that cannot find mbstate_t outside a full GN build's include set, and
# fighting that buys nothing here.
clang++ -std=c++20 -I"$SRC" -I"$SRC/flutter" \
  -o "$WORK/driver" "$HERE/container_reader_driver.cc" "$READER" || {
  echo "ERROR: driver failed to compile" >&2; exit 1; }

"$WORK/driver"
