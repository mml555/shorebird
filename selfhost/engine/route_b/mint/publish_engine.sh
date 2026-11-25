#!/usr/bin/env bash
# publish_engine.sh -- merge the Mac and Linux halves of engine E into one overlay tar, release it on the
# engine repo, and install it into ci-build's mirror.
#
#   bash publish_engine.sh                 # PLAN: local checks only. No network.
#   bash publish_engine.sh --pull-linux    # OWNER: ssh + rsync the Linux half from ci-build (read-only on ci-build)
#   bash publish_engine.sh --build         # local: merge, add the extras and PROVENANCE.txt, write the tar in $OUT/engine.
#                                          #   Reads GitHub (commit exists), publishes nothing.
#   bash publish_engine.sh --run           # OWNER: gh release create, scp, ssh install_on_ci.sh engine --run
#
# MINT_ENV=<env file> is required. --run refuses unless --build made $OUT/engine and its sums verify.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); . "$HERE/lib.sh"; load_env; resolve_helpers
MODE=plan; case "${1:-}" in --pull-linux) MODE=pull;; --build) MODE=build;; --run) MODE=run;; "") ;; *) die "usage: $0 [--pull-linux|--build|--run]";; esac
X=$ENGINE_EXTRA/download.shorebird.dev/shorebird/$E
EXTRAS=(analyze-snapshot-macos-arm64 analyze-snapshot-macos-x64 artifacts_manifest.yaml patch-darwin-arm64.zip patch-darwin-x64.zip patch-linux-x64.zip route-b-compiler-darwin-arm64.zip)

if [[ $MODE == pull ]]; then
  say "pull the Linux half from $CI_HOST:$LINUX_STAGE_REMOTE"
  ssh "$CI_HOST" "cd $LINUX_STAGE_REMOTE && sha256sum -c --quiet SHA256SUMS && echo \"Linux: \$(wc -l < SHA256SUMS) files ok on $CI_HOST\""
  mkdir -p "$LINUX_HALF"
  rsync -a "$CI_HOST:$LINUX_STAGE_REMOTE/" "$LINUX_HALF/"
  ( cd "$LINUX_HALF" && shasum -a 256 -c --quiet SHA256SUMS && echo "Linux half: $(wc -l < SHA256SUMS) files ok in $LINUX_HALF" )
  exit 0
fi

say "verify Mac half in $MAC_STAGE"
[[ -f $MAC_STAGE/SHA256SUMS ]] || die "no $MAC_STAGE/SHA256SUMS: run build_engine_mac.sh --run first"
( cd "$MAC_STAGE" && shasum -a 256 -c --quiet SHA256SUMS && echo "Mac: $(wc -l < SHA256SUMS) files ok" )
say "Linux half in $LINUX_HALF"
[[ -f $LINUX_HALF/SHA256SUMS ]] || die "no $LINUX_HALF/SHA256SUMS: run $0 --pull-linux (owner) after the Linux build"
( cd "$LINUX_HALF" && shasum -a 256 -c --quiet SHA256SUMS && echo "Linux: $(wc -l < SHA256SUMS) files ok" )
for f in "${EXTRAS[@]}"; do [[ -f "$X/$f" ]] || die "missing $X/$f (prepare_inputs.sh and build_compiler.sh make the extras)"; done
echo "extras: $(find "$X" -type f | wc -l | tr -d ' ') files ok"
[[ -f "$MINT_DIR/engine-PROVENANCE.head.tmpl" ]] || die "missing engine-PROVENANCE.head.tmpl"
[[ $MODE != plan ]] || { echo "PLAN ONLY. --build makes the tar locally; --run publishes it."; exit 0; }

if [[ $MODE == run ]]; then
  [[ -f "$OUT/engine/BUILT" ]] || die "no build in $OUT/engine. Run --build first."
  ( cd "$OUT/engine" && shasum -a 256 -c --quiet SHA256SUMS ) || die "$OUT/engine/SHA256SUMS does not verify"
  echo "publishing the build of $(cat "$OUT/engine/BUILT")"
  [[ "$(cat "$OUT/engine/BUILT.engine")" == "$E" ]] || die "$OUT/engine was built for $(cat "$OUT/engine/BUILT.engine"), not $E"
  if gh release view "engine-$E" -R "$ENGINE_REPO" >/dev/null 2>&1; then die "release engine-$E already exists on $ENGINE_REPO"; fi
