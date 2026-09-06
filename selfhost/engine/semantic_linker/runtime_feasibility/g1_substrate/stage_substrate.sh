#!/usr/bin/env bash
# cspell:words dartaotruntime clonefile depot gclient prebuilt nodm dill semantic linker
# stage_substrate.sh -- SEMANTIC-LINKER-1 / G1 step 1. Stand up an ISOLATED
# engine tree at the frozen lineage, and prove it IS the frozen lineage.
#
# WHY A SEPARATE TREE. /Volumes/build/route-b/flutter is the tree that produced
# the SUPPORTED cell; out/host_release_arm64 there holds the exact dartaotruntime
# and vm_platform.dill the cell ships. This lane must not build in it, must not
# re-gn it, and must not touch its out dirs. So the source is CLONED and every
# experiment happens in the clone.
#
# WHY IT IS ALMOST FREE. /Volumes/build is APFS, so `cp -c` uses clonefile:
# copy-on-write, no second copy of 18 GB of source, and it completes in seconds.
# Blocks diverge only where a build writes.
#
# WHY THE EXISTING out/host_release_arm64_nodm IS NOT THE CONTROL. It looks like
# one -- same tree, dynamic modules off -- and it is not a matched pair with the
# dm host ([[stamps-are-not-bytes]] is the habit; here the labels disagree too):
#
#     out/host_release_arm64       dart_version = 6b58bb3a72...   built 2026-08-12/20
#     out/host_release_arm64_nodm  dart_version = 9e8c898a4d...   built 2026-09-01
#
# Two settings differ, not one, and three weeks of tree movement sit between
# them. G1 needs OFF and ON to differ in exactly the experiment flag, so both are
# built here, from one staged source, in one session.
#
#   stage_substrate.sh [--force]
#
# Exit: 0 staged and verified · 1 verification failed · 2 environment error
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd -- "$HERE/../../../../.." >/dev/null 2>&1 && pwd)"
FREEZE="$REPO/selfhost/engine/semantic_linker/runtime_feasibility/g0_freeze/freeze_manifest.json"

SRC_ENGINE=${SRC_ENGINE:-/Volumes/build/route-b/flutter}
LANE=${LANE:-/Volumes/build/semantic-linker/sl1}
DEST="$LANE/flutter"

# Read the frozen identities from G0's manifest rather than restating them, so
# the two gates cannot drift apart silently.
[[ -f "$FREEZE" ]] || { echo "no G0 freeze manifest at $FREEZE — run g0_freeze/freeze.sh --emit" >&2; exit 2; }
jq_() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));
import functools
v=d
for k in sys.argv[2].split('.'): v=v[k]
print(v)" "$FREEZE" "$1"; }
WANT_ENGINE_REV=$(jq_ producing_source.engine.revision)
WANT_ENGINE_TREE=$(jq_ producing_source.engine.tree)
WANT_DART_REV=$(jq_ producing_source.dart.revision)
WANT_DART_HEAD_TREE=$(jq_ producing_source.dart.head_tree)
WANT_DART_EFF_TREE=$(jq_ producing_source.dart.effective_tree)
DIRTY_FILE=$(python3 -c "import json;print(json.load(open('$FREEZE'))['producing_source']['dart']['dirty_paths'][0])")

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

