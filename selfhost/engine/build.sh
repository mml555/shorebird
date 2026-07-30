#!/usr/bin/env bash
# cspell:words worktree
#
# build.sh — build the Shorebird engine from a synced Shorebird Flutter checkout.
# Does not upload; run publish_to_store.sh (object store) or overlay_publish.sh
# (local overlay in front of the CDN mirror) afterward.
#
# Two modes:
#
#   build.sh                          Full vendored CI shard for the host, by
#                                     delegating to Shorebird's OWN scripts in
#                                     vendor/flutter/shorebird/ci/. Faithful to
#                                     their CI; expensive (on Linux: 3 Android
#                                     arches + host_release with from-source
#                                     Dart + host_debug).
#
#   build.sh --cell android-arm64     Minimal experimental cell: just the one
#                                     configuration that carries engine changes
#                                     to an Android arm64 device. Linux host
#                                     only. Everything else in the artifact set
#                                     is served from the pinned revision (see
#                                     overlay_publish.sh).
#
# Options:
#   --cell <name>   Build one cell instead of the full shard. Only
#                   `android-arm64` today.
#   --host <os>     mac|linux|win. Default: auto-detect.
#   --jobs <n>      ninja parallelism for --cell builds. Default: 3, which is
#                   deliberately low — the documented build host is a 4-vCPU box
#                   shared with another service (see selfhost/ENGINE_BUILD.md).
#   --root <dir>    Flutter checkout to build. Default: vendor/flutter. On a
#                   build farm this is normally a real git clone of the pinned
#                   revision, because gclient and Flutter's own scripts need
#                   git; vendor/flutter is a history-less snapshot.
#
# This script automates the safe/orchestration parts (prereq checks, invoking
# the real build). The one-time gclient checkout+sync is a farm bootstrap step
# you do first — see .gclient.template; this script verifies it was done and
# stops with instructions if not.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"

CELL=""
HOST=""
JOBS=3
FLUTTER_ROOT="$REPO_ROOT/vendor/flutter"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cell) CELL="${2:?--cell needs a value}"; shift 2 ;;
    --host) HOST="${2:?--host needs a value}"; shift 2 ;;
    --jobs) JOBS="${2:?--jobs needs a value}"; shift 2 ;;
    --root) FLUTTER_ROOT="${2:?--root needs a value}"; shift 2 ;;
    mac|linux|win) HOST="$1"; shift ;;   # positional form, kept for compatibility
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

FLUTTER_ROOT="$(cd -- "$FLUTTER_ROOT" >/dev/null 2>&1 && pwd)" \
  || die "checkout not found: $FLUTTER_ROOT"
ENGINE_ROOT="$FLUTTER_ROOT/engine"
ENGINE_SRC="$ENGINE_ROOT/src"
CI_DIR="$FLUTTER_ROOT/shorebird/ci"

# --- Resolve host / platform -------------------------------------------------
if [[ -z "$HOST" ]]; then
  case "$(uname -s)" in
    Darwin) HOST=mac ;;
    Linux)  HOST=linux ;;
    MINGW*|MSYS*|CYGWIN*) HOST=win ;;
    *) die "unsupported host $(uname -s); pass --host mac|linux|win explicitly" ;;
  esac
fi

# --- Sanity: source present --------------------------------------------------
[[ -f "$FLUTTER_ROOT/DEPS" ]]            || die "$FLUTTER_ROOT is not a Flutter checkout (no DEPS)"
[[ -x "$ENGINE_SRC/flutter/tools/gn" ]]  || die "engine/src/flutter/tools/gn missing under $FLUTTER_ROOT"

# --- Report the pinned revisions we are building ----------------------------
ENGINE_HASH="$(tr -d '[:space:]' < "$FLUTTER_ROOT/bin/internal/engine.version")"
note "Checkout:        $FLUTTER_ROOT"
note "engine.version:  $ENGINE_HASH"
note "Host build type: $HOST"

# --- Prereqs ----------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || die "missing prerequisite: $1 ($2)"; }
need cargo   "install Rust: https://rustup.rs — the updater is compiled by the GN build"
need ninja   "install depot_tools (provides ninja) and add to PATH"
need gn      "install depot_tools (provides gn) and add to PATH"
need python3 "required by the engine build + packaging scripts"

# gclient sync marker: after a successful sync the DEPS-pinned deps are present.
# NOTE the path — DEPS places third_party under engine/src/flutter, NOT
# engine/src (this check used to look in the wrong place and always failed).
if [[ ! -d "$ENGINE_SRC/flutter/third_party/dart" ]]; then
  cat >&2 <<EOF
ERROR: the engine dependencies are not synced.

$FLUTTER_ROOT holds SOURCE only; the ~40-60GB of DEPS-pinned engine
dependencies (Skia, dart-sdk, buildtools, the Android NDK/SDK, ...) must be
fetched with gclient first.

