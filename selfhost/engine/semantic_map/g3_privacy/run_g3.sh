#!/usr/bin/env bash
# cspell:words semantic dill bytecode
# run_g3.sh -- SEMANTIC-MAP-1 / G3 (#52). Privacy domains.
#
# INHERITED, from G0/G1/G2 acceptance:
#   * build from effective Dart tree 7b04b01b (refused otherwise)
#   * the shipped analyzer pin is echoed
#   * DECLARATION_ID stays identity-only; privacy is a separate column
#   * the corpus dill builder serialises on its own lock
#   * THE TRANSCRIPT AND THE JSON COME FROM ONE INVOCATION. G2 learned this the
#     hard way: a transcript left by an earlier run was missing a case the JSON
#     had already scored, and nothing detected it. This script writes its own.
#
# THE CONFOUND RUNS FIRST, AND IT IS FATAL. The guard refusing
# --resolve-private-names-in-library on a platform library is uncommitted-but-
# shipped source (G0 confound PLATFORM_LIBRARY_GUARD_IS_UNCOMMITTED). Built from
# a tree that predates it, the platform-library arm passes vacuously. So the
# guard's presence is not assumed, not grepped for and believed -- it is made to
# FIRE, with an anti-vacuity control, before any arm below is trusted.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SM="$(cd -- "$HERE/.." >/dev/null 2>&1 && pwd)"
SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
DT=${DT:-$SRC/flutter/third_party/dart}
DART="$OUT/dart-sdk/bin/dart"
G0C="$SM/g0_freeze/corpus"
G1="$SM/g1_identity"
XC="$HERE/corpus_ext"
EVID="$HERE/evidence"; mkdir -p "$EVID"
TRANSCRIPT="$EVID/g3_privacy.txt"
W=${W:-${TMPDIR:-/tmp}/sm1_g3}

{
rm -rf "$W"; mkdir -p "$W"

EFF=$(python3 -c "import json;print(json.load(open('$SM/g0_freeze/freeze_manifest.json'))['inherited_lineage']['producing_source']['dart']['effective_tree'])")
[[ "$EFF" == "7b04b01bdc10ec990143257f0d28580571c2122f" ]] \
  || { echo "REFUSING: frozen effective tree is $EFF, not 7b04b01b" >&2; exit 2; }
echo "SM1-G3 privacy domains"
echo "  frozen effective tree : $EFF"
echo "  analyzer pin          : $(python3 -c "import json;print(json.load(open('$SM/g0_freeze/freeze_manifest.json'))['analyzer']['shipped_sha256'])")"

echo
echo "--- CONFOUND FIRST: the platform-library guard must be present AND firing ---"
bash "$HERE/lib/assert_guard.sh" | sed 's/^/  /'
GUARD_RC=${PIPESTATUS[0]}
if [[ "$GUARD_RC" != 0 ]]; then
  echo
  echo "  REFUSING TO SCORE. The guard is not proven to fire, so the"
  echo "  platform-library arm would pass vacuously. This is fatal rather than a"
  echo "  finding: 'nothing was granted' and 'the guard never ran' look identical"
  echo "  from the outside."
  echo
  echo "SUMMARY checks_failed=1"
  echo "G3 PRIVACY FAILED"
  exit 1
fi

# BOTH KERNELS. The AOT kernel says what SURVIVED; the pre-AOT kernel is the
# declaration domain. G1 measured that --aot tree-shakes declarations, so the
# AOT kernel alone cannot enumerate the privacy domain -- and "absent" would be
# indistinguishable from "not private".
pre_dill() { # <corpus-dir> <out.dill>
  local P="$W/pre_build"
  rm -rf "$P"; mkdir -p "$P/lib" "$P/.dart_tool"
  cp "$1"/*.dart "$P/lib/"
  printf '{"configVersion":2,"packages":[{"name":"corpus","rootUri":"file://%s/","packageUri":"lib/","languageVersion":"3.9"}]}' "$P" \
    > "$P/.dart_tool/package_config.json"
  "$DART" "$DT/pkg/vm/bin/gen_kernel.dart" --platform "$OUT/vm_platform.dill" \
    --no-aot --packages "$P/.dart_tool/package_config.json" \
    -o "$2" package:corpus/app.dart >/dev/null 2>&1
}

rows_for() { # <corpus-dir> <label>
  bash "$SM/g0_freeze/lib/build_corpus_dill.sh" "$1" "$W/$2.dill" >/dev/null 2>&1 || return 1
  [[ -s "$W/$2.dill" ]] || return 1
  pre_dill "$1" "$W/$2.pre.dill" || return 1
  [[ -s "$W/$2.pre.dill" ]] || return 1
  "$DART" --packages="$DT/.dart_tool/package_config.json" \
    "$HERE/lib/gen_privacy_rows.dart" --dill "$W/$2.dill" \
    --pre-dill "$W/$2.pre.dill" --include package:corpus/ \
    --out "$W/$2.json" >/dev/null 2>&1
}

echo
echo "--- building privacy rows ---"
rows_for "$G0C/base" base || { echo "could not produce base rows" >&2; exit 1; }
for d in "$XC"/*; do
  [[ -d "$d" ]] || continue
  rows_for "$d" "$(basename "$d")" || echo "  WARN $(basename "$d")"
done
for f in "$W"/*.json; do
  echo "  $(basename "$f" .json): $(python3 -c "
import json;d=json.load(open('$f'));print(f\"rows={d['count']} private={d['private_count']} write-collapsed={d['write_capability_collapsed_count']}\")")"
done

# PARITY WITH G1. The identity is RECOMPUTED in this tool, not imported, so the
# two implementations are compared on the same input. Shared code would make the
# check prove nothing.
echo
echo "--- identity parity with G1 (recomputed, not imported) ---"
"$DART" --packages="$DT/.dart_tool/package_config.json" \
  "$G1/lib/gen_declaration_ids.dart" --dill "$W/base.dill" \
  --include package:corpus/ --out "$W/g1_ids.json" >/dev/null 2>&1
python3 - "$W/g1_ids.json" "$W/base.json" <<'PY'
import json, sys
g1 = json.load(open(sys.argv[1])); g3 = json.load(open(sys.argv[2]))
a = {(r['library'], r['owner'], r['kind'], r['name']): r['declaration_id']
     for r in g1['declarations']}
b = {(r['library'], r['owner'], r['kind'], r['name']): r['declaration_id']
     for r in g3['rows']}
common = set(a) & set(b)
bad = [k for k in common if a[k] != b[k]]
print(f'  G1/G3 identity parity : {len(common)} shared declarations, '
      f'{len(bad)} disagreement(s)')
if bad:
    for k in bad[:4]:
        print(f'    DISAGREE {k}: {a[k][:12]} vs {b[k][:12]}')
    raise SystemExit(1)
PY
PARITY=$?

echo
python3 "$HERE/lib/score_g3.py" "$W" "$HERE/EXPECTATIONS_G3.json" \
  "$EVID/g3_privacy.json"
SCORE=$?
[[ "$PARITY" -eq 0 && "$SCORE" -eq 0 ]] || exit 1
} 2>&1 | tee "$TRANSCRIPT"
exit "${PIPESTATUS[0]}"