else
  gh api "repos/$ENGINE_REPO/commits/$E" -q .sha >/dev/null || die "$E is not on $ENGINE_REPO. Push $ENGINE_BRANCH first (and Dart $DART to its fork)."
  rm -rf "$OUT/engine"; mkdir -p "$OUT/engine/merged"
  say "merge (a path present in both halves must be byte-identical)"
  cp -Rp "$MAC_STAGE/." "$OUT/engine/merged/"; rm -f "$OUT/engine/merged/SHA256SUMS"
  ( cd "$LINUX_HALF" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort ) | while read -r p; do
    if [[ -e "$OUT/engine/merged/$p" ]]; then cmp -s "$OUT/engine/merged/$p" "$LINUX_HALF/$p" || die "CONFLICT $p"
    else mkdir -p "$OUT/engine/merged/$(dirname "$p")"; cp -p "$LINUX_HALF/$p" "$OUT/engine/merged/$p"; fi
  done
  say "add download.shorebird.dev/shorebird/$E (the Mac build staged the analyze snapshots under a bare shorebird/)"
  if [[ -d "$OUT/engine/merged/shorebird/$E" ]]; then
    for f in "$OUT/engine/merged/shorebird/$E/"*; do cmp -s "$f" "$X/$(basename "$f")" || die "CONFLICT $f vs $X"; done
  fi
  rm -rf "$OUT/engine/merged/shorebird"
  cp -Rp "$ENGINE_EXTRA/." "$OUT/engine/merged/"
  cd "$OUT/engine/merged"
  [[ -z "$(find . -name '._*' -print -quit)" ]] || die "AppleDouble (._*) files in the merged overlay"
  st=$(find . -name engine_stamp.json | head -1); [[ -n "$st" ]] || die "no engine_stamp.json in the merged overlay"
  P="download.shorebird.dev/shorebird/$E/PROVENANCE.txt"
  UPDATER_REV=${UPDATER_REV:-$( (git -C "${MAC_TREE:-/nonexistent}" show "$E:DEPS" 2>/dev/null || true) | sed -nE 's/.*"updater_rev": "([0-9a-f]{8})[0-9a-f]*".*/\1/p' | head -1)}
  UPDATER_REV=${UPDATER_REV:-unknown}
  FLUTTER_ENGINE_REVISION=$(sed -nE 's/^flutter_engine_revision: *([0-9a-f]{40}).*/\1/p' "$X/artifacts_manifest.yaml" | head -1)
  [[ -n $FLUTTER_ENGINE_REVISION ]] || die "no flutter_engine_revision in $X/artifacts_manifest.yaml"
  MAC_OS="macOS $(sw_vers -productVersion) $(uname -m)"; XCODE=$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'); XCODE=${XCODE:-Xcode unknown}
  PATCH_SOURCE=${PATCH_SOURCE:-${PATCH_SOURCE_TAR:+$(basename "$PATCH_SOURCE_TAR")}}; PATCH_SOURCE=${PATCH_SOURCE:-the previous cell}
  export UPDATER_REV FLUTTER_ENGINE_REVISION MAC_OS XCODE HELPERS_SHA PATCH_SOURCE
  { render_tmpl "$MINT_DIR/engine-PROVENANCE.head.tmpl"; echo "published_at:             $(date -u +%Y-%m-%dT%H:%M:%SZ) (overlay built)"
    echo "files (sha256):"; find . -type f ! -path "./$P" | sed 's#^\./##' | LC_ALL=C sort | xargs -I{} shasum -a 256 "{}" | sed 's/^/  /'; } > "$P"
  find . -type f | sed 's#^\./##' | LC_ALL=C sort > "$OUT/engine/overlay-$E.txt"
  COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -cf "$OUT/engine/overlay-$E.tar" -T "$OUT/engine/overlay-$E.txt"
  python3 -I - "$OUT/engine/overlay-$E.tar" <<'PY'
