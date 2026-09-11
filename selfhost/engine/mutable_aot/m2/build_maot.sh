#!/usr/bin/env bash
# Build the MAOT host toolchain and record WHAT WAS BUILT.
#
# The record this lane writes names a fork revision. For that name to mean
# anything, the binaries have to have been built from it -- and an earlier
# version of this check compared file mtimes, which is wrong twice over: a
# `git checkout` rewrites every mtime without changing a byte, and `touch`
# changes an mtime without changing anything at all.
#
# So this writes the DIGEST of each MAOT source into the output directory
# after a successful build, and the gate compares digests. Switching branches,
# editing without rebuilding, or a build that only half-succeeded all change
# the comparison; touching a file does not.
set -euo pipefail

FORK="${MAOT_FORK:-/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart}"
SRC_ROOT="${MAOT_SRC_ROOT:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${MAOT_OUT:-$SRC_ROOT/out/maot_host}"
DEPOT="${DEPOT_TOOLS:-/Volumes/build/ios-engine/depot_tools}"

SOURCES=(
  runtime/vm/maot_registry.cc
  runtime/vm/maot_registry.h
  runtime/vm/kernel_loader.cc
  runtime/vm/object_store.h
  runtime/vm/dart.cc
  runtime/vm/compiler/aot/precompiler.cc
  runtime/vm/compiler/aot/precompiler.h
  runtime/vm/compiler/frontend/kernel_translation_helper.cc
  runtime/vm/compiler/frontend/kernel_translation_helper.h
  runtime/vm/compiler/backend/flow_graph_compiler_arm64.cc
  runtime/vm/compiler/backend/inliner.cc
)

for f in "${SOURCES[@]}"; do
  if [[ ! -f "$FORK/$f" ]]; then
    echo "FATAL: $FORK is not on a Mutable-AOT revision ($f is absent)." >&2
    echo "The rig is shared. See m2/rescued/R3_STATE_BEFORE_BORROW.txt" >&2
    exit 3
  fi
done

# Never `ninja ... | tail`: the pipeline reports tail's status, ninja fails
# silently, and the lane then measures a binary that is minutes old. That is
# not hypothetical -- it happened, and only a falsification arm caught it.
PATH="$DEPOT:$PATH" ninja -C "$OUT" gen_snapshot dartaotruntime
NINJA_RC=$?
if [[ $NINJA_RC -ne 0 ]]; then
  echo "FATAL: ninja exited $NINJA_RC; no digest written" >&2
  exit "$NINJA_RC"
fi

{
  echo "# written by build_maot.sh after a successful build"
  echo "fork_commit $(git -C "$FORK" rev-parse HEAD)"
  echo "fork_tree $(git -C "$FORK" rev-parse 'HEAD^{tree}')"
  echo "built_at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for f in "${SOURCES[@]}"; do
    echo "$(shasum -a 256 "$FORK/$f" | cut -d' ' -f1) $f"
  done
} > "$OUT/.maot_source_digest"

echo "built and recorded: $OUT/.maot_source_digest"
