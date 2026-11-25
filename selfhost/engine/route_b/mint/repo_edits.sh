#!/usr/bin/env bash
# repo_edits.sh -- the edits a new engine and cell need in a checkout of this repo (use a fresh worktree
# off main). Local files only: it commits and pushes nothing. Open the PR yourself.
#
#   MINT_ENV=<env file> bash repo_edits.sh --worktree <dir>          # PLAN
#   MINT_ENV=<env file> bash repo_edits.sh --worktree <dir> --run
#
# What it changes in <dir>:
#   selfhost/cdn/Caddyfile                     E and A appended to the four protection groups
#   selfhost/cdn/check_protection_matchers.py  E and A appended to its three lists
#   selfhost/cdn/experimental_hashes.map       "E FB" and "A FB"
#   packages/shorebird_cli/lib/src/dart_sdk_compatibility.dart   E8 and A8 -> Dart 8 hex
#   bin/internal/flutter.version               the selector commit SEL
#   selfhost/engine/route_b/cell_manifests/<A>.v2   $OUT/dist/cell_manifest.v2
# PREV (the hash each group ends with now) is PREV from the env file, or is read from <dir>'s Caddyfile.
# It refuses when the groups disagree. It does not touch the two prose comments in the Caddyfile that list
# short hashes; add E8 and A8 there by hand.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); . "$HERE/lib.sh"; load_env
RUN=0; WT=""
while (($#)); do case "$1" in --run) RUN=1; shift;; --worktree) WT=${2:-}; shift 2;; *) die "usage: $0 --worktree <dir> [--run]";; esac; done
[[ -n $WT && -d $WT ]] || die "--worktree <dir> is required"
git -C "$WT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$WT is not a git work tree"
[[ -f $OUT/ADDRESS ]] || die "no $OUT/ADDRESS: run stage_mint.sh --run first"
A=$(cat "$OUT/ADDRESS"); hex40 address "$A"; A8=${A:0:8}
C=${SEL_CLONE:?set SEL_CLONE in $MINT_ENV}; BR=$SELECTOR_BRANCH_PREFIX${A:0:8}
SEL=$(git -C "$C" rev-parse --verify "refs/heads/$BR") || die "no selector branch $BR in $C: run make_selector.sh --run"
CDN=$WT/selfhost/cdn
PREV=${PREV:-$(prev_from_caddyfile "$CDN/Caddyfile")}
say "engine $E, cell $A, selector $SEL, previous hash $PREV"
[[ -z $(git -C "$WT" status --porcelain --untracked-files=no) ]] || die "$WT has uncommitted changes"
# Check everything first, write second: the dry runs and the checks below stop before any file changes,
# so a refusal never leaves a half-edited worktree.
CM=$WT/selfhost/engine/route_b/cell_manifests/$A.v2
if [[ -e $CM ]]; then cmp -s "$CM" "$OUT/dist/cell_manifest.v2" || die "$CM exists with other bytes"; fi
[[ -f $OUT/dist/cell_manifest.v2 ]] || die "no $OUT/dist/cell_manifest.v2 (stage_mint.sh --run)"
[[ -f $WT/bin/internal/flutter.version ]] || die "no bin/internal/flutter.version in $WT"
M=$CDN/experimental_hashes.map
PROT=("$E=engine $E8 (Flutter $FLUTTER_LINE, Dart ${DART:0:8}, built on Shorebird $FB_BRANCH)" "$A=minted cell over $E8's bytes (Flutter $FLUTTER_LINE, Route B iOS)")
DC=("$E=Flutter $FLUTTER_LINE engine $E8 and the cell $A8 minted over it (Dart ${DART:0:8}). selfhost/cdn/experimental_hashes.map." "$A=")
python3 -I "$HERE/cell_edits.py" protect "$CDN" "$PREV" "${PROT[@]}" --dry-run
python3 -I "$HERE/cell_edits.py" dart-compat "$WT/packages/shorebird_cli/lib/src/dart_sdk_compatibility.dart" "$DART" "${DC[@]}" --dry-run
for h in "$E" "$A"; do if grep -q "^$h " "$M"; then echo "map has $h"; else echo "map: $h $FB"; fi; done
echo "flutter.version: $(cat "$WT/bin/internal/flutter.version") -> $SEL"
if [[ -e $CM ]]; then echo "cell manifest already in place"; else echo "cell manifest: -> $CM"; fi
if [[ $RUN == 1 ]]; then
  python3 -I "$HERE/cell_edits.py" protect "$CDN" "$PREV" "${PROT[@]}"
  python3 -I "$HERE/cell_edits.py" dart-compat "$WT/packages/shorebird_cli/lib/src/dart_sdk_compatibility.dart" "$DART" "${DC[@]}"
  [[ ! -s $M || -z "$(tail -c1 "$M")" ]] || echo >> "$M"
  for h in "$E" "$A"; do
    grep -q "^$h " "$M" && continue
    [[ $h == "$E" ]] && printf '# Engine %s (Flutter %s) and its cell %s.\n' "$E8" "$FLUTTER_LINE" "$A8" >> "$M"
    printf '%s %s\n' "$h" "$FB" >> "$M"
  done
  printf '%s\n' "$SEL" > "$WT/bin/internal/flutter.version"
  [[ -e $CM ]] || cp "$OUT/dist/cell_manifest.v2" "$CM"
  python3 -I "$CDN/check_protection_matchers.py" | tail -1
  echo "DONE. By hand: add ${E:0:8} and ${A:0:8} to the two short-hash comments in selfhost/cdn/Caddyfile."
  echo "Then run the touched CLI test: cd packages/shorebird_cli && dart test test/src/dart_sdk_compatibility_test.dart"
else echo "PLAN ONLY. Add --run."; fi
