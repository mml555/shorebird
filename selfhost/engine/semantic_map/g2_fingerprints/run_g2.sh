#!/usr/bin/env bash
# cspell:words semantic dill
# run_g2.sh -- SEMANTIC-MAP-1 / G2 (#51). ABI and body fingerprints.
#
# INHERITED, from G0/G1 acceptance:
#   * build from effective Dart tree 7b04b01b (refused otherwise)
#   * the shipped analyzer pin is echoed
#   * DECLARATION_ID / ABI_FINGERPRINT / BODY_FINGERPRINT stay separate
#   * the corpus dill builder serialises on its own lock; runs here are sequential
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SM="$(cd -- "$HERE/.." >/dev/null 2>&1 && pwd)"
SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
DT="$SRC/flutter/third_party/dart"
DART="$OUT/dart-sdk/bin/dart"
G0C="$SM/g0_freeze/corpus"
G1="$SM/g1_identity"
XC="$HERE/corpus_ext"
EVID="$HERE/evidence"; mkdir -p "$EVID"
TRANSCRIPT="$EVID/g2_fingerprints.txt"
W=${W:-${TMPDIR:-/tmp}/sm1_g2}
rm -rf "$W"; mkdir -p "$W"

# THE TRANSCRIPT AND THE JSON MUST COME FROM ONE RUN.
# score_g2.py writes evidence/g2_fingerprints.json at a fixed path, but the
# transcript used to depend on the CALLER redirecting stdout. That is how the
# two artifacts drifted: a transcript written by an earlier invocation was
# missing a case the JSON had already scored, and nothing detected it. The
# script now writes its own transcript from the same invocation, so a
# transcript that disagrees with the JSON is no longer reachable.
{
EFF=$(python3 -c "import json;print(json.load(open('$SM/g0_freeze/freeze_manifest.json'))['inherited_lineage']['producing_source']['dart']['effective_tree'])")
[[ "$EFF" == "7b04b01bdc10ec990143257f0d28580571c2122f" ]] \
  || { echo "REFUSING: frozen effective tree is $EFF, not 7b04b01b" >&2; exit 2; }
echo "SM1-G2 ABI and body fingerprints"
echo "  frozen effective tree : $EFF"
echo "  analyzer pin          : $(python3 -c "import json;print(json.load(open('$SM/g0_freeze/freeze_manifest.json'))['analyzer']['shipped_sha256'])")"

# BOTH KERNELS. The ABI cannot be read from the AOT kernel -- --aot strips
# parameters -- so a pre-AOT kernel is built from the same source at the same
# stable path, and the tool is handed both.
pre_dill() { # <corpus-dir> <out.dill>
  local P="$W/pre_build"
  rm -rf "$P"; mkdir -p "$P/lib" "$P/.dart_tool"
  cp "$1"/*.dart "$P/lib/"
  printf '{"configVersion":2,"packages":[{"name":"corpus","rootUri":"file://%s/","packageUri":"lib/","languageVersion":"3.9"}]}' "$P" \
    > "$P/.dart_tool/package_config.json"
  # --no-aot ONLY. Adding --no-link-platform leaves dart:core references
  # unbound, and kernel throws inside InstanceInvocation.visitChildren:
  #   Reference to dart:core::num::@methods::+ is not bound to an AST node
  # The body walk has to traverse those nodes, so the platform must be linked.
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
    "$HERE/lib/gen_map_rows.dart" --dill "$W/$2.dill" --pre-dill "$W/$2.pre.dill" \
    --include package:corpus/ --out "$W/$2.json" >/dev/null 2>&1
}

rows_for "$G0C/base" base || { echo "could not produce base rows" >&2; exit 1; }
for d in "$G0C"/mutants/*; do rows_for "$d" "$(basename "$d")" || echo "  WARN $(basename "$d")"; done
for d in "$XC"/*;            do rows_for "$d" "$(basename "$d")" || echo "  WARN $(basename "$d")"; done

# PARITY WITH G1. The identity is recomputed in this tool rather than imported,
# so the two implementations are compared on the same input. Shared code would
# make this check prove nothing -- the reasoning coverage/parity.sh applies to
# the reference tooling.
"$DART" --packages="$DT/.dart_tool/package_config.json" \
  "$G1/lib/gen_declaration_ids.dart" --dill "$W/base.dill" \
  --include package:corpus/ --out "$W/g1_ids.json" >/dev/null 2>&1
python3 - "$W/g1_ids.json" "$W/base.json" <<'PY'
import json, sys
g1 = json.load(open(sys.argv[1])); g2 = json.load(open(sys.argv[2]))
a = {(r['library'], r['owner'], r['kind'], r['name']): r['declaration_id']
     for r in g1['declarations']}
b = {(r['library'], r['owner'], r['kind'], r['name']): r['declaration_id']
     for r in g2['rows']}
common = set(a) & set(b)
bad = [k for k in common if a[k] != b[k]]
print(f'  G1/G2 identity parity : {len(common)} shared declarations, '
      f'{len(bad)} disagreement(s)')
if bad:
    for k in bad[:4]:
        print(f'    DISAGREE {k}: {a[k][:12]} vs {b[k][:12]}')
    raise SystemExit(1)
if set(a) - set(b) or set(b) - set(a):
    print(f'  note: G1 names {len(set(a)-set(b))} not in G2, G2 names '
          f'{len(set(b)-set(a))} not in G1')
PY
PARITY=$?

python3 "$HERE/lib/score_g2.py" "$W" "$G0C/EXPECTATIONS.json" \
  "$HERE/EXPECTATIONS_G2.json" "$EVID/g2_fingerprints.json"
SCORE=$?
[[ "$PARITY" -eq 0 && "$SCORE" -eq 0 ]] || exit 1
} 2>&1 | tee "$TRANSCRIPT"
exit "${PIPESTATUS[0]}"