One-time bootstrap (on the build farm):
  1. Install depot_tools and put it on PATH.
  2. git config --global url."https://github.com/".insteadOf git@github.com:
     (DEPS pins the Dart SDK fork over SSH; this avoids needing a GitHub key.
     On a shared host, export GIT_CONFIG_GLOBAL=<worktree>/gitconfig first —
     it redirects --global to that file instead of ~/.gitconfig.)
  3. Copy a .gclient to the checkout ROOT — solution name ".", see
     selfhost/engine/.gclient.template or the in-tree
     engine/scripts/standard.gclient.
  4. Run:  cd "$FLUTTER_ROOT" && gclient sync --no-history
Then re-run this script.
EOF
  exit 1
fi

# --- Disk check (warn only) --------------------------------------------------
# `df -Pk` (POSIX 1K blocks), not `df -Pg`: -g is a BSD/macOS flag that GNU
# coreutils rejects, so on Linux the command failed, and under `set -e` with
# `pipefail` a failing substitution in an assignment exits the script — silently,
# because the error was sent to /dev/null. That aborted every run on Linux right
# here, which is the *only* supported host for the android-arm64 cell.
# `|| true` as well, so a "warn only" check can never again be fatal.
AVAIL_GB="$(df -Pk "$ENGINE_SRC" 2>/dev/null | awk 'NR==2{print int($4/1048576)}' || true)"
if [[ -n "${AVAIL_GB:-}" && "$AVAIL_GB" -lt 60 ]]; then
  echo "WARNING: only ${AVAIL_GB}GB free under $ENGINE_SRC; a full build wants ~60GB+." >&2
fi

# --- Minimal cell -----------------------------------------------------------
if [[ -n "$CELL" ]]; then
  [[ "$CELL" == "android-arm64" ]] || die "unknown cell: $CELL (only android-arm64)"
  [[ "$HOST" == "linux" ]] || die \
    "the android-arm64 cell is Linux-only here. Building Android from macOS needs
     extra GN args — see $FLUTTER_ROOT/shorebird/docs/BUILDING.md."

  # The Rust updater is compiled INSIDE the GN build by
  # //flutter/shell/common/shorebird:build_rust_updater, which drives cargo
  # directly and sets CC/AR/CARGO_TARGET_*_LINKER from the NDK itself. So the
  # target triple must be installed, but cargo-ndk is NOT required (the comment
  # in shorebird/ci/internal/linux_setup.sh predates build_rust_updater.py).
  if ! rustup target list --installed 2>/dev/null | grep -qx 'aarch64-linux-android'; then
    die "rust target aarch64-linux-android not installed: rustup target add aarch64-linux-android"
  fi

  OUT_DIR="out/android_release_arm64"
  note "Cell: android-arm64  (out/$OUT_DIR, ninja -j$JOBS)"

  cd "$ENGINE_SRC"
  # Flags per shorebird/docs/BUILDING.md (Linux / Android arm64). Note there is
  # NO `shorebird_runtime` GN arg at this revision — the Shorebird hooks are
  # unconditional, gated in GN by shorebird_updater_supported. BUILDING.md's iOS
  # example still passes it; don't copy that.
  ./flutter/tools/gn --no-rbe --no-enable-unittests \
    --android --android-cpu=arm64 --runtime-mode=release
  ninja -C "$OUT_DIR" -j "$JOBS" default gen_snapshot

  note "Cell complete. Expected artifacts under $ENGINE_SRC/$OUT_DIR:"
  for f in \
    "zip_archives/android-arm64-release/artifacts.zip" \
    "zip_archives/android-arm64-release/symbols.zip" \
    "zip_archives/android-arm64-release/linux-x64.zip" \
    "arm64_v8a_release.jar" \
    "arm64_v8a_release.pom"
  do
    if [[ -e "$OUT_DIR/$f" ]]; then echo "  + $f"; else echo "  - MISSING $f" >&2; fi
  done
  note "Next: selfhost/engine/overlay_publish.sh --hash <expHash> --root $FLUTTER_ROOT"
  exit 0
fi

# --- Full shard: delegate to Shorebird's real vendored scripts ---------------
BUILD_SCRIPT="$CI_DIR/internal/${HOST}_build.sh"
SETUP_SCRIPT="$CI_DIR/internal/${HOST}_setup.sh"
[[ -f "$BUILD_SCRIPT" ]] || die "vendored build script missing: $BUILD_SCRIPT"

cd "$CI_DIR"
if [[ -f "$SETUP_SCRIPT" ]]; then
  # The vendored setup scripts run `sudo apt install` and `cargo install`. On a
  # shared build host that is an invasive side effect, so it is opt-in.
  if [[ "${RUN_VENDORED_SETUP:-0}" == "1" ]]; then
    note "Running vendored setup: internal/${HOST}_setup.sh"
    bash "internal/${HOST}_setup.sh"
  else
    note "Skipping internal/${HOST}_setup.sh (it sudo-installs packages)."
    note "Run it once by hand, or re-run with RUN_VENDORED_SETUP=1."
  fi
fi
note "Running vendored build: internal/${HOST}_build.sh $ENGINE_ROOT"
bash "internal/${HOST}_build.sh" "$ENGINE_ROOT"

note "Build complete. Artifacts are under: $ENGINE_SRC/out"
note "Next: selfhost/engine/publish_to_store.sh $ENGINE_HASH"
