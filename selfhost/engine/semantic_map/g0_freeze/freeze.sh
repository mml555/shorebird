#!/usr/bin/env bash
# cspell:words dartaotruntime dill semantic localsend wonderous
# freeze.sh -- SEMANTIC-MAP-1 / G0 (#49). Freeze everything this lane reasons
# from, so a later gate's disagreement is attributable to the map rather than to
# a moved input.
#
# THE FREEZE IS BYTES, NOT LABELS. Every input is recorded by digest or immutable
# revision and re-read from disk on verify. A stamp asserts what an input is
# CLAIMED to be; this compares what it IS.
#
# ONE FINDING IS BAKED IN HERE. coverage/parity.sh defaults its ANALYZER to
# $OUT/zip_archives/route_b_analyze.aot -- an artifact in the BUILD TREE that is
# NOT the analyzer the cell ships. Measured 2026-09-06:
#
#     build tree   18862acd...  2,035,128 bytes
#     shipped cell 67741a08...  2,053,976 bytes   <- SUPPORTED_STATE.yaml
#
# Freezing "the analyzer" by pointing at the build tree would freeze the wrong
# artifact and every later gate would be measuring something the product does not
# use. This script freezes the SHIPPED one and records the discrepancy.
#
#   freeze.sh [--verify | --emit]
#
# Exit: 0 clean · 1 a check failed · 2 environment error
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd -- "$HERE/../../../.." >/dev/null 2>&1 && pwd)"
RB="$REPO/selfhost/engine/route_b"
SL1="$REPO/selfhost/engine/semantic_linker/runtime_feasibility"
MANIFEST="$HERE/freeze_manifest.json"
EVID="$HERE/evidence"; mkdir -p "$EVID"
CELL=${CELL:-f85251f344600ae08196925a174e9cff8f0ff18e}
ZIP="$REPO/selfhost/cdn/overlay/download.shorebird.dev/shorebird/$CELL/route-b-compiler-darwin-arm64.zip"
MODE=verify
[[ "${1:-}" == "--emit" ]] && MODE=emit
[[ "${1:-}" == "--verify" ]] && MODE=verify

fails=0
ok()  { printf '  ok      %s\n' "$*"; }
bad() { printf '  FAILED  %s\n' "$*"; fails=$((fails+1)); }
cmp_v(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1: expected $2, got ${3:-<none>}"; fi; }
sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

echo "SEMANTIC-MAP-1 G0 freeze ($MODE)"
echo "  repo : $REPO"

# ---- 1. the release lineage this lane builds against ------------------------
SL1FREEZE="$SL1/g0_freeze/freeze_manifest.json"
if [[ -f "$SL1FREEZE" ]]; then
  ok "inherits the SEMANTIC-LINKER-1 freeze ($(basename "$SL1FREEZE"))"
  DART_EFF=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['producing_source']['dart']['effective_tree'])" "$SL1FREEZE")
  cmp_v "producing Dart effective tree" "7b04b01bdc10ec990143257f0d28580571c2122f" "$DART_EFF"
else
  bad "no SEMANTIC-LINKER-1 freeze manifest to inherit"
fi

# ---- 2. the analyzer, taken from the CELL and not from the build tree --------
ANALYZER_SHIPPED=""
if [[ -f "$ZIP" ]]; then
  U=$(mktemp -d)
  if unzip -qo "$ZIP" route_b_analyze.aot -d "$U" 2>/dev/null; then
    ANALYZER_SHIPPED=$(sha "$U/route_b_analyze.aot")
    RECORDED=$(sed -nE 's/^[[:space:]]*analyzer_sha256:[[:space:]]*([0-9a-f]+).*/\1/p' "$RB/SUPPORTED_STATE.yaml" | head -1)
    cmp_v "shipped analyzer matches the supported record" "$RECORDED" "$ANALYZER_SHIPPED"
  else
    bad "cannot extract the analyzer from the published cell archive"
  fi
  rm -rf "$U"
else
  bad "no published cell archive at $ZIP"
