#!/usr/bin/env bash
# cspell:words dartaotruntime prepass callsite CALLSITES targetable defaultdict dstnode noart nobind noedge nolib unmutated exactcls
#
# p41_release_probe_gate.sh -- the gate for route_b_release_probe, including the
# mutation table from P41_RELEASE_PROBE_SPEC.md §7.
#
# A probe that cannot fail falsely certifies a release as patchable, so every
# guard is mutation-checked: break the guard, and a specific fixture must be
# LET THROUGH. A mutation that changes nothing means the guard was decoration.
#
# PRECOMMIT -- fixed before running.
#
# BASELINE, correct binding, unmutated probe:
#   | target                        | result                           |
#   |-------------------------------|----------------------------------|
#   | foldOpaque                    | ONE_OR_MORE_QUALIFYING_CALLSITES |
#   | foldConst                     | ZERO_QUALIFYING_CALLSITES        |
#   | deadBranch                    | ONE_OR_MORE_QUALIFYING_CALLSITES |  <- permanent control
#   | foldOpaque under a WRONG library | TARGET_NOT_FOUND              |
#
#   deadBranch is the control that keeps the claim honest: a surviving call site
#   that never executes. If it ever classifies as anything but GREEN, or if the
#   wording anywhere calls a green result "reachable", this gate fails.
#
# BINDING (spec §5) -- each must refuse, and refuse for the stated reason:
#   no --binding / missing file / wrong probe_revision / wrong artifact digest /
#   wrong cell_id  ->  ARTIFACT_BINDING_MISMATCH for EVERY target
#
# PROFILE (spec §8):
#   garbage JSON, reordered node_fields, leftover edges -> PROFILE_INVALID
#   target Function absent   -> TARGET_NOT_FOUND, NOT zero-callsites
#   target identity doubled  -> TARGET_AMBIGUOUS, NOT arbitrary first-match
#
# MUTATIONS OF THE PROBE -- required failure in parentheses:
#   count tear-off pools as callers   (a no-real-call fixture passes)
#   count unowned pools as callers    (deliberately ambiguous evidence passes)
#   drop library scoping              (a wrong-library target resolves)
#   drop the edges-consumed check     (a structurally broken profile is read)
#
# Host only. No device, no mint.
#
#   probes/p41_release_probe_gate.sh
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
RB=${RB:-"$(cd "$HERE/.." >/dev/null 2>&1 && pwd)"}
WORK=${WORK:-$(mktemp -d)}

if [ "${SELF_SNAPSHOT:-}" != "1" ]; then
  SNAP=$(mktemp); cat "${BASH_SOURCE[0]}" > "$SNAP"
  SELF_SNAPSHOT=1 WORK="$WORK" RB="$RB" exec bash "$SNAP" "$@"
fi

DART_TREE=$SRC/flutter/third_party/dart
DART=$OUT/dart-sdk/bin/dart
KERNEL_PKGS="--packages=$DART_TREE/.dart_tool/package_config.json"
GEN_KERNEL=$DART_TREE/pkg/vm/bin/gen_kernel.dart
GEN_SNAPSHOT=$OUT/gen_snapshot
PKGS_DIR=$DART_TREE/third_party/pkg/core/pkgs
PROBE=$RB/release_probe.dart
LIB=package:dynamic_modules/container_target.dart

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1));
  else echo "  FAIL  $1"; echo "        got : $2"; echo "        want: $3"
    fail=$((fail+1)); fi; }

[ -x "$DART" ] || die "no host dart at $DART"
[ -f "$PROBE" ] || die "no probe at $PROBE"
echo "work: $WORK"

# ---- the specimen release --------------------------------------------------
mkdir -p "$WORK/lib" "$WORK/.dart_tool"
cp "$RB/packaging/container_target.dart" "$WORK/lib/container_target.dart"
python3 - "$WORK/lib/container_target.dart" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace("void _state(String when) =>", """String foldConst() => 1 > 0 ? 'CST' : 'X';

String foldOpaque() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OPQ' : 'X';

String deadBranch(String x) =>
    DateTime.now().millisecondsSinceEpoch >= 0 ? 'DBR-$x' : 'X';

// Referenced but never invoked: an observation point for what a tear-off with
// no real call site looks like. The mutation rows do not depend on this shape.
String tearOffOnly() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'TOF' : 'X';
final List<Function> _refs = <Function>[tearOffOnly];

// A member of a library-PRIVATE class. The profile mangles the class name too
// (`_Priv@12345`), and an exact class-name comparison reported
// TARGET_NOT_FOUND for every such member -- failing closed, but refusing the
// shape P1 proved on device. Found 2026-08-26 by the P6 obfuscation arm.
class _Priv {
  @pragma('vm:never-inline')
  String privTarget() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'PRV' : 'X';
}

String _specimenLine() {
  final live = '${foldOpaque()}/${foldConst()}/${_Priv().privTarget()}';
  if (DateTime.now().millisecondsSinceEpoch < 0) {
    return '$live/${deadBranch('never')}';
  }
  return '$live/${_refs.length}';
}

void _state(String when) =>""", 1)
s = s.replace("print('$when alpha=${alpha()} beta=${beta()}');",
              "print('$when alpha=${alpha()} beta=${beta()} spec=${_specimenLine()}');", 1)
