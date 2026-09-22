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
  runtime/vm/compiler/frontend/kernel_binary_flowgraph.cc
  # Interpreted, not compiled in: gen_kernel runs these from source on every
  # invocation, so they cannot go stale against the binary the way a .cc can.
  # Recorded anyway. SELECTION itself lives in transformer.dart, and whether
  # maot:mutable is honoured at all lives in pragma.dart and vm.dart -- so
  # editing one of these changes which declarations exist without changing a
  # byte of the binary, and a record that does not name them cannot say which
  # sources produced the evidence.
  #
  # This list and the gates' lists must match EXACTLY in both directions: the
  # staleness check walks the recorded set and separately flags anything a
  # gate hashes that the record does not cover. A two-entry list here against
  # a four-entry list there reported every run as stale.
  pkg/vm/lib/metadata/maot_declaration_id.dart
  pkg/vm/lib/transformations/type_flow/transformer.dart
  # Selection itself lives here too: which declarations are mutable, and the
  # package-ownership policy that decides it. Editing this changes the
  # measured population without changing a byte of the binary, which is
  # exactly the staleness this record exists to catch.
  pkg/vm/lib/transformations/type_flow/maot_selection.dart
  pkg/vm/lib/transformations/pragma.dart
  pkg/vm/lib/modular/target/vm.dart
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

# The binary is now bound to the sources. Bind the sources to the NAMED
# COMMIT as well, because those are different claims and only the first was
# ever checked.
#
# The hole, exactly as it occurred: HEAD was 2e4df989 while the worktree
# already held what became b92efd82. The digest matched the dirty bytes, the
# binary was built from them, so `build_digest_matches` was true -- and the
# evidence still named 2e4df989 and its tree. Every link in the chain held
# except the one nobody checked: that the bytes measured are the bytes the
# named commit contains.
#
# Compared by CONTENT against the blob at HEAD, not with `git diff --quiet`,
# because that says nothing about a path git is not tracking at all.
DIRTY=()
for f in "${SOURCES[@]}"; do
  if ! git -C "$FORK" cat-file -e "HEAD:$f" 2>/dev/null; then
    DIRTY+=("$f (not tracked at HEAD)")
    continue
  fi
  have=$(shasum -a 256 "$FORK/$f" | cut -d' ' -f1)
  want=$(git -C "$FORK" cat-file blob "HEAD:$f" | shasum -a 256 | cut -d' ' -f1)
  if [[ "$have" != "$want" ]]; then
    DIRTY+=("$f")
  fi
done
if [[ ${#DIRTY[@]} -gt 0 ]]; then
  echo "FATAL: ${#DIRTY[@]} tracked MAOT source(s) differ from $(git -C "$FORK" rev-parse --short HEAD):" >&2
  printf '  %s\n' "${DIRTY[@]}" >&2
  echo "A record naming a commit whose bytes were never measured is not" >&2
  echo "provenance. Commit the change, then rebuild." >&2
  exit 4
fi

{
  echo "# written by build_maot.sh after a successful build"
  echo "fork_commit $(git -C "$FORK" rev-parse HEAD)"
  echo "fork_tree $(git -C "$FORK" rev-parse 'HEAD^{tree}')"
  echo "fork_sources_match_head 1"
  echo "built_at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for f in "${SOURCES[@]}"; do
    echo "$(shasum -a 256 "$FORK/$f" | cut -d' ' -f1) $f"
  done
} > "$OUT/.maot_source_digest"

echo "built and recorded: $OUT/.maot_source_digest"
