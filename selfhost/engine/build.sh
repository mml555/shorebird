#!/usr/bin/env bash
#
# build.sh — build the Shorebird engine from the captured source (vendor/flutter)
# by delegating to Shorebird's OWN vendored CI build scripts. Does not upload;
# run publish_to_store.sh afterward to push artifacts to our object store.
#
# Usage:
#   selfhost/engine/build.sh [mac|linux|win]     # default: auto-detect host
#
# This automates the safe/orchestration parts (prereq checks, invoking the real
# build). The one-time gclient checkout+sync is a farm bootstrap step you do
# first — see .gclient.template and Flutter's engine setup docs; this script
# verifies it was done and stops with instructions if not.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"
FLUTTER_ROOT="$REPO_ROOT/vendor/flutter"
ENGINE_ROOT="$FLUTTER_ROOT/engine"
ENGINE_SRC="$ENGINE_ROOT/src"
CI_DIR="$FLUTTER_ROOT/shorebird/ci"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

# --- Resolve host / platform -------------------------------------------------
HOST="${1:-}"
if [[ -z "$HOST" ]]; then
  case "$(uname -s)" in
    Darwin) HOST=mac ;;
    Linux)  HOST=linux ;;
    MINGW*|MSYS*|CYGWIN*) HOST=win ;;
    *) die "unsupported host $(uname -s); pass mac|linux|win explicitly" ;;
  esac
fi
BUILD_SCRIPT="$CI_DIR/internal/${HOST}_build.sh"
SETUP_SCRIPT="$CI_DIR/internal/${HOST}_setup.sh"

# --- Sanity: captured source present ----------------------------------------
[[ -d "$FLUTTER_ROOT" ]]        || die "vendor/flutter not found (run the source-capture; see vendor/flutter/VENDOR.md)"
[[ -f "$BUILD_SCRIPT" ]]        || die "vendored build script missing: $BUILD_SCRIPT"
[[ -f "$ENGINE_SRC/flutter/tools/gn" ]] || die "engine/src/flutter/tools/gn missing under vendor/flutter"

# --- Report the pinned revisions we are building ----------------------------
ENGINE_HASH="$(tr -d '[:space:]' < "$FLUTTER_ROOT/bin/internal/engine.version")"
note "Building engine revision: $ENGINE_HASH"
note "Host build type: $HOST   (engine root: $ENGINE_ROOT)"

# --- Prereqs ----------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || die "missing prerequisite: $1 ($2)"; }
need cargo "install Rust: https://rustup.rs — needed for the patch tool + updater"
need ninja "install depot_tools (provides ninja) and add to PATH"
need gn    "install depot_tools (provides gn) and add to PATH"
need python3 "required by the engine framework-packaging scripts"

# gclient sync marker: after a successful sync, engine/src has third_party deps.
if [[ ! -d "$ENGINE_SRC/third_party/dart" ]]; then
  cat >&2 <<EOF
ERROR: the engine dependencies are not synced.

vendor/flutter is a flat SOURCE snapshot; the ~30-50GB of DEPS-pinned engine
dependencies (Skia, dart-sdk, buildtools, …) must be fetched with gclient first.

One-time bootstrap (on the build farm):
  1. Install depot_tools and put it on PATH.
  2. Create a .gclient (see selfhost/engine/.gclient.template) that points at
     this checkout, or follow Flutter's engine setup for the pinned revision.
  3. Run:  cd "$ENGINE_SRC" && gclient sync -D
Then re-run this script.
EOF
  exit 1
fi

# --- Disk check (warn only) --------------------------------------------------
AVAIL_GB="$(df -Pg "$ENGINE_SRC" 2>/dev/null | awk 'NR==2{print $4}')"
if [[ -n "${AVAIL_GB:-}" && "$AVAIL_GB" -lt 60 ]]; then
  echo "WARNING: only ${AVAIL_GB}GB free under $ENGINE_SRC; a full build wants ~60GB+." >&2
fi

# --- Build: delegate to Shorebird's real vendored scripts -------------------
cd "$CI_DIR"
if [[ -f "$SETUP_SCRIPT" ]]; then
  note "Running vendored setup: internal/${HOST}_setup.sh"
  bash "internal/${HOST}_setup.sh"
fi
note "Running vendored build: internal/${HOST}_build.sh $ENGINE_ROOT"
bash "internal/${HOST}_build.sh" "$ENGINE_ROOT"

note "Build complete. Artifacts are under: $ENGINE_SRC/out"
note "Next: selfhost/engine/publish_to_store.sh $ENGINE_HASH"