p.write_text(s)
PY
cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$WORK/", "packageUri": "lib/",
    "languageVersion": "3.9" },
  { "name": "crypto", "rootUri": "file://$PKGS_DIR/crypto", "packageUri": "lib/",
    "languageVersion": "3.4" },
  { "name": "typed_data", "rootUri": "file://$PKGS_DIR/typed_data",
    "packageUri": "lib/", "languageVersion": "3.4" } ] }
JSON
SDK='dart:core#print,dart:core#DateTime.now,dart:core#DateTime.get:millisecondsSinceEpoch'
cd "$WORK"

note "the specimen release, in the iOS release shape"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o prepass.dill "$LIB" >/dev/null
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot \
  --no-link-platform --packages .dart_tool/package_config.json \
  -o import.dill "$LIB" >/dev/null
# shellcheck disable=SC2086
"$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill prepass.dill \
  --private-dill import.dill --policy p2 --out di.yaml --manifest m.json \
  --sdk-members "$SDK" >/dev/null 2>&1
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
  -o release.dill "$LIB" >/dev/null
"$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-assembly \
  --assembly=app.S --write-v8-snapshot-profile-to=profile.json release.dill
ART=$(shasum -a 256 app.S | cut -d' ' -f1)
KERN=$(shasum -a 256 release.dill | cut -d' ' -f1)
DI=$(shasum -a 256 di.yaml | cut -d' ' -f1)
echo "    artifact $(echo "$ART" | cut -c1-16)  kernel $(echo "$KERN" | cut -c1-16)"

# The release writes this beside the profile. Nothing else may be trusted to
# say which artifact the profile describes.
cat > binding.json <<JSON
{ "profile_format_revision": "v8-snapshot-profile/gen_snapshot",
  "probe_revision": 1,
  "cell_id": "93a375665d637f999bbff028488301a510bb611e",
  "release_artifact_sha256": "$ART",
  "release_kernel_sha256": "$KERN",
  "dynamic_interface_sha256": "$DI" }
JSON

# ---- helpers ---------------------------------------------------------------
result() { # <probe.dart> <profile> <binding> <artifact-sha> <target> [extra...]
  local probe=$1 prof=$2 bind=$3 art=$4 tgt=$5; shift 5
  "$DART" "$probe" --profile "$prof" --binding "$bind" --artifact-sha256 "$art" \
    --target "$tgt" "$@" 2>/dev/null \
    | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print("NO_JSON"); raise SystemExit
print(d["targets"][0]["result"])'
}
evidence() { # same args -> the evidence line
  local probe=$1 prof=$2 bind=$3 art=$4 tgt=$5; shift 5
  "$DART" "$probe" --profile "$prof" --binding "$bind" --artifact-sha256 "$art" \
    --target "$tgt" "$@" 2>/dev/null \
    | python3 -c 'import json,sys
d=json.load(sys.stdin); e=d["targets"][0]["evidence"]
print(" ".join(f"{k}={v}" for k,v in e.items() if k!="callers"),
      "callers=" + ",".join(e["callers"]) if e["callers"] else "")'
}

