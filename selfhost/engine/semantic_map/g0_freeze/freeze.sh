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

# ---- 6. the adversarial arm: a mutated input must change the freeze ---------
# The freeze record must be a function of the bytes. If a mutant can be swapped
# in without the record moving, the freeze is decorative.
CORPUS_DIGEST=$(find "$CORP" -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
T=$(mktemp -d); cp -R "$CORP" "$T/corpus"
printf '\n// adversarial arm\n' >> "$T/corpus/base/app.dart"
MUT_DIGEST=$(find "$T/corpus" -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
if [[ "$CORPUS_DIGEST" != "$MUT_DIGEST" ]]; then
  ok "adversarial arm: a one-line mutation changes the corpus digest"
else
  bad "adversarial arm: the corpus digest did NOT move under mutation — the freeze is decorative"
fi
rm -rf "$T"

# ---- 7. emit / verify ------------------------------------------------------
if [[ "$MODE" == emit ]]; then
  python3 - "$MANIFEST" "$REPO" "$HERE" "$ANALYZER_SHIPPED" "${ANALYZER_BUILD_TREE:-}" "$CORPUS_DIGEST" "$CELL" <<'G0JSON'
import json,sys,os,hashlib,datetime,subprocess
man, repo, here, an_ship, an_build, corpus_digest, cell = sys.argv[1:8]
def sha(p):
    try:
        h=hashlib.sha256()
        with open(p,'rb') as f:
            for c in iter(lambda: f.read(1<<20), b''): h.update(c)
        return h.hexdigest()
    except OSError: return None
rb = os.path.join(repo,'selfhost/engine/route_b')
sl1 = os.path.join(repo,'selfhost/engine/semantic_linker/runtime_feasibility/g0_freeze/freeze_manifest.json')
inherited = json.load(open(sl1)) if os.path.isfile(sl1) else {}
refs = {rel: sha(os.path.join(rb,rel)) for rel in
        ('identity/gen_target_manifest.dart','packaging/build_patch.dart',
         'coverage/analyze_coverage.dart','coverage/parity.sh')}
pins = {rel: sha(os.path.join(rb,rel)) for rel in
        ('coverage/demand1/wonderous.window.txt','coverage/demand1/localsend.window.txt')}
doc = {
 'schema':'semantic-map-1/g0-freeze/1','gate':'SM1-G0','issue':49,'tracker':48,
 'frozen': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
 'inherited_lineage': {
   'from':'semantic_linker/runtime_feasibility/g0_freeze/freeze_manifest.json',
   'distribution': inherited.get('distribution',{}),
   'producing_source': inherited.get('producing_source',{}),
   'note':'SEMANTIC-MAP-1 builds from this lineage. #47 is off the critical path; the bank is what makes that safe.'},
 'analyzer': {
   'shipped_sha256': an_ship, 'cell': cell,
   'build_tree_sha256': an_build or None,
   'divergence': (an_build is not None and an_build != an_ship),
   'finding': ('coverage/parity.sh defaults ANALYZER to the BUILD TREE copy, which is not the '
               'artifact the cell ships. Any parity run in this lane must pin ANALYZER= to the '
               'shipped digest, or it measures something the product does not use.')},
 'reference_implementations': refs,
 'reference_implementation_note': ('gen_target_manifest.dart and build_patch.dart are the incumbent '
   'reference oracles and stay UNMODIFIED; parity.sh proves the shipped analyzer agrees with them. '
   'Printed-Kernel equality is that incumbent, not this lane\'s wire contract.'),
 'corpus': {
   'real_world_regression': {'pins': pins,
     'scope':'continuity anchor only; selected for a different question'},
   'adversarial_semantic': {'digest': corpus_digest,
     'expectations': 'corpus/EXPECTATIONS.json',
     'mutants': len(json.load(open(os.path.join(here,'corpus/EXPECTATIONS.json')))['mutants'])}},
 'historical_baselines': {
   'wonderous':'50.00%','localsend':'92.67%',
   'scope':('Route B PRODUCER-DEMAND baselines, measured for a different question. They are NOT '
            'semantic-map quality scores and are not reinterpreted as such by this lane.'),
   'source':'selfhost/engine/route_b/evidence/producer_demand_2.md'},
 'confounds_recorded': [
   {'id':'PLATFORM_LIBRARY_GUARD_IS_UNCOMMITTED',
    'statement':('The guard refusing --resolve-private-names-in-library on a platform library is '
                 'uncommitted-but-shipped source, present in effective tree 7b04b01b and absent '
                 'from a clean checkout of 9e8c898a.'),
    'consequence':'A gate built from the wrong tree makes the platform-library arm pass vacuously.',
    'owner_gate':'SM1-G3'},
   {'id':'ANALYZER_BUILD_TREE_DIVERGENCE',
    'statement':'parity.sh defaults to a build-tree analyzer that is not the shipped one.',
    'consequence':'Freezing or measuring the wrong analyzer.','owner_gate':'SM1-G0 (recorded here)'},
   {'id':'VM_ENTRY_POINT_RETAINS_INDEPENDENTLY',
    'statement':"@pragma('vm:entry-point') retains a symbol regardless of the dynamic-interface contract.",
    'consequence':'A retention control passes while measuring the pragma.','owner_gate':'SM1-G4'}],
 'unmodified': {
   'claim':'no supported artifact, selector or cell is modified by this lane',
   'checked':['packages/','bin/','selfhost/engine/route_b/','selfhost/compatibility.yaml']},
}
json.dump(doc, open(man,'w'), indent=2)
print(f'  ok      wrote {man}')
G0JSON
else
  if [[ -f "$MANIFEST" ]]; then
    REC=$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d['corpus']['adversarial_semantic']['digest'])" "$MANIFEST" 2>/dev/null)
    cmp_v "adversarial corpus digest unchanged since the freeze" "$REC" "$CORPUS_DIGEST"
    RECAN=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['analyzer']['shipped_sha256'])" "$MANIFEST" 2>/dev/null)
    cmp_v "shipped analyzer unchanged since the freeze" "$RECAN" "$ANALYZER_SHIPPED"
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
