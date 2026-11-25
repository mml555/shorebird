#!/usr/bin/env bash
# publish_cell.sh -- OWNER-RUN, after stage_mint.sh --run and make_selector.sh --run. Order: selector
# branch and tag on the engine repo, cell release on the cell repo, ci-build install, cell manifest install.
#
#   MINT_ENV=<env file> bash publish_cell.sh          # PLAN: checks only (reads GitHub, writes nothing)
#   MINT_ENV=<env file> bash publish_cell.sh --run
#
# The env file needs SEL_CLONE (a clone of the engine repo that holds the selector branch) and CLI (the
# full sha on the cell repo whose tree names the cell: it holds cell_manifests/<A>.v2).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); . "$HERE/lib.sh"; load_env
RUN=0; case "${1:-}" in --run) RUN=1;; "") ;; *) die "usage: $0 [--run]";; esac
[[ -f $OUT/ADDRESS ]] || die "no $OUT/ADDRESS: run stage_mint.sh --run first"
A=$(cat "$OUT/ADDRESS"); hex40 address "$A"; D=$OUT/dist; ST=$OUT/ci-stage; A8=${A:0:8}
C=${SEL_CLONE:?set SEL_CLONE=<clone with the selector branch> in $MINT_ENV}
CLI=${CLI:?set CLI=<full sha on $CELL_REPO that names cell $A> in $MINT_ENV}; hex40 CLI "$CLI"
BR=$SELECTOR_BRANCH_PREFIX$A8; TAG=selfhost-flutter-cell-$A8
(cd "$D" && shasum -a 256 -c --quiet MANIFEST.sha256); (cd "$ST" && shasum -a 256 -c --quiet tar.sha); echo "bundles ok"
SEL=$(git -C "$C" rev-parse "refs/heads/$BR") || die "no branch $BR in $C (make_selector.sh --run)"
[[ "$(git -C "$C" diff --name-only "$SEL^" "$SEL")" == bin/internal/engine.version ]] || die "selector changes more than engine.version"
[[ "$(git -C "$C" rev-parse "$SEL^")" == "$E" ]] || die "selector's parent is not the engine commit $E"
[[ "$(git -C "$C" show "$SEL:bin/internal/engine.version")" == "$A" ]] || die "engine.version is not $A"
echo "selector $BR = $SEL, parent $E"
url=$(git -C "$C" remote get-url "$SELECTOR_REMOTE") || die "no remote $SELECTOR_REMOTE in $C"
[[ $url == *"$ENGINE_REPO"* ]] || die "remote $SELECTOR_REMOTE of $C is $url, not $ENGINE_REPO: nothing is pushed anywhere else"
gh api "repos/$CELL_REPO/commits/$CLI" -q .sha >/dev/null || die "$CLI is not on $CELL_REPO"
gh api "repos/$CELL_REPO/contents/selfhost/engine/route_b/cell_manifests/$A.v2?ref=$CLI" -q .sha >/dev/null \
  || die "$CLI has no selfhost/engine/route_b/cell_manifests/$A.v2 (it must name the cell)"
if gh release view "cell-$A8" -R "$CELL_REPO" >/dev/null 2>&1; then die "release cell-$A8 already exists on $CELL_REPO"; fi
if gh api "repos/$ENGINE_REPO/git/ref/tags/$TAG" >/dev/null 2>&1; then die "tag $TAG already exists on $ENGINE_REPO"; fi
[[ $RUN == 1 ]] || { echo "PLAN ONLY; --run publishes."; exit 0; }

# GitHub refuses release assets of 2 GiB or more: the release gets the tar in parts; ci-build still gets the whole tar.
P=$OUT/cell-parts; rm -rf "$P"; mkdir -p "$P"
split -b 1900m "$D/cell-$A.tar" "$P/cell-$A.tar.part-"
[[ "$(cat "$P"/cell-"$A".tar.part-* | shasum -a 256 | cut -d' ' -f1)" == "$(grep " cell-$A.tar\$" "$D/MANIFEST.sha256" | cut -d' ' -f1)" ]] || die "rejoined parts differ from the tar"
( cd "$P" && shasum -a 256 cell-"$A".tar.part-* > PARTS.sha256 && cat PARTS.sha256 )
git -C "$C" push --no-verify "$SELECTOR_REMOTE" "refs/heads/$BR"
git -C "$C" tag -a "$TAG" "$SEL" -m "Flutter SDK revision selecting cell $A8 ($CELL) over engine $E8. engine.version = $A."
git -C "$C" push --no-verify "$SELECTOR_REMOTE" "refs/tags/$TAG"
gh release create "cell-$A8" -R "$CELL_REPO" --target "$CLI" --latest=false --title "Cell $A8 - $CELL over engine $E8 (Flutter $FLUTTER_LINE)" \
  --notes "Cell $A over engine $E, fallback $FB (Shorebird $FB_BRANCH). Selector $SEL on $BR (tag $TAG). The tar is in parts (GitHub's 2 GiB asset limit): cat cell-$A.tar.part-* > cell-$A.tar, then shasum -a 256 -c MANIFEST.sha256. See cell_manifest.v2." \
  "$P/cell-$A.tar.part-"* "$P/PARTS.sha256" "$D/cell_manifest.v2" "$D/files.sha256" "$D/MANIFEST.sha256"
T=$CI_TMP/cell-$A8
{ echo "E=$E"; echo "FB=$FB"; echo "FLUTTER_LINE=$FLUTTER_LINE"; echo "CONTAINER=$CONTAINER"; echo "CI_CDN=$CI_CDN"; } > "$ST/remote.env"
ssh "$CI_HOST" "mkdir -p $T"
scp "$ST/cell-$A.tar" "$ST/files.sha256" "$ST/names" "$ST/tar.sha" "$ST/remote.env" "$HERE/install_on_ci.sh" "$HERE/cell_edits.py" "$CI_HOST:$T/"
ssh "$CI_HOST" "ADDR=$A bash $T/install_on_ci.sh cell --run" 2>&1 | tee "$OUT/install_cell.log"
bash "$HERE/install_manifest.sh" --run 2>&1 | tee -a "$OUT/install_cell.log"