fi
# The build-tree copy, recorded as a KNOWN DIVERGENCE rather than silently used.
BUILD_ANALYZER="${BUILD_ANALYZER:-/Volumes/build/route-b/flutter/engine/src/out/host_release_arm64/zip_archives/route_b_analyze.aot}"
ANALYZER_BUILD_TREE=$(sha "$BUILD_ANALYZER")
if [[ -n "$ANALYZER_BUILD_TREE" && "$ANALYZER_BUILD_TREE" != "$ANALYZER_SHIPPED" ]]; then
  ok "build-tree analyzer differs from the shipped one, as recorded (${ANALYZER_BUILD_TREE:0:12} vs ${ANALYZER_SHIPPED:0:12})"
elif [[ -n "$ANALYZER_BUILD_TREE" ]]; then
  ok "build-tree analyzer happens to equal the shipped one"
else
  echo "  --      no build-tree analyzer present on this machine (not required)"
fi

# ---- 3. the reference implementations parity.sh cross-checks ----------------
REF1="$RB/identity/gen_target_manifest.dart"
REF2="$RB/packaging/build_patch.dart"
REF3="$RB/coverage/analyze_coverage.dart"
PAR="$RB/coverage/parity.sh"
for f in "$REF1" "$REF2" "$REF3" "$PAR"; do
  [[ -f "$f" ]] && ok "frozen: ${f#$REPO/}" || bad "missing reference implementation: ${f#$REPO/}"
done

# ---- 4. the real-world corpus pins -----------------------------------------
W="$RB/coverage/demand1/wonderous.window.txt"
L="$RB/coverage/demand1/localsend.window.txt"
for f in "$W" "$L"; do
  [[ -f "$f" ]] && ok "corpus pin: ${f#$REPO/} ($(grep -c . "$f") revisions)" || bad "missing corpus pin: ${f#$REPO/}"
done

# ---- 5. the adversarial semantic corpus ------------------------------------
CORP="$HERE/corpus"
EXP="$CORP/EXPECTATIONS.json"
if [[ -f "$EXP" ]]; then
  N_DECL=$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))['mutants']))" "$EXP")
  N_DISK=$(ls "$CORP/mutants" | wc -l | tr -d ' ')
  cmp_v "declared mutants == mutants on disk" "$N_DECL" "$N_DISK"
  # Every declared mutant must actually differ from base, or it tests nothing.
  vac=0
  while IFS= read -r m; do
    if diff -rq "$CORP/base" "$CORP/mutants/$m" >/dev/null 2>&1; then
      bad "mutant '$m' is identical to base — it would pass vacuously"; vac=$((vac+1))
    fi
  done < <(python3 -c "import json,sys;[print(m['id']) for m in json.load(open(sys.argv[1]))['mutants']]" "$EXP")
  [[ "$vac" -eq 0 ]] && ok "every declared mutant differs from base"
else
  bad "no corpus expectations at $EXP"
fi

# ---- 6. adversarial arms ---------------------------------------------------
# THE ONE #49 ASKS FOR: build a release dill from the frozen source, mutate ONE
# declaration, rebuild, and require the release identity to move.
#
# Its confound is stated and controlled first: "the digest differs" proves
# nothing unless a rebuild of the SAME source is shown to be deterministic. It
# is, and the control runs every time rather than being asserted once.
BASE_DILL_SHA=""
# DILL_SOURCE exists so the verifier's refusal can be exercised in ISOLATION:
# pointing it at a mutant changes the rebuilt dill while leaving every frozen
# corpus file untouched, so the only check that fails is the release-identity
# one. Without it, mutating the corpus on disk fails the input hashes too and the
# transcript would not show which refusal fired.
DILL_SOURCE=${DILL_SOURCE:-$HERE/corpus/base}
if [[ "${SKIP_DILL:-0}" == 1 ]]; then
  if [[ "$MODE" == verify ]]; then
    bad "SKIP_DILL is not honoured on --verify: the release-dill proof is mandatory"
  else
    echo "  SKIP    release-dill arm not run (SKIP_DILL=1) — the emitted freeze will be INCOMPLETE and will not verify"
  fi
