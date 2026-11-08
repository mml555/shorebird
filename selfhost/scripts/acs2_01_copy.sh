#!/usr/bin/env bash
# cspell:words armv gclient prebuilt ninja depot cipd openjdk ddm
# ANDROID-CELL-SUPPLY-2 gate 1, step 1: a NEW checkout at the exact engine
# source, made by COPYING rather than re-cloning.
#
# Why a copy: it guarantees the source bytes are identical to the tree that
# produced the qualified cell — a fresh `gclient sync` could resolve a floating
# DEPS entry differently and quietly change the lineage. And it does not mutate
# the original, which is the constraint that matters.
#
# `out/` is excluded (51 GB of build products); this lane builds fresh.
set -uo pipefail
SRC=/Volumes/build/route-b/flutter
DST=/Volumes/build/route-b/acs2/flutter
mkdir -p "$DST"
rsync -a --exclude 'engine/src/out/' "$SRC/" "$DST/"
echo "rsync exit=$?"
echo "copied: $(du -sh "$DST" | cut -f1)"
echo "engine revision: $(git -C "$DST/engine/src/flutter" rev-parse HEAD 2>/dev/null || git -C "$DST" rev-parse HEAD)"
echo "=== done $(date -u +%FT%TZ) ==="