# ---- BASELINE --------------------------------------------------------------
note "BASELINE -- the permanent control table"
for t in foldOpaque:ONE_OR_MORE_QUALIFYING_CALLSITES \
         foldConst:ZERO_QUALIFYING_CALLSITES \
         deadBranch:ONE_OR_MORE_QUALIFYING_CALLSITES; do
  n=${t%%:*}; want=${t#*:}
  echo "    $n: $(evidence "$PROBE" profile.json binding.json "$ART" "$LIB#$n")"
  check "$n" "$(result "$PROBE" profile.json binding.json "$ART" "$LIB#$n")" "$want"
done
echo "    tearOffOnly (observation, not a precommitted row):"
echo "      $(evidence "$PROBE" profile.json binding.json "$ART" "$LIB#tearOffOnly")"
echo "      $(result "$PROBE" profile.json binding.json "$ART" "$LIB#tearOffOnly")"

note "a member of a PRIVATE CLASS resolves -- the class name is mangled too"
echo "    $(evidence "$PROBE" profile.json binding.json "$ART" "$LIB#_Priv.privTarget")"
check "_Priv.privTarget resolves despite the mangled class name" \
  "$(result "$PROBE" profile.json binding.json "$ART" "$LIB#_Priv.privTarget")" \
  ONE_OR_MORE_QUALIFYING_CALLSITES

note "IDENTITY is not a bare selector"
check "same member, wrong library -> TARGET_NOT_FOUND" \
  "$(result "$PROBE" profile.json binding.json "$ART" \
      'package:dynamic_modules/nope.dart#foldOpaque')" TARGET_NOT_FOUND

# ---- BINDING ---------------------------------------------------------------
note "BINDING -- a profile of artifact A is not evidence about artifact B"
BAD=0000000000000000000000000000000000000000000000000000000000000000
check "wrong artifact digest" \
  "$(result "$PROBE" profile.json binding.json "$BAD" "$LIB#foldOpaque")" \
  ARTIFACT_BINDING_MISMATCH
check "wrong digest still refuses a FOLDED target" \
  "$(result "$PROBE" profile.json binding.json "$BAD" "$LIB#foldConst")" \
  ARTIFACT_BINDING_MISMATCH
python3 -c "
import json
b=json.load(open('binding.json')); b['probe_revision']=999
json.dump(b, open('b_rev.json','w'))
b=json.load(open('binding.json')); b['cell_id']='deadbeef'
json.dump(b, open('b_cell.json','w'))
b=json.load(open('binding.json')); del b['release_artifact_sha256']
json.dump(b, open('b_noart.json','w'))"
check "wrong probe_revision" \
  "$(result "$PROBE" profile.json b_rev.json "$ART" "$LIB#foldOpaque")" \
  ARTIFACT_BINDING_MISMATCH
check "wrong cell_id" \
  "$(result "$PROBE" profile.json b_cell.json "$ART" "$LIB#foldOpaque" \
      --cell-id 93a375665d637f999bbff028488301a510bb611e)" \
  ARTIFACT_BINDING_MISMATCH
check "binding without an artifact digest" \
  "$(result "$PROBE" profile.json b_noart.json "$ART" "$LIB#foldOpaque")" \
  ARTIFACT_BINDING_MISMATCH
check "binding file missing entirely" \
  "$(result "$PROBE" profile.json /nonexistent.json "$ART" "$LIB#foldOpaque")" \
  ARTIFACT_BINDING_MISMATCH

# ---- PROFILE surgery -------------------------------------------------------
cat > surgery.py <<'PY'
import json, sys
# Surgery on a v8 snapshot profile. Nodes are 5-wide, edges 3-wide, and edges
# are laid out per node IN NODE ORDER -- so a node appended LAST may have its
# edges appended last, and nothing earlier shifts.
mode, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
target = sys.argv[4] if len(sys.argv) > 4 else None
d = json.load(open(src))
meta = d['snapshot']['meta']
NT = meta['node_types'][0]; ET = meta['edge_types'][0]
NF = len(meta['node_fields']); EF = len(meta['edge_fields'])
nodes, edges, strings = d['nodes'], d['edges'], d['strings']
n = len(nodes) // NF

def find(name, typename='Function'):
    ti = NT.index(typename)
    for i in range(n):
        if nodes[i*NF] == ti and strings[nodes[i*NF+1]] == name:
            return i
    raise SystemExit(f'no {typename} named {name}')

def intern(s):
    if s in strings: return strings.index(s)
    strings.append(s); return len(strings) - 1

def append_node(typename, name, out_edges):
    global n
    nodes.extend([NT.index(typename), intern(name), 900000 + n, 8, len(out_edges)])
    for kind, label, dstnode in out_edges:
        edges.extend([ET.index(kind), intern(label) if label else 0, dstnode * NF])
    n += 1
    d['snapshot']['node_count'] = n
    d['snapshot']['edge_count'] = len(edges) // EF
    return n - 1

if mode == 'garbage':
    open(dst, 'w').write('{not json at all')
    raise SystemExit
if mode == 'reorder-fields':
    meta['node_fields'] = ['name', 'type', 'id', 'self_size', 'edge_count']