else
  DW=$(mktemp -d)
  if bash "$HERE/lib/build_corpus_dill.sh" "$DILL_SOURCE" "$DW/base1.dill" >/dev/null 2>&1 \
  && bash "$HERE/lib/build_corpus_dill.sh" "$DILL_SOURCE" "$DW/base2.dill" >/dev/null 2>&1; then
    if [[ -s "$DW/base1.dill" && -s "$DW/base2.dill" ]]; then
      B1=$(sha "$DW/base1.dill"); B2=$(sha "$DW/base2.dill")
      if [[ "$B1" == "$B2" ]]; then
        ok "release dill is deterministic across rebuilds (control; source $(basename "$DILL_SOURCE"))"
        BASE_DILL_SHA=$B1
        # In refusal-exercise mode DILL_SOURCE already points at a mutant, so
        # comparing it against that same mutant would report "did not move" and
        # contradict the refusal the run is demonstrating. The sub-arm applies
        # only when the source is the base.
        if [[ "$DILL_SOURCE" != "$HERE/corpus/base" ]]; then
          echo "  --      mutation sub-arm not applicable: DILL_SOURCE is $(basename "$DILL_SOURCE"), not base (refusal-exercise mode)"
        elif bash "$HERE/lib/build_corpus_dill.sh" "$HERE/corpus/mutants/body_only" "$DW/mut.dill" >/dev/null 2>&1 \
           && [[ -s "$DW/mut.dill" ]]; then
          MS=$(sha "$DW/mut.dill")
          [[ "$MS" != "$B1" ]] && ok "one-declaration mutation changes the release dill (${B1:0:12} -> ${MS:0:12})" \
                               || bad "the release dill did NOT move under a one-declaration mutation"
        else
          bad "could not build the mutant release dill"
        fi
      else
        bad "release dill is NOT deterministic — a digest difference would prove nothing"
      fi
    else
      bad "release dill build produced no output; the arm would compare empty strings"
    fi
  else
    bad "could not build the base release dill"
  fi
  rm -rf "$DW"
fi

# SUPPLEMENTARY, kept because it is cheap and independent of the toolchain:
# a source mutation must move the corpus digest.
CORPUS_DIGEST=$(find "$CORP" -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
T=$(mktemp -d); cp -R "$CORP" "$T/corpus"
printf '\n// adversarial arm\n' >> "$T/corpus/base/app.dart"
MUT_DIGEST=$(find "$T/corpus" -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
[[ "$CORPUS_DIGEST" != "$MUT_DIGEST" ]] && ok "supplementary: a source mutation changes the corpus digest" \
                                        || bad "supplementary: the corpus digest did NOT move under mutation"
rm -rf "$T"

# ---- 7. emit / verify ------------------------------------------------------
# THE MANIFEST IS THE SOURCE OF TRUTH. Verification iterates `frozen_inputs` and
# re-hashes every entry; there is no parallel hard-coded inventory to drift from
# it. The first version of this script recorded hashes for the reference tools
# and the corpus pins and then checked only their EXISTENCE -- so a one-byte edit
# to gen_target_manifest.dart still printed G0 FREEZE VERIFIED. A freeze that
# records a digest it never compares is decorative.
if [[ "$MODE" == emit ]]; then
  python3 "$HERE/lib/emit_manifest.py" "$MANIFEST" "$REPO" "$HERE" \
    "$ANALYZER_SHIPPED" "${ANALYZER_BUILD_TREE:-}" "$CORPUS_DIGEST" "$CELL" \
    "${BASE_DILL_SHA:-}" && ok "wrote $MANIFEST" || bad "could not write $MANIFEST"
else
  if [[ -f "$MANIFEST" ]]; then
    OUTPUT=$(python3 "$HERE/lib/verify_manifest.py" "$MANIFEST" "$REPO" "$HERE" \
      "$ANALYZER_SHIPPED" "$CORPUS_DIGEST" "${BASE_DILL_SHA:-}")
    RC=$?
    printf '%s\n' "$OUTPUT"
    [[ "$RC" -eq 0 ]] || fails=$((fails + $(grep -c 'FAILED' <<<"$OUTPUT")))
  else
    bad "no freeze manifest — run with --emit"
  fi
fi

# ---- 8. the product must be untouched --------------------------------------
DIRTY=$(git -C "$REPO" status --porcelain -- packages bin selfhost/engine/route_b selfhost/compatibility.yaml | head)
[[ -z "$DIRTY" ]] && ok "no supported artifact, selector or cell modified" \
                  || bad "this lane modified product files: $DIRTY"

echo
[[ "$fails" -eq 0 ]] && echo "G0 FREEZE VERIFIED" || echo "G0 FREEZE FAILED: $fails check(s)"
exit $(( fails > 0 ))