import sys, tarfile
names = [m.name for m in tarfile.open(sys.argv[1])]
bad = [n for n in names if not n.startswith(('flutter_infra_release/', 'download.flutter.io/', 'download.shorebird.dev/'))]
assert not bad, f"unexpected top-level paths: {bad[:5]}"
assert not any(n.split('/')[-1].startswith('._') for n in names), "AppleDouble entry"
PY
  printf '%s %s\n' "$E" "$FB" > "$OUT/engine/experimental_hashes-$E.map"
  cp "$st" "$OUT/engine/engine_stamp-$E.json"
  cp "$MINT_DIR/install_on_ci.sh" "$MINT_DIR/cell_edits.py" "$OUT/engine/"
  ( cd "$OUT/engine" && shasum -a 256 "overlay-$E.tar" "overlay-$E.txt" "experimental_hashes-$E.map" "engine_stamp-$E.json" > SHA256SUMS && cat SHA256SUMS )
  echo "$E" > "$OUT/engine/BUILT.engine"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$OUT/engine/BUILT"; echo "BUILT $(wc -l < "$OUT/engine/overlay-$E.txt" | tr -d ' ') files in $OUT/engine/overlay-$E.tar"
fi
[[ $MODE == run ]] || exit 0

say "split the tar for the release (GitHub refuses assets of 2 GiB or more); ci-build still gets the whole tar"
rm -rf "$OUT/engine/parts"; mkdir "$OUT/engine/parts"
split -b 1900m "$OUT/engine/overlay-$E.tar" "$OUT/engine/parts/overlay-$E.tar.part-"
( cd "$OUT/engine/parts" && [[ "$(cat overlay-"$E".tar.part-* | shasum -a 256 | cut -d' ' -f1)" == "$(grep " overlay-$E.tar\$" ../SHA256SUMS | cut -d' ' -f1)" ]] ) || die "rejoined parts differ from the tar"
( cd "$OUT/engine/parts" && shasum -a 256 overlay-"$E".tar.part-* > PARTS.sha256 && cat PARTS.sha256 )
say "release engine-$E on $ENGINE_REPO"
gh release create "engine-$E" -R "$ENGINE_REPO" --target "$E" --latest=false --title "Engine $E8 (Flutter $FLUTTER_LINE) overlay" \
  --notes "Overlay for engine $E: Mac and Linux halves merged. The tar is in parts (GitHub's 2 GiB asset limit): cat overlay-$E.tar.part-* > overlay-$E.tar, then shasum -a 256 -c SHA256SUMS. Install on a mirror with install_on_ci.sh engine; map line fallback $FB (Shorebird $FB_BRANCH). Built on macOS (darwin half) and ci-build (linux half); see download.shorebird.dev/shorebird/$E/PROVENANCE.txt in the tar." \
  "$OUT/engine/parts/overlay-$E.tar.part-"* "$OUT/engine/parts/PARTS.sha256" "$OUT/engine/overlay-$E.txt" "$OUT/engine/experimental_hashes-$E.map" "$OUT/engine/engine_stamp-$E.json" "$OUT/engine/SHA256SUMS"
say "ci-build install"
T=$CI_TMP/engine-$E8
{ echo "E=$E"; echo "FB=$FB"; echo "FLUTTER_LINE=$FLUTTER_LINE"; echo "CONTAINER=$CONTAINER"; echo "CI_CDN=$CI_CDN"; [[ -z ${PREV:-} ]] || echo "PREV=$PREV"; } > "$OUT/engine/remote.env"
ssh "$CI_HOST" "mkdir -p $T"
scp "$OUT/engine/"{overlay-"$E".tar,overlay-"$E".txt,experimental_hashes-"$E".map,engine_stamp-"$E".json,SHA256SUMS,remote.env,install_on_ci.sh,cell_edits.py} "$CI_HOST:$T/"
ssh "$CI_HOST" "bash $T/install_on_ci.sh engine --run" 2>&1 | tee "$OUT/install_engine.log"
