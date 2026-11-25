#!/usr/bin/env bash
# repack.sh -- OWNER-RUN. Repackage release cell-<A8> (A = $OUT/ADDRESS) in the shape that
# selfhost/scripts/bootstrap_selfhost.sh downloads:
#   cell-<A>.tar (the cell members only), host-extras-<A>.tar (the host files in host-extras.names.tmpl),
#   cell_manifest.v2, LAYOUT.txt, MANIFEST.sha256, CELL.txt, plus the release notes.
#
#   MINT_ENV=<env file> bash repack.sh            # PLAN: checks the inputs, builds nothing
#   MINT_ENV=<env file> bash repack.sh --build    # build into $OUT/repack, run the hydrate check. Local only.
#   MINT_ENV=<env file> bash repack.sh --run      # upload the six files to the existing release (--clobber) and rewrite its notes
#
# Needs publish_cell.sh --run to have made the release, and stage_mint.sh --run to have made $OUT/ov-mint.
# The hydrate check runs selfhost/scripts/sd1_hydrate_cell.sh from the helpers checkout.
# Release notes come from the env file: see mint.env.example (CLI_PR, ENGINE_NOTE, PROMO_NOTE, NOTES_EXTRA).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); . "$HERE/lib.sh"; load_env; resolve_helpers
MODE=plan; case "${1:-}" in --build) MODE=build;; --run) MODE=run;; "") ;; *) die "usage: $0 [--build|--run]";; esac
export LC_ALL=C
O=$OUT; R=$O/repack
[[ -f $O/ADDRESS ]] || die "no $O/ADDRESS: run stage_mint.sh --run first"
A=$(cat "$O/ADDRESS"); hex40 address "$A"; A8=${A:0:8}; REL=cell-$A8
HE_LIST=$R/host-extras.names
[[ -d $O/ov-mint && -f $O/members.names && -f $O/extras.names ]] || die "no staged cell in $O (stage_mint.sh --run)"
[[ -z ${CLI_PR:-} || ${CLI_PR} =~ ^[0-9]+$ ]] || die "CLI_PR must be a number"

if [[ $MODE == plan ]]; then
  echo "cell $A, release $REL on $CELL_REPO; members $(wc -l < "$O/members.names" | tr -d ' '); extras staged $(wc -l < "$O/extras.names" | tr -d ' ')"
  echo "host-extras template: $MINT_DIR/host-extras.names.tmpl ($(wc -l < "$MINT_DIR/host-extras.names.tmpl" | tr -d ' ') files)"
  echo "PLAN ONLY. --build builds into $R; --run uploads."; exit 0
fi

if [[ $MODE == build ]]; then
  rm -rf "$R"; mkdir -p "$R/dist"
  CELL_ADDRESS=$A render_tmpl "$MINT_DIR/host-extras.names.tmpl" | sort > "$HE_LIST"
  NHE=$(wc -l < "$HE_LIST" | tr -d ' ')
  # Every host-extras file must be among the staged extras.
  missing=$(sort "$O/extras.names" | comm -23 "$HE_LIST" -)
  [[ -z $missing ]] || { echo "$missing"; die "these host-extras files are not in the staged extras"; }
  sort "$O/members.names" > "$R/members.names"; NM=$(wc -l < "$R/members.names" | tr -d ' ')
  [[ $NM == "${EXPECT_MEMBERS:-30}" ]] || die "$NM members staged, expected ${EXPECT_MEMBERS:-30}"
  export COPYFILE_DISABLE=1
  tar --no-mac-metadata --no-xattrs --uid 0 --gid 0 --uname '' --gname '' -cf "$R/dist/cell-$A.tar" -C "$O/ov-mint" -T "$R/members.names"
  tar --no-mac-metadata --no-xattrs --uid 0 --gid 0 --uname '' --gname '' -cf "$R/dist/host-extras-$A.tar" -C "$O/ov-mint" -T "$HE_LIST"
  python3 -I - "$R/dist/cell-$A.tar" "$R/dist/host-extras-$A.tar" <<'PY'
import sys, tarfile
for t in sys.argv[1:]:
    n = [m.name for m in tarfile.open(t).getmembers() if m.isfile()]
    bad = [x for x in n if x.split('/')[-1].startswith('._')]
    assert not bad, (t, bad[:3])
    print(t.split('/')[-1], len(n), 'files, no AppleDouble')
