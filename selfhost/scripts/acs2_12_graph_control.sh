#!/usr/bin/env bash
# cspell:words ninja depot armv graphctl
# GRAPH-LEVEL non-impact control for arm64, immune to LTO nondeterminism.
#
# The byte-comparison attempt was invalid: copying an out dir and rewriting
# engine_version yields an inconsistent partial rebuild (78% of libflutter.so
# differed, which is not a stamp), and enable_lto=true makes byte-identity
# unreliable as evidence anyway.
#
# What IS decidable: the BUILD GRAPH. Same git HEAD, so engine_version is
# constant; only lib/snapshot/BUILD.gn differs between the two runs. If the
# arm64 target lists are identical, the applicability gate changed nothing for
# arm64 — by evaluation, not by argument.
set -uo pipefail
B=/Volumes/build/route-b/acs2
SRC=$B/flutter/engine/src
export PATH=/Volumes/build/ios-engine/depot_tools:$PATH
export GIT_CONFIG_GLOBAL=/Volumes/build/ios-engine/gitconfig
export DEPOT_TOOLS_UPDATE=0
cd "$SRC" || exit 1
G=out/graphctl_arm64
echo "=== started $(date -u +%FT%TZ) HEAD=$(git -C flutter rev-parse HEAD) ==="
gen_graph() { # <label>
  rm -rf "$G"
  ./flutter/third_party/gn/gn gen "$G" --args="$(cat out/android_release_arm64/args.gn | tr '\n' ' ')" >/dev/null 2>&1
  ninja -C "$G" -t targets all 2>/dev/null | sort > "/tmp/graph_$1.txt"
  echo "  $1: $(wc -l < /tmp/graph_$1.txt | tr -d ' ') targets"
}
echo "--- with the PATCHED BUILD.gn ---"; gen_graph patched
echo "--- with the PARENT's BUILD.gn (only that one file reverted) ---"
git -C flutter checkout dfa2b24ac38477f3705ff0357530f33fe09474b8 -- lib/snapshot/BUILD.gn
gen_graph parent
git -C flutter checkout HEAD -- lib/snapshot/BUILD.gn
echo "  BUILD.gn restored: $(git -C flutter status --porcelain -- lib/snapshot/BUILD.gn | wc -l | tr -d ' ') modifications"
echo "=== arm64 graph diff ==="
if diff -q /tmp/graph_parent.txt /tmp/graph_patched.txt >/dev/null 2>&1; then
  echo "  IDENTICAL — the gate changed nothing in arm64's build graph"
else
  echo "  DIFFERS:"; diff /tmp/graph_parent.txt /tmp/graph_patched.txt | head -20
fi
rm -rf "$G"
echo "=== done $(date -u +%FT%TZ) ==="
