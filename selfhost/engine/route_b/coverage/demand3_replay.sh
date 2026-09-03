#!/usr/bin/env bash
# D-DEMAND-3 stage 1: re-run the D-PRODUCER-DEMAND-2 replay against TODAY's
# committed producer, into producer14/ so the D2 evidence is untouched.
#
# Identical inputs to replay13.sh: same pairs13 documents, same manifest13
# (constructor-retaining, policy p2), same release import kernels, same
# candidate-checkout discipline. The only variable is the CLI tree, and
# verify_supported_state.sh confirmed repo HEAD's packages/shorebird_cli tree
# equals the qualified revision's -- so this is expected to reproduce D2
# exactly, and a difference would be product drift worth stopping for.
#
# NO RESUME GUARD, deliberately. The first attempt at this script had
# `[ -f "$out" ] && continue`; a timeout killed it mid-pair, leaving a 0-byte
# output, and the next run skipped it as "done". An empty replay reports no
# refusals, so those observations would have been counted as producer-accepted
# and LocalSend's compatibility would have read too high. Every output here is
# written by a process that ran to completion, and the assertion at the end
# checks exactly that.
set -uo pipefail
CLI=/Users/mendell/shorebird/packages/shorebird_cli
for app in wonderous localsend; do
  W=/Volumes/build/route-b/demand1/$app
  WT=$W/wt
  PKGREL=.dart_tool/package_config.json
  rm -rf "$W/producer14"; mkdir -p "$W/producer14"
  for p in "$W"/pairs13/*.json; do
    n=$(basename "$p" .json); b=${n%%_*}; c=${n##*_}
    out="$W/producer14/$n.txt"
    python3 -c "import json,sys; sys.exit(0 if json.load(open('$p')).get('changed') else 1)" || continue
    man="$W/manifest13/$b.manifest.json"
    imp=$(ls "$W/import/$b"*.import.dill 2>/dev/null | head -1)
    [ -f "$man" ] || { echo "  $n: NO MANIFEST"; continue; }
    cand=$(grep "^$c" "$W/window.txt" | head -1)
    cgroup=$(awk -v s="$cand" '$1==s{print $2}' "$W/lockgroups.txt")
    git -C "$WT" checkout --quiet --force --detach "$cand" 2>/dev/null || { echo "  $n: CHECKOUT FAILED"; continue; }
    mkdir -p "$WT/$(dirname "$PKGREL")"
    cp "$W/pkgcfg/$cgroup/package_config.json" "$WT/$PKGREL" 2>/dev/null || true
    ( cd "$CLI" && timeout 1800 dart run tool/demand_replay_refusal.dart \
        "$p" --enumerate --manifest "$man" --release-import "$imp" ) \
        > "$out" 2>&1
    echo "  $app/$n: refusals = $(grep -c '^  REFUSE' "$out" 2>/dev/null || echo 0)"
  done
done
# COMPLETENESS ASSERTION. A replay that did not reach its final verdict line is
# not a measurement; treating one as "no refusals" is how a silent hole becomes
# a headline number.
bad=0
for f in /Volumes/build/route-b/demand1/*/producer14/*.txt; do
  grep -q 'admission passed for the remainder:' "$f" || { echo "INCOMPLETE: $f"; bad=1; }
done
[ "$bad" -eq 0 ] && echo "==> every replay reached a verdict" || echo "==> INCOMPLETE REPLAYS PRESENT"