elif mode == 'leftover-edges':
    edges.extend([0, 0, 0])
    d['snapshot']['edge_count'] = len(edges) // EF
elif mode == 'rename-target':
    # The identity disappears. Absence of the Function is NOT absence of a call
    # site, and the probe must say so.
    i = find(target); nodes[i*NF+1] = intern(target + '$$gone')
elif mode == 'double-target':
    i = find(target)
    owner = None
    pos = sum(nodes[k*NF+4] for k in range(i))
    for k in range(nodes[i*NF+4]):
        et, nm, to = edges[(pos+k)*EF:(pos+k)*EF+EF]
        if ET[et] == 'property' and strings[nm] == 'owner_': owner = to // NF
    append_node('Function', target, [('property', 'owner_', owner)])
elif mode == 'add-unowned-pool':
    # An ObjectPool referencing the target, owned by no Code at all: evidence
    # that cannot be attributed to a caller.
    append_node('ObjectPool', 'Unnamed [ObjectPool] (nil)',
                [('element', None, find(target))])
elif mode == 'add-tearoff-pool':
    pool = append_node('ObjectPool', 'Unnamed [ObjectPool] (nil)',
                       [('element', None, find(target))])
    append_node('Code', f'[Optimized] [tear-off] {target}',
                [('property', 'object_pool_', pool)])
else:
    raise SystemExit(f'unknown mode {mode}')
json.dump(d, open(dst, 'w'))
PY

note "PROFILE -- a profile that cannot be trusted is not absence"
python3 surgery.py garbage profile.json p_garbage.json
python3 surgery.py reorder-fields profile.json p_reorder.json
python3 surgery.py leftover-edges profile.json p_leftover.json
python3 surgery.py rename-target profile.json p_gone.json foldOpaque
python3 surgery.py double-target profile.json p_double.json foldOpaque
check "garbage JSON -> PROFILE_INVALID" \
  "$(result "$PROBE" p_garbage.json binding.json "$ART" "$LIB#foldOpaque")" \
  PROFILE_INVALID
check "node_fields reordered -> PROFILE_INVALID" \
  "$(result "$PROBE" p_reorder.json binding.json "$ART" "$LIB#foldOpaque")" \
  PROFILE_INVALID
check "leftover edges -> PROFILE_INVALID" \
  "$(result "$PROBE" p_leftover.json binding.json "$ART" "$LIB#foldOpaque")" \
  PROFILE_INVALID
check "target Function absent -> TARGET_NOT_FOUND, not zero-callsites" \
  "$(result "$PROBE" p_gone.json binding.json "$ART" "$LIB#foldOpaque")" \
  TARGET_NOT_FOUND
check "identity doubled -> TARGET_AMBIGUOUS, not first-match" \
  "$(result "$PROBE" p_double.json binding.json "$ART" "$LIB#foldOpaque")" \
  TARGET_AMBIGUOUS

# ---- MUTATIONS OF THE PROBE ------------------------------------------------
# Ambiguous and tear-off-only evidence, built on the FOLDED target so the
# unmutated probe must still refuse it. If a mutation lets it through, the guard
# was load-bearing; if it does not, the guard was decoration.
python3 surgery.py add-unowned-pool profile.json p_unowned.json foldConst
python3 surgery.py add-tearoff-pool profile.json p_tearoff.json foldConst

note "the unmutated probe refuses both synthetic shapes"
check "unowned pool alone -> still ZERO" \
  "$(result "$PROBE" p_unowned.json binding.json "$ART" "$LIB#foldConst")" \
  ZERO_QUALIFYING_CALLSITES
check "tear-off pool alone -> still ZERO" \
  "$(result "$PROBE" p_tearoff.json binding.json "$ART" "$LIB#foldConst")" \
  ZERO_QUALIFYING_CALLSITES

mutate() { # <name> <python edit> ; writes $WORK/m_<name>.dart
  local name=$1 edit=$2
  python3 - "$PROBE" "$WORK/m_$name.dart" "$edit" <<'PY'
import pathlib, sys
src, dst, edit = sys.argv[1], sys.argv[2], sys.argv[3]
s = pathlib.Path(src).read_text()
a, b = edit.split('=>>')
if a not in s: raise SystemExit(f'mutation anchor missing: {a[:60]}')
pathlib.Path(dst).write_text(s.replace(a, b, 1))
PY
}

note "MUTATION -- count tear-off pools as callers"
mutate tearoff "      ev.tearoffPools++;=>>      ev.callerOwnedPools++;"
check "mutant lets a tear-off-only shape through" \
  "$(result "$WORK/m_tearoff.dart" p_tearoff.json binding.json "$ART" "$LIB#foldConst")" \
  ONE_OR_MORE_QUALIFYING_CALLSITES