fails=0
ok()  { printf '  ok      %s\n' "$*"; }
bad() { printf '  FAILED  %s\n' "$*"; fails=$((fails+1)); }
cmp_v(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1: expected $2, got ${3:-<none>}"; fi; }

echo "stage_substrate -- SEMANTIC-LINKER-1 G1"
echo "  source : $SRC_ENGINE"
echo "  lane   : $DEST"

[[ -d "$SRC_ENGINE/engine/src" ]] || { echo "no engine source at $SRC_ENGINE" >&2; exit 2; }

# THE PRODUCER TREE MUST BE THE FROZEN ONE BEFORE ANYTHING IS COPIED. Cloning
# first and checking after would bake whatever the disk happened to hold into
# the lane and then report on the copy, which proves nothing about the baseline.
SD="$SRC_ENGINE/engine/src/flutter/third_party/dart"
cmp_v "producer engine HEAD is the frozen revision" "$WANT_ENGINE_REV" "$(git -C "$SRC_ENGINE" rev-parse HEAD 2>/dev/null)"
cmp_v "producer engine tree is the frozen tree"     "$WANT_ENGINE_TREE" "$(git -C "$SRC_ENGINE" rev-parse 'HEAD^{tree}' 2>/dev/null)"
cmp_v "producer Dart HEAD is the frozen revision"   "$WANT_DART_REV"    "$(git -C "$SD" rev-parse HEAD 2>/dev/null)"
eff_tree() { # <repo> — HEAD plus the one known-dirty file, via a scratch index
  local repo=$1 idx; idx=$(mktemp)
  GIT_INDEX_FILE=$idx git -C "$repo" read-tree HEAD 2>/dev/null
  GIT_INDEX_FILE=$idx git -C "$repo" add -- "$DIRTY_FILE" 2>/dev/null
  GIT_INDEX_FILE=$idx git -C "$repo" write-tree 2>/dev/null
  rm -f "$idx"
}
cmp_v "producer Dart EFFECTIVE tree (HEAD + the uncommitted guard)" "$WANT_DART_EFF_TREE" "$(eff_tree "$SD")"
[[ "$fails" -eq 0 ]] || { echo; echo "REFUSING TO STAGE: the producer tree is not the frozen lineage"; exit 1; }

# ---------------------------------------------------------------------- clone
CLONED=0
if [[ -d "$DEST" && "$FORCE" == 0 ]]; then
  ok "lane tree already staged (pass --force to re-clone)"
else
  CLONED=1
  [[ "$FORCE" == 1 ]] && rm -rf "$DEST"
  mkdir -p "$DEST/engine"
  echo "  cloning source (APFS clonefile; out/ excluded)..."
  # Everything at the top level except engine/, then engine/src minus out/.
  for e in "$SRC_ENGINE"/* "$SRC_ENGINE"/.[!.]*; do
    [[ -e "$e" ]] || continue
    [[ "$(basename "$e")" == engine ]] && continue
    cp -Rc "$e" "$DEST/" 2>/dev/null || cp -R "$e" "$DEST/"
  done
  for e in "$SRC_ENGINE"/engine/src/* "$SRC_ENGINE"/engine/src/.[!.]*; do
    [[ -e "$e" ]] || continue
    [[ "$(basename "$e")" == out ]] && continue
    mkdir -p "$DEST/engine/src"
    cp -Rc "$e" "$DEST/engine/src/" 2>/dev/null || cp -R "$e" "$DEST/engine/src/"
  done
  ok "cloned"
fi

# ------------------------------------------------------- prove the copy is it
DD="$DEST/engine/src/flutter/third_party/dart"
cmp_v "lane engine HEAD"            "$WANT_ENGINE_REV"    "$(git -C "$DEST" rev-parse HEAD 2>/dev/null)"
cmp_v "lane engine tree"            "$WANT_ENGINE_TREE"   "$(git -C "$DEST" rev-parse 'HEAD^{tree}' 2>/dev/null)"
cmp_v "lane Dart HEAD"              "$WANT_DART_REV"      "$(git -C "$DD" rev-parse HEAD 2>/dev/null)"
cmp_v "lane Dart committed tree"    "$WANT_DART_HEAD_TREE" "$(git -C "$DD" rev-parse 'HEAD^{tree}' 2>/dev/null)"
cmp_v "lane Dart EFFECTIVE tree"    "$WANT_DART_EFF_TREE" "$(eff_tree "$DD")"
# THIS ASSERTION BELONGS TO A FRESH CLONE ONLY. Once the lane has been built in,
# out/ is supposed to exist, and asserting its absence on a re-verify turned a
# correctly-staged tree into a failure.
if [[ "$CLONED" == 1 ]]; then
  [[ -d "$DEST/engine/src/out" ]] && bad "the clone carries an out/ dir; it must start with none" \
                                  || ok "no inherited out/ — both configurations will be built here from scratch"
else
  ok "re-verified an already-staged tree (out/ is expected to exist and is not asserted against)"
fi

# THE SUPPORTED TREE MUST BE UNCHANGED BY ALL OF THE ABOVE.
cmp_v "producer engine STILL at the frozen tree (untouched by staging)" \
  "$WANT_ENGINE_TREE" "$(git -C "$SRC_ENGINE" rev-parse 'HEAD^{tree}' 2>/dev/null)"
cmp_v "producer Dart STILL at the frozen effective tree" "$WANT_DART_EFF_TREE" "$(eff_tree "$SD")"
[[ -d "$SRC_ENGINE/engine/src/out/host_release_arm64" ]] \
  && ok "producer out/host_release_arm64 still present (the cell's own bytes)" \
  || bad "producer out/host_release_arm64 has gone missing"

echo
if [[ "$fails" -eq 0 ]]; then echo "SUBSTRATE STAGED AND VERIFIED"; else echo "STAGING FAILED: $fails check(s)"; fi
exit $(( fails > 0 ))
