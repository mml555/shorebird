#!/usr/bin/env bash
# SM1-G5 Phase D -- the real application corpora.
#
# Per the #54 ruling: a fully-evidenced predictor result of zero admitted
# declarations satisfies `predicted SUBSET-OF demonstrated` without a
# behavioural demonstration, because the empty set is a subset of anything. But
# the corpora must still run the COMPLETE pipeline -- emptiness may not come
# from omitted evidence -- and an injected admitted row must FAIL_OPEN.
#
# So per corpus this builds both kernels and the release AOT through the
# instrumented toolchain, produces all four evidence inputs, derives the
# release contract from the artifact, runs the strict reader over it, runs the
# real predictor, asserts complete accounting, and injects one fake admitted
# row requiring FAIL_OPEN.
#
# Intermediate artifacts are 40-115 MB each and are NOT banked; this script and
# the recorded digests are the provenance.
#
# usage: run_corpora.sh <clone-src> <corpora-dir>
set -uo pipefail
SRC="${1:?usage: run_corpora.sh <clone-src> <corpora-dir>}"
C="${2:?usage: run_corpora.sh <clone-src> <corpora-dir>}"
G="$(cd "$(dirname "$0")" && pwd)"
SM="$(cd "$G/.." && pwd)"
S="$SRC/out/host_release_arm64"
DT="$SRC/flutter/third_party/dart"
PKG="--packages=$DT/.dart_tool/package_config.json"
GK="$S/dartaotruntime $S/gen/gen_kernel_aot.dart.snapshot"
PLAT="$S/flutter_patched_sdk/platform_strong.dill"
mkdir -p "$C"
rc=0
ASSERTIONS=()
want() {
  if [ "$2" = "$3" ]; then ASSERTIONS+=("  pass  $1")
  else ASSERTIONS+=("  FAIL  $1 -- got '$3', expected '$2'"); rc=1; fi
}
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
jq_() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2],{'d':d}))" "$1" "$2"; }

# EVERY PRODUCER'S EXIT STATUS IS LOAD-BEARING. These previously ran inside a
# pipeline whose status was discarded, so a failed producer left the previous
# run's output in place and later assertions consumed it.
PRODUCER_FAILED=""
must() { # must <what> <cmd...>
  local what="$1"; shift
  if ! "$@"; then
    echo "    PRODUCER FAILED: $what"
    PRODUCER_FAILED="${PRODUCER_FAILED}$what; "
    rc=1
    return 1
  fi
}

# ---------------------------------------------------------------- corpora
# name | worktree | entry (relative) | include prefix
CORPORA=(
  "localsend|/Volumes/build/route-b/demand1/localsend/wt|app/lib/main.dart|package:localsend_app/"
  "wonderous|$C/wonderous_wt|lib/main.dart|package:wonders/"
)

# Wonderous is prepared into a COPY: its worktree belongs to another lane, and
# its source has drifted ahead of its own lock resolution
# (InternetConnectionChecker.instance does not exist in the resolved 1.0.0+1,
# which offers the factory). One line is changed, and it is recorded here
# rather than left as an unexplained difference from upstream.
prepare_wonderous() {
  local W=/Volumes/build/route-b/demand1/wonderous/wt
  local D="$C/wonderous_wt"
  local F="$D/lib/logic/common/platform_info.dart"

  # ALWAYS REBUILT, NEVER REUSED. Reusing an existing prepared tree means the
  # run describes a tree it did not create -- and the `cp -c -R src dst ||
  # cp -R src dst` pattern is the one that produced an invalid completeness
  # control earlier: the first form fails across volumes, and the fallback then
  # ran with dst already partly created and nested the tree one level down.
  rm -rf "$D"
  mkdir -p "$D" || { echo "  cannot create $D"; return 1; }
  # Copy CONTENTS into an existing directory, so there is no create-or-nest
  # ambiguity, and require success.
  if ! cp -R "$W/." "$D/"; then
    echo "  PRODUCER FAILED: wonderous:copy"
    PRODUCER_FAILED="${PRODUCER_FAILED}wonderous:copy; "
    return 1
  fi
  for req in lib/main.dart .dart_tool/package_config.json \
             lib/logic/common/platform_info.dart; do
    [ -f "$D/$req" ] || {
      echo "  PRODUCER FAILED: wonderous:copy incomplete, missing $req"
      PRODUCER_FAILED="${PRODUCER_FAILED}wonderous:copy($req); "
      return 1
    }
  done

  # The one recorded source change, and it must actually apply: the worktree
  # calls InternetConnectionChecker.instance, absent from the 1.0.0+1 its
  # lockfile resolves (that version offers the factory). Without this the
  # kernel does not build at all.
  sed -i '' \
    's/InternetConnectionChecker\.instance\.hasConnection/InternetConnectionChecker().hasConnection/' \
    "$F"
  if grep -q 'InternetConnectionChecker\.instance' "$F"; then
    echo "  PRODUCER FAILED: wonderous:patch did not apply"
    PRODUCER_FAILED="${PRODUCER_FAILED}wonderous:patch; "
    return 1
  fi
  grep -q 'InternetConnectionChecker()\.hasConnection' "$F" || {
    echo "  PRODUCER FAILED: wonderous:patch left no expected call"
    PRODUCER_FAILED="${PRODUCER_FAILED}wonderous:patch-shape; "
    return 1
  }
  echo "  wonderous prepared fresh: $(find "$D" -type f | wc -l | tr -d ' ') files,"
  echo "    one recorded source change in lib/logic/common/platform_info.dart"
  return 0
}