note "MUTATION -- count unowned pools as callers"
mutate unowned "      ev.unownedPools++;=>>      ev.callerOwnedPools++;"
check "mutant lets ambiguous evidence through" \
  "$(result "$WORK/m_unowned.dart" p_unowned.json binding.json "$ART" "$LIB#foldConst")" \
  ONE_OR_MORE_QUALIFYING_CALLSITES

note "MUTATION -- compare the owning class name EXACTLY"
mutate exactcls "    if (!_nameMatches(p.nameOf(owner), id.owningClassName)) continue;=>>    if (p.nameOf(owner) != id.owningClassName) continue;"
check "mutant cannot find a member of a private class" \
  "$(result "$WORK/m_exactcls.dart" profile.json binding.json "$ART" "$LIB#_Priv.privTarget")" \
  TARGET_NOT_FOUND
check "  ...and still finds a TOP-LEVEL target, so the mutation is narrow" \
  "$(result "$WORK/m_exactcls.dart" profile.json binding.json "$ART" "$LIB#foldOpaque")" \
  ONE_OR_MORE_QUALIFYING_CALLSITES

note "MUTATION -- drop library scoping"
mutate nolib "    if (lib == null || p.nameOf(lib) != id.library) continue;=>>    if (lib == null) continue;"
check "mutant resolves a WRONG-library target" \
  "$(result "$WORK/m_nolib.dart" profile.json binding.json "$ART" \
      'package:dynamic_modules/nope.dart#foldOpaque')" \
  ONE_OR_MORE_QUALIFYING_CALLSITES

note "MUTATION -- drop the edges-consumed check"
mutate noedge "    if (pos != edges.length) {
      return (null, 'edges array has \${edges.length - pos} bytes left over');
    }=>>    if (false) { return (null, 'unreachable'); }"
check "mutant reads a structurally broken profile" \
  "$(result "$WORK/m_noedge.dart" p_leftover.json binding.json "$ART" "$LIB#foldOpaque")" \
  ONE_OR_MORE_QUALIFYING_CALLSITES

note "MUTATION -- drop the artifact-digest comparison"
mutate nobind "  if (declaredArtifact.toLowerCase() != artifactSha.toLowerCase()) {=>>  if (false) {"
check "mutant accepts a profile of a DIFFERENT artifact" \
  "$(result "$WORK/m_nobind.dart" profile.json binding.json "$BAD" "$LIB#foldOpaque")" \
  ONE_OR_MORE_QUALIFYING_CALLSITES

# ---- WORDING ---------------------------------------------------------------
# Semantic overclaim is this project's recurring failure mode, so it gets a test.
note "WORDING -- a green result must never be called reachability"
# Ad-hoc blacklisting of phrasings does not work -- the first attempt flagged
# the two lines that FORBID the overclaim. The principle instead: every mention
# of reachability in these documents must carry a denial or a prohibition, and
# the bounding sentence must actually be present.
python3 - "$PROBE" "$RB/P41_RELEASE_PROBE_SPEC.md" > wording.txt <<'PY'
import re, sys, pathlib
GUARD = re.compile(r'\bnot\b|\bnever\b|\bno\b|defect|fail|forbid|unreachable|'
                   r'rather than|instead of|survival|!=|\u2260', re.I)
bad = []
for f in sys.argv[1:]:
    for i, line in enumerate(pathlib.Path(f).read_text().splitlines(), 1):
        if 'reachab' in line.lower() and not GUARD.search(line):
            bad.append(f'{f}:{i}:{line.strip()[:90]}')
print('\n'.join(bad) if bad else 'none')
PY
check "every mention of reachability carries a denial" "$(cat wording.txt)" none
check "the bounding sentence is present in the spec" \
  "$(grep -c "does not mean runtime control flow will reach it" \
      "$RB/P41_RELEASE_PROBE_SPEC.md")" 1
check "the probe source states it too" \
  "$(grep -c "does NOT answer whether runtime control flow reaches" "$PROBE")" 1
check "deadBranch stays GREEN (restated after every mutation)" \
  "$(result "$PROBE" profile.json binding.json "$ART" "$LIB#deadBranch")" \
  ONE_OR_MORE_QUALIFYING_CALLSITES

note "PASS=$pass FAIL=$fail"
echo "work dir kept: $WORK"
[ "$fail" -eq 0 ]
