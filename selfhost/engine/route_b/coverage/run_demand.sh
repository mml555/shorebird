#!/usr/bin/env bash
# cspell:words dartaotruntime wonderous localsend dill pubspec
#
# run_demand.sh -- D-DEMAND-1. Walks a project's real history and asks the
# SHIPPING analyzer whether Route B could carry each real change.
#
# DEPENDENCIES ARE RESOLVED PER LOCKFILE GROUP, not once for the whole window.
# Compiling every commit against one frozen resolution was MEASURED to fail on
# the older half of a 40-commit Wonderous window -- the app had been migrated to
# a new package API, so older sources cannot compile against newer packages. See
# the SUPERSEDED section of D_DEMAND_1_PRECOMMIT.md.
#
# Commits are grouped into contiguous runs sharing one committed pubspec.lock.
# Each group is resolved once. Inside a group the developers' own lockfile did
# not move, so release and candidate share a resolution -- what a real patch
# faces, since a Route B patch cannot change dependencies. A pair STRADDLING a
# boundary is recorded as `pair.dependency_change`: a real refusal, reported,
# never silently dropped.
#
# One kernel per commit: on a contiguous chain each commit is the candidate for
# one pair and the release for the next.
set -uo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
DART=$OUT/dart-sdk/bin/dart
GEN_KERNEL=$SRC/flutter/third_party/dart/pkg/vm/bin/gen_kernel.dart
PLATFORM=$OUT/flutter_patched_sdk/platform_strong.dill
AOT=$OUT/dartaotruntime
ANALYZER=${ANALYZER:-$OUT/zip_archives/route_b_analyze.aot}
# The frozen Flutter SDK, used ONLY via its bundled dart. Never the `flutter`
# tool, which can rebuild snapshots inside ~/.shorebird.
FSDK=${FSDK:-/Users/mendell/.shorebird/bin/cache/flutter/c15ef6379403a0a55531a058bdb2c8e55bc05c98}

REPO=${REPO:?REPO=<frozen checkout>}
PIN=${PIN:?PIN=<frozen revision>}
ENTRY=${ENTRY:?ENTRY=<package uri>}
APPSUB=${APPSUB:-.}
LOCKPATH=${LOCKPATH:-pubspec.lock}     # repo-relative, for grouping
PUBDIR=${PUBDIR:-.}                    # where `pub get` runs, worktree-relative
PKGARG=${PKGARG:-.dart_tool/package_config.json}   # as gen_kernel sees it, from APPSUB
PKGREL=${PKGREL:-.dart_tool/package_config.json}   # repo-relative location produced by pub
K=${K:-40}
WORK=${WORK:?WORK=<output dir>}
INCLUDES=${INCLUDES:?INCLUDES=<space separated library prefixes>}

die() { echo "ERROR: $*" >&2; exit 1; }

[ -x "$DART" ] || die "no host dart at $DART"
[ -f "$ANALYZER" ] || die "no analyzer at $ANALYZER"
[ -x "$FSDK/bin/cache/dart-sdk/bin/dart" ] || die "no frozen SDK dart under $FSDK"
mkdir -p "$WORK/dills" "$WORK/census" "$WORK/pairs" "$WORK/logs"

inc_args=()
for p in $INCLUDES; do inc_args+=(--include "$p"); done

COMMITS=()
while IFS= read -r line; do COMMITS+=("$line"); done < <(
  git -C "$REPO" rev-list --first-parent -n "$K" "$PIN" | tail -r)