PY
  cp "$O/dist/cell_manifest.v2" "$R/dist/"
  { echo "# Cell $A: where each member goes, relative to the CDN overlay root."
    echo "# sha256 values are the RAW file digests (what a download must match)."
    echo "# The descriptor's own digests are canonical-form and are in cell_manifest.v2."
    echo "#"; echo "# overlay_relative_path  sha256  bytes"
    while read -r p; do echo "$p $(shasum -a 256 "$O/ov-mint/$p" | cut -d' ' -f1) $(stat -f %z "$O/ov-mint/$p")"; done < "$R/members.names"
  } > "$R/dist/LAYOUT.txt"
  cd "$R/dist"
  shasum -a 256 "cell-$A.tar" cell_manifest.v2 LAYOUT.txt > MANIFEST.sha256
  { echo "cell_address $A"; echo "members $NM"; echo "bundle cell-$A.tar"
    echo "bundle_sha256 $(shasum -a 256 "cell-$A.tar" | cut -d' ' -f1)"; echo "bundle_bytes $(stat -f %z "cell-$A.tar")"
    echo "descriptor_sha256 $(shasum -a 256 cell_manifest.v2 | cut -d' ' -f1)"; echo "layout_sha256 $(shasum -a 256 LAYOUT.txt | cut -d' ' -f1)"
  } > CELL.txt
  shasum -a 256 "host-extras-$A.tar" > "$R/host-extras.sha256"
  cat MANIFEST.sha256 CELL.txt "$R/host-extras.sha256"; ls -l
  echo "== hydrate check (sd1_hydrate_cell.sh from $HELPERS)"
  HY=$R/hydrated; rm -rf "$HY"
  rc=0; bash "$SCRIPTS/sd1_hydrate_cell.sh" --dist "$R/dist" --overlay "$HY" --cell "$A" --host-extras "$R/dist/host-extras-$A.tar" > "$R/hydrate.log" 2>&1 || rc=$?
  tail -25 "$R/hydrate.log"
  [[ $rc == 0 ]] && ! grep -q "HYDRATION FAILED" "$R/hydrate.log" || die "hydrate failed (exit $rc)"
  echo "files in hydrated overlay: $(find "$HY" -type f | wc -l | tr -d ' ')"; rm -rf "$HY"
  FULL=$(awk -v f="cell-$A.tar" '$2==f{print $1}' "$O/dist/MANIFEST.sha256")
  NALL=$(wc -l < "$O/ci-stage/names" | tr -d ' ')
  sz() { stat -f %z "$R/dist/$1"; }; dg() { shasum -a 256 "$R/dist/$1" | cut -d' ' -f1; }
  C=${SEL_CLONE:?set SEL_CLONE in $MINT_ENV}
  SEL=${SEL:-$(git -C "$C" rev-parse "refs/heads/$SELECTOR_BRANCH_PREFIX$A8")}
  [[ -n "$FULL" && -n "$SEL" ]] || die "notes incomplete"
  CLI_NOTE=""; [[ -z ${CLI_PR:-} ]] || CLI_NOTE=" through the CLI PR #$CLI_PR"
  cat > "$R/notes.md" <<NOTES
Cell \`$A\`: route-b-cell-v2, $CELL, $NM members, minted over engine \`$E\` ($ENGINE_REPO \`$ENGINE_BRANCH\`, Flutter $FLUTTER_LINE, Dart \`${DART:0:8}\`${ENGINE_NOTE:+; $ENGINE_NOTE}). Fallback engine \`$FB\` (Shorebird \`$FB_BRANCH\`).

Selected by $ENGINE_REPO \`$SEL\` (branch \`$SELECTOR_BRANCH_PREFIX$A8\`, tag \`selfhost-flutter-cell-$A8\`; its parent is the engine commit and the delta is \`bin/internal/engine.version\` alone)$CLI_NOTE.

Promotion on ci-build (selfhost/TOOLCHAIN_PROMOTION.md): ${PROMO_NOTE:-not yet run}.
${NOTES_EXTRA:+
$NOTES_EXTRA
}
| Asset | SHA-256 |
|---|---|
| \`cell-${A8}….tar\` ($(sz "cell-$A.tar") B, the $NM members) | \`$(dg "cell-$A.tar")\` |
| \`host-extras-${A8}….tar\` ($(sz "host-extras-$A.tar") B) | \`$(dg "host-extras-$A.tar")\` |
| \`cell_manifest.v2\` | \`$(dg cell_manifest.v2)\` |
| \`LAYOUT.txt\` | \`$(dg LAYOUT.txt)\` |

The host-extras tar holds $NHE unaddressed host files (the list is host-extras.names.tmpl in selfhost/engine/route_b/mint). It is additive and not part of the address. \`MANIFEST.sha256\` and \`CELL.txt\` describe these files, which \`selfhost/scripts/bootstrap_selfhost.sh\` downloads.

The full overlay (all $NALL files, including the debug and profile Android artifacts) is in parts because of GitHub's 2 GiB asset limit: \`cat cell-$A.tar.part-* > full-overlay-$A.tar\` gives SHA-256 \`$FULL\` (\`PARTS.sha256\` checks the parts; \`files.sha256\` lists the $NALL files).
NOTES
  echo "notes: $R/notes.md"
  echo "REPACK BUILT ($R/dist)"; exit 0
fi

# --run
[[ -d $R/dist && -s $R/notes.md ]] || die "no build in $R: run --build first"
cd "$R/dist"
shasum -a 256 -c MANIFEST.sha256 && shasum -a 256 -c "$R/host-extras.sha256" || die "a checksum failed"
gh release view "$REL" -R "$CELL_REPO" >/dev/null || die "release $REL does not exist on $CELL_REPO (publish_cell.sh --run first)"
gh release upload "$REL" -R "$CELL_REPO" --clobber "cell-$A.tar" "host-extras-$A.tar" cell_manifest.v2 LAYOUT.txt MANIFEST.sha256 CELL.txt
gh release edit "$REL" -R "$CELL_REPO" --notes-file "$R/notes.md"
gh release view "$REL" -R "$CELL_REPO" --json assets -q '.assets[]|.name+" "+(.size|tostring)+" "+.digest'