{
echo "SM1-G5 Phase D -- real application corpora"
echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by run_corpora.sh"
echo
echo "  gen_snapshot $(sha "$S/gen_snapshot")  (frozen + 0001 + 0002)"
echo "  platform     $(sha "$PLAT")"
echo
cat <<'TXT'
THE RULING THIS IMPLEMENTS (#54)

  A fully-evidenced predictor result of zero admitted declarations satisfies
  the subset property with no behavioural demonstration: the empty set is a
  subset of anything. The corpora must still run the complete pipeline --
  emptiness may NOT come from omitted evidence -- and an injected admitted row
  must FAIL_OPEN.

  If a corpus ever admits a declaration, behavioural GUI observability becomes
  necessary for those rows only.
TXT
prepare_wonderous

for spec in "${CORPORA[@]}"; do
  IFS='|' read -r NAME WT ENTRY INC <<< "$spec"
  echo
  echo "################################ $NAME ################################"
  if [ ! -d "$WT" ]; then
    echo "  MISSING worktree $WT"; rc=1; continue
  fi
  # DELETE EVERY DERIVED ARTIFACT FIRST, so nothing from an earlier run can be
  # mistaken for this one's output.
  rm -f "$C/${NAME}_aot.dill" "$C/${NAME}_pre.dill" "$C/$NAME.aot" \
        "$C/${NAME}_g1.json" "$C/${NAME}_g3.json" "$C/${NAME}_g4.json" \
        "$C/${NAME}_refs.json" "$C/${NAME}_contract.json" \
        "$C/${NAME}_inlining.json" "$C/${NAME}_predictions.json" \
        "$C/${NAME}_subset.json" "$C/${NAME}_injected.json" \
        "$C/${NAME}_inj_subset.json" "$G/evidence/corpus_${NAME}.json"
  echo "  worktree $WT"
  echo "  entry    $ENTRY"
  echo "  include  $INC"
  echo
  echo "--- 1. kernels and release AOT, through the instrumented toolchain ---"
  must "$NAME:gen_kernel-aot" $GK --platform "$PLAT" --target flutter --aot \
      --packages "$WT/.dart_tool/package_config.json" \
      -o "$C/${NAME}_aot.dill" "$WT/$ENTRY"
  must "$NAME:gen_kernel-pre" $GK --platform "$PLAT" --target flutter \
      --packages "$WT/.dart_tool/package_config.json" \
      -o "$C/${NAME}_pre.dill" "$WT/$ENTRY"
  must "$NAME:gen_snapshot" "$S/gen_snapshot" --snapshot_kind=app-aot-elf \
      --patchable_static_calls --elf="$C/$NAME.aot" "$C/${NAME}_aot.dill"
  for f in "${NAME}_aot.dill" "${NAME}_pre.dill" "$NAME.aot"; do
    if [ -s "$C/$f" ]; then echo "    $(sha "$C/$f")  $f"
    else echo "    MISSING $f"; rc=1; fi
  done
  echo
  echo "--- 2. all four evidence inputs, produced not stubbed ---"
  must "$NAME:g1" env -C "$C" "$S/dart" $PKG \
      "$SM/g2_fingerprints/lib/gen_map_rows.dart" \
      --dill "${NAME}_aot.dill" --pre-dill "${NAME}_pre.dill" \
      --include "$INC" --out "${NAME}_g1.json"
  must "$NAME:g3" env -C "$C" "$S/dart" $PKG \
      "$SM/g3_privacy/lib/gen_privacy_rows.dart" \
      --dill "${NAME}_aot.dill" --pre-dill "${NAME}_pre.dill" \
      --include "$INC" --out "${NAME}_g3.json"
  must "$NAME:g4" env -C "$C" "$S/dart" $PKG \
      "$SM/g4_retention/lib/gen_retention_rows.dart" \
      --dill "${NAME}_aot.dill" --enforcement "$SM/g4_retention/evidence/arms.json" \
      --include "$INC" --out "${NAME}_g4.json"
  must "$NAME:refs" env -C "$C" "$S/dart" $PKG "$G/lib/body_references.dart" \
      --dill "${NAME}_aot.dill" --include "$INC" --out "${NAME}_refs.json"
  echo
  echo "--- 3. release contract, from the release artifact ---"
  must "$NAME:contract" env -C "$C" "$S/dart" $PKG \
      "$G/lib/release_contract.dart" --dill "${NAME}_aot.dill" \
      --aot "$NAME.aot" --include "$INC" --out "${NAME}_contract.json"
  echo "    capability $(jq_ "$C/${NAME}_contract.json" "d['release_patch_capability']")"
  echo "    evidence   $(jq_ "$C/${NAME}_contract.json" "d['release_patch_capability_evidence'][:56]")"
  echo
  echo "--- 4. Route 2 reader over that exact AOT ---"
  must "$NAME:reader" python3 "$G/lib/read_inlining.py" "$C/$NAME.aot" \
      "$C/${NAME}_g1.json" - "$C/${NAME}_inlining.json"
  echo
  echo "--- 5. the real predictor ---"
  must "$NAME:predictor" "$S/dart" "$G/lib/predict_patchable.dart" \
      --g2 "$C/${NAME}_g1.json" --g3 "$C/${NAME}_g3.json" \
      --g4 "$C/${NAME}_g4.json" --refs "$C/${NAME}_refs.json" \
      --release-contract "$C/${NAME}_contract.json" \
      --inlining-state "$C/${NAME}_inlining.json" \
      --out "$C/${NAME}_predictions.json"
  python3 - "$C/${NAME}_predictions.json" <<'PY' | sed 's/^/    /'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"declarations={d['count']} predicted_patchable={d['predicted_patchable']}")
for k, v in sorted(d['refusal_histogram'].items(), key=lambda x: (-x[1], x[0])):
    print(f"  {v:6}  {k}")
PY
  echo
  echo "--- 6. the subset property ---"
  python3 "$G/lib/score_subset.py" "$C/${NAME}_predictions.json" - \
      "$C/${NAME}_subset.json" 2>&1 | sed 's/^/    /'
  echo
  echo "--- 7. injected over-claim must FAIL_OPEN ---"
  python3 - "$C/${NAME}_predictions.json" "$C/${NAME}_injected.json" <<'PY' | sed 's/^/    /'
import json, sys
d = json.load(open(sys.argv[1]))
if not d['rows']:
    raise SystemExit('no rows to inject into')
d['rows'][0]['predicted_patchable'] = True
d['predicted_patchable'] = 1
json.dump(d, open(sys.argv[2], 'w'))
print(f"injected one fake admitted row: {d['rows'][0]['key'][:72]}")
PY
  # The scorer's NONZERO EXIT is captured here and asserted below. Printing it
  # inside a pipeline discarded it, so only the JSON verdict was load-bearing.
  python3 "$G/lib/score_subset.py" "$C/${NAME}_injected.json" - \
      "$C/${NAME}_inj_subset.json" > "$C/${NAME}_inj.out" 2>&1
  INJ_RC=$?
  sed 's/^/    /' "$C/${NAME}_inj.out"
  echo "    exit=$INJ_RC  (asserted: non-zero)"
  eval "INJ_RC_$NAME=$INJ_RC"

  # A SMALL SUMMARY IS BANKED. The row files are 40-115 MB and stay out of the
  # repository; these digests plus this script are the provenance.
  python3 - "$C" "$NAME" "$G/evidence/corpus_${NAME}.json" "$G" <<'PY'
import hashlib, json, pathlib, re, sys
C, NAME, OUT, GATE = sys.argv[1:5]
sha = lambda p: hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()

# THE REPLACEABLE SET IS READ FROM THE PREDICTOR, not restated here. If the
# predictor's notion of a replaceable callable changes, this proof follows it
# instead of silently checking the wrong set.
src = pathlib.Path(GATE, 'lib', 'predict_patchable.dart').read_text()
m = re.search(r"const \{([^}]*)\}\.contains\(kind\)", src)
if m is None:
    raise SystemExit('cannot locate the replaceable-kind set in the predictor')
REPLACEABLE = set(re.findall(r"'(\w+)'", m.group(1)))
SCOPE = ('CALL_SITE_SHAPE_UNPROVEN', 'FRONTEND_MATERIALIZATION_UNPROVEN')
pred = json.load(open(f'{C}/{NAME}_predictions.json'))

# PROVE, PER ROW, that both scope reasons apply to EVERY replaceable
# declaration. Presence in the aggregate histogram is not that proof: a reason
# could appear on many rows and still be absent from one, which is exactly the
# row that would then be admissible.
repl = [r for r in pred['rows'] if r['kind'] in REPLACEABLE]
missing = [r['key'] for r in repl
           if not all(c in r['refusal_reasons'] for c in SCOPE)]
non_repl_admitted = [r['key'] for r in pred['rows']
                     if r['kind'] not in REPLACEABLE
                     and r.get('predicted_patchable') is True]
sub = json.load(open(f'{C}/{NAME}_subset.json'))
inl = json.load(open(f'{C}/{NAME}_inlining.json'))
con = json.load(open(f'{C}/{NAME}_contract.json'))
json.dump({
    'schema': 'semantic-map-1/g5-corpus-summary/1',
    'corpus': NAME,
    # DIGEST-BOUND. The row files are 40-115 MB and stay out of the
    # repository, so these SHA-256s are the only thing tying this summary to
    # the products it describes. Without them the summary is an unverifiable
    # assertion about files nobody can check.
    'artifacts': {n: sha(f'{C}/{n}') for n in
                  (f'{NAME}_aot.dill', f'{NAME}_pre.dill', f'{NAME}.aot')},
    'evidence_sha256': {n: sha(f'{C}/{NAME}_{n}.json') for n in
                        ('g1', 'g3', 'g4', 'refs', 'contract', 'inlining',
                         'predictions', 'subset')},
    'evidence_rows': {
        'g1': len(json.load(open(f'{C}/{NAME}_g1.json'))['rows']),
        'g3': len(json.load(open(f'{C}/{NAME}_g3.json'))['rows']),
        'g4': len(json.load(open(f'{C}/{NAME}_g4.json'))['rows']),
        'refs': len(json.load(open(f'{C}/{NAME}_refs.json'))['rows']),
    },
    'declarations': pred['count'],
    'predicted_patchable': pred['predicted_patchable'],
    'refusal_histogram': pred['refusal_histogram'],
    'release_patch_capability': con['release_patch_capability'],
    'release_aot_sha256': con['release_aot_sha256'],
    'route2': {'note_validated': inl['note_validated'],
               'complete_projection': inl['note_complete_projection'],
               'note_section_sha256': inl['diagnostics'].get('note_section_sha256'),
               'records': inl['diagnostics'].get('records'),
               'accounting': inl['accounting'],
               'unprojected_count': inl['unprojected_count']},
    'scope_exclusion_proof': {
        'replaceable_kinds': sorted(REPLACEABLE),
        'scope_reasons': list(SCOPE),
        'replaceable_declarations': len(repl),
        'replaceable_missing_a_scope_reason': len(missing),
        'examples_missing': missing[:5],
        'covers_every_replaceable': not missing,
        'non_replaceable_admitted': len(non_repl_admitted),
    },
    'subset_verdict': sub['verdict'],
    'prediction_set': sub['prediction_set'],
    'behavioral_demonstration': sub['behavioral_demonstration'],
    'coverage_diagnostic_only': sub['coverage_diagnostic_only'],
}, open(OUT, 'w'), indent=2)
PY

  # ---- assertions, per corpus ----
  N=$(jq_ "$C/${NAME}_g1.json" "d['count']")
  want "$NAME: G1 projection is non-empty" True "$(python3 -c "print($N > 0)")"
  # These previously evaluated to True unconditionally -- a vacuous assertion,
  # which is worse than none: it reports coverage it never checked. Each now
  # compares an actual row count.
  want "$NAME: g3 privacy rows produced" True \
       "$(python3 -c "print($(jq_ "$C/${NAME}_g3.json" "len(d['rows'])") > 0)")"
  want "$NAME: g4 retention rows produced" "$N" \
       "$(jq_ "$C/${NAME}_g4.json" "len(d['rows'])")"
  want "$NAME: body-reference rows produced" True \
       "$(python3 -c "print($(jq_ "$C/${NAME}_refs.json" "len(d['rows'])") > 0)")"
  want "$NAME: predictor covered every G1 declaration" "$N" \
       "$(jq_ "$C/${NAME}_predictions.json" "d['count']")"
  want "$NAME: release contract covered every declaration" "$N" \
       "$(jq_ "$C/${NAME}_contract.json" "len(d['rows'])")"
  want "$NAME: reader accounted for every declaration" "$N" \
       "$(jq_ "$C/${NAME}_inlining.json" "d['accounting']['total_g1_rows']")"
  want "$NAME: reader accounting reconciles" True \
       "$(jq_ "$C/${NAME}_inlining.json" "d['accounting']['accounted'] == d['accounting']['total_g1_rows']")"
  want "$NAME: release capability proven from the artifact" PROVEN \
       "$(jq_ "$C/${NAME}_contract.json" "d['release_patch_capability']")"
  want "$NAME: reader bound to that exact AOT" "$(sha "$C/$NAME.aot")" \
       "$(jq_ "$C/${NAME}_inlining.json" "d['diagnostics']['aot_sha256']")"
  want "$NAME: prediction set is EMPTY" EMPTY \
       "$(jq_ "$C/${NAME}_subset.json" "d['prediction_set']")"
  want "$NAME: no demonstration required for an empty set" \
       NOT_REQUIRED_FOR_EMPTY_PREDICTION \
       "$(jq_ "$C/${NAME}_subset.json" "d['behavioral_demonstration']")"
  want "$NAME: subset holds vacuously" SUBSET_HOLDS_VACUOUSLY \
       "$(jq_ "$C/${NAME}_subset.json" "d['verdict']")"
  want "$NAME: an injected admitted row FAILS OPEN" FAIL_OPEN \
       "$(jq_ "$C/${NAME}_inj_subset.json" "d['verdict']")"
  eval "INJ=\$INJ_RC_$NAME"
  want "$NAME: the injected over-claim EXITS NON-ZERO" nonzero \
       "$([ "${INJ:-0}" != 0 ] && echo nonzero || echo zero)"
  want "$NAME: both scope reasons cover EVERY replaceable declaration" True \
       "$(jq_ "$G/evidence/corpus_${NAME}.json" "d['scope_exclusion_proof']['covers_every_replaceable']")"
  want "$NAME: no non-replaceable declaration is admitted" 0 \
       "$(jq_ "$G/evidence/corpus_${NAME}.json" "d['scope_exclusion_proof']['non_replaceable_admitted']")"
  want "$NAME: every corpus product is digest-bound" 8 \
       "$(jq_ "$G/evidence/corpus_${NAME}.json" "len(d['evidence_sha256'])")"
  want "$NAME: coverage is reported as zero of N" "0/$N" \
       "$(jq_ "$C/${NAME}_subset.json" "d['coverage_diagnostic_only'].split(' ')[0]")"


done
} > "$G/evidence/corpora.txt" 2>&1

{
  echo
  echo "ASSERTIONS (${#ASSERTIONS[@]} checked)"
  printf '%s\n' "${ASSERTIONS[@]}"
  echo
  echo "SM1_G5_CORPORA: $([ "$rc" = 0 ] && echo ALL_EMPTY_AND_FAIL_CLOSED || echo FAILED)"
} >> "$G/evidence/corpora.txt"
printf '%s\n' "${ASSERTIONS[@]}"
echo "SM1_G5_CORPORA: $([ "$rc" = 0 ] && echo ALL_EMPTY_AND_FAIL_CLOSED || echo FAILED)"
exit "$rc"