NC=${#COMMITS[@]}
LAST=$(( NC - 1 ))
echo "==> window: $NC commits, oldest ${COMMITS[0]:0:8} .. newest ${COMMITS[$LAST]:0:8}"
printf '%s\n' "${COMMITS[@]}" > "$WORK/window.txt"

# Lockfile identity per commit -> contiguous groups.
: > "$WORK/lockgroups.txt"
for sha in "${COMMITS[@]}"; do
  h=$(git -C "$REPO" show "$sha:$LOCKPATH" 2>/dev/null | shasum -a 256 | cut -c1-12)
  [ -z "$h" ] && h=NO_LOCK
  echo "$sha $h" >> "$WORK/lockgroups.txt"
done
echo "==> lock states: $(awk '{print $2}' "$WORK/lockgroups.txt" | sort -u | wc -l | tr -d ' ')"

WT=$WORK/wt
git -C "$REPO" worktree prune >/dev/null 2>&1
if [ ! -d "$WT" ]; then
  git -C "$REPO" worktree add --detach "$WT" "$PIN" >/dev/null 2>&1
  [ -d "$WT" ] || die "could not create worktree at $WT"
fi

built=0; failed=0; resolved=0
: > "$WORK/build_failures.txt"
: > "$WORK/resolve_failures.txt"

prev_group=""
for sha in "${COMMITS[@]}"; do
  group=$(awk -v s="$sha" '$1==s{print $2}' "$WORK/lockgroups.txt")
  dill=$WORK/dills/$sha.dill
  [ -f "$dill" ] && { built=$((built+1)); prev_group=$group; continue; }

  git -C "$WT" checkout --quiet --force --detach "$sha" 2>/dev/null || {
    echo "$sha checkout_failed" >> "$WORK/build_failures.txt"
    failed=$((failed+1)); prev_group=$group; continue; }

  cache=$WORK/pkgcfg/$group
  if [ ! -f "$cache/package_config.json" ]; then
    # First commit of a new lockfile group: resolve once, here.
    ( cd "$WT/$PUBDIR" && FLUTTER_ROOT="$FSDK" timeout 900 \
        "$FSDK/bin/cache/dart-sdk/bin/dart" pub get --no-precompile ) \
        > "$WORK/logs/$group.pubget.log" 2>&1
    if [ -f "$WT/$PKGREL" ]; then
      mkdir -p "$cache"; cp "$WT/$PKGREL" "$cache/package_config.json"
      resolved=$((resolved+1))
      echo "  group $group resolved at ${sha:0:8}"
    else
      echo "$group $sha pub_get_failed" >> "$WORK/resolve_failures.txt"
      echo "$sha resolve_failed" >> "$WORK/build_failures.txt"
      failed=$((failed+1)); prev_group=$group; continue
    fi
  else
    mkdir -p "$(dirname "$WT/$PKGREL")"; cp "$cache/package_config.json" "$WT/$PKGREL"
  fi

  ( cd "$WT/$APPSUB" && timeout 1200 "$DART" "$GEN_KERNEL" --platform "$PLATFORM" \
      --target flutter --aot --tfa --packages "$PKGARG" -o "$dill" "$ENTRY" ) \
      > "$WORK/logs/$sha.kernel.log" 2>&1
  if [ -f "$dill" ]; then
    built=$((built+1))
    timeout 900 "$AOT" "$ANALYZER" --census --dill "$dill" "${inc_args[@]}" \
      --out "$WORK/census/$sha.jsonl" > "$WORK/logs/$sha.census.log" 2>&1
    printf '  %s built [%s]\n' "${sha:0:8}" "$group"
  else
    failed=$((failed+1)); rm -f "$dill"
    echo "$sha kernel_failed" >> "$WORK/build_failures.txt"
    printf '  %s KERNEL FAILED: %s\n' "${sha:0:8}" \
      "$(head -1 "$WORK/logs/$sha.kernel.log" | cut -c1-90)"
  fi
  prev_group=$group
done

echo "==> resolutions: $resolved   kernels: $built built, $failed failed"

pairs=0; cross=0
: > "$WORK/cross_group_pairs.txt"
for ((i=0; i<NC-1; i++)); do
  base=${COMMITS[$i]}; cand=${COMMITS[$((i+1))]}
  gb=$(awk -v s="$base" '$1==s{print $2}' "$WORK/lockgroups.txt")
  gc=$(awk -v s="$cand" '$1==s{print $2}' "$WORK/lockgroups.txt")
  if [ "$gb" != "$gc" ]; then
    echo "$base $cand $gb $gc" >> "$WORK/cross_group_pairs.txt"
    cross=$((cross+1)); continue
  fi
  bd=$WORK/dills/$base.dill; cdl=$WORK/dills/$cand.dill
  [ -f "$bd" ] && [ -f "$cdl" ] || continue
  timeout 900 "$AOT" "$ANALYZER" --base-dill "$bd" --patched-dill "$cdl" \
    "${inc_args[@]}" --out "$WORK/pairs/${base:0:8}_${cand:0:8}.json" \
    > "$WORK/logs/pair_${base:0:8}_${cand:0:8}.log" 2>&1 \
    && pairs=$((pairs+1))
done
echo "==> pairs analysed: $pairs   cross-lockfile pairs (dependency_change): $cross"
echo "==> work dir: $WORK"
