#!/usr/bin/env bash
# SM1-G6 (#55) -- map schema, identity, versioning and release binding.
#
# A map describes ONE release and must never be applicable to another. This
# builds bound maps for three genuinely different releases, verifies each
# against its own release, and then swaps every binding field independently.
#
# The third release is a REBUILD of the first from the same kernel: identical
# declarations, different AOT bytes. That is the case #55 names -- similarity
# is not identity -- and it is a real artifact here rather than a contrived one,
# because SM1-G5 measured that whole-AOT output is not byte-reproducible.
#
# usage: run_g6.sh <clone-src> <g5-workdir> <corpora-dir>
set -uo pipefail
SRC="${1:?usage: run_g6.sh <clone-src> <g5-workdir> <corpora-dir>}"
W5="${2:?}"
C="${3:?}"
G="$(cd "$(dirname "$0")" && pwd)"
G5="$(cd "$G/../g5_patchability" && pwd)"
S="$SRC/out/host_release_arm64"
W="${TMPDIR:-/tmp}/sm1_g6"; rm -rf "$W"; mkdir -p "$W"
rc=0
ASSERTIONS=()
want() {
  if [ "$2" = "$3" ]; then ASSERTIONS+=("  pass  $1")
  else ASSERTIONS+=("  FAIL  $1 -- got '$3', expected '$2'"); rc=1; fi
}
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
must() {
  local what="$1"; shift
  "$@" || { echo "    PRODUCER FAILED: $what"; PF="${PF}$what; "; rc=1; return 1; }
}
PF=""

MAN="$G5/instrumentation/MANIFEST.json"
DART_REV=$(python3 -c "import json;print(json.load(open('$MAN'))['base']['dart_revision'])")
TREE=$(python3 -c "import json;print(json.load(open('$MAN'))['base']['frozen_effective_tree'])")
GS=$(python3 -c "import json;print(json.load(open('$MAN'))['built']['instrumented_gen_snapshot_sha256_schema6'])")
GEN_SHA=$(sha "$G/lib/gen_bound_map.py")

# facts <name> <kernel> <aot> <out>  -- read from the artifacts, not asserted
facts() {
  python3 - "$1" "$2" "$3" "$4" "$DART_REV" "$TREE" "$GS" "$GEN_SHA" <<'PY'
import hashlib, json, pathlib, sys
name, kernel, aot, out, rev, tree, gs, gen = sys.argv[1:9]
sha = lambda p: hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
kh, ah = sha(kernel), sha(aot)
json.dump({
    'release_name': name,
    'release_id': hashlib.sha256(f'{name}|{kh}|{ah}'.encode()).hexdigest(),
    'release_kernel_hash': kh,
    'release_aot_sha256': ah,
    'compiler': {'dart_revision': rev, 'frozen_effective_tree': tree,
                 'gen_snapshot_sha256': gs},
    'generator_sha256': gen,
}, open(out, 'w'), indent=2)
PY
}

{
echo "SM1-G6 -- map schema, identity, versioning and release binding"
echo "generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by run_g6.sh"
echo
cat <<'TXT'
WHAT IS BOUND

    schema_version
    release_id
    release_kernel_hash
    release_aot_identity              sha256 is the identity; the GNU build id
                                      is recorded but never trusted, because
                                      SM1-G5 measured that it hashes only four
                                      snapshot segments and two different AOTs
                                      can share one
    flutter_dart_compiler_identities  dart revision, frozen tree, gen_snapshot
    generator_identity                the generator and its tool digests
    digest                            over the canonicalized map, excluding
                                      itself

CATEGORIES (SEMANTIC-LINKER-1 vocabulary)

    HOST_IDENTITY      the map does not belong to this release
    MODULE_INTEGRITY   the map itself cannot be trusted

Refusals are decided on STRUCTURED FIELD COMPARISON. SL1 found corrupt bytecode
reporting as "Unable to find class ° in Library:'dart:core'" -- an
import-resolution message for an integrity cause -- so no classification here
reads message text.
TXT
echo
echo "############ 1. THREE RELEASES, AND THEIR OWN FACTS ############"
# A  = the adversarial probe release; A2 = the same kernel rebuilt (identical
# declarations, different bytes); B = LocalSend, a wholly different program.
facts probe        "$W5/release3.dill"      "$W5/app_release.aot"   "$W/facts_a.json"
facts probe_rebuild "$W5/release3.dill"     "$W5/app_release_b.aot" "$W/facts_a2.json"
facts localsend    "$C/localsend_aot.dill"  "$C/localsend.aot"      "$W/facts_b.json"
for f in a a2 b; do
  python3 - "$W/facts_$f.json" <<'PY' | sed 's/^/  /'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"{d['release_name']:15} kernel={d['release_kernel_hash'][:16]} "
      f"aot={d['release_aot_sha256'][:16]}")
PY
done
echo
echo "############ 2. BOUND MAPS ############"
must map-a python3 "$G/lib/gen_bound_map.py" 1 probe "$W5/release3.dill" \
    "$W5/app_release.aot" "$G5/evidence/g1_projection.json" "$MAN" "$G5/lib" \
    "$W/map_a.json"
must map-b python3 "$G/lib/gen_bound_map.py" 1 localsend "$C/localsend_aot.dill" \
    "$C/localsend.aot" "$C/localsend_g1.json" "$MAN" "$G5/lib" "$W/map_b.json"
echo
echo "############ 3. EACH MAP AGAINST ITS OWN RELEASE ############"
python3 "$G/lib/verify_binding.py" "$W/map_a.json" "$W/facts_a.json" "$W/v_a.json"
python3 "$G/lib/verify_binding.py" "$W/map_b.json" "$W/facts_b.json" "$W/v_b.json"
echo
echo "############ 4. EVERY BINDING FIELD, SWAPPED INDEPENDENTLY ############"
# The similarity arm claims the rebuild has IDENTICAL declarations. That is
# CHECKED by building a real map for the rebuild and comparing the declaration
# lists -- an earlier version of this script simply set the flag to True, which
# is the vacuous-assertion pattern this programme keeps catching.
must map-a2 python3 "$G/lib/gen_bound_map.py" 1 probe_rebuild \
    "$W5/release3.dill" "$W5/app_release_b.aot" \
    "$G5/evidence/g1_projection.json" "$MAN" "$G5/lib" "$W/map_a2.json"
python3 - "$W/facts_a2.json" "$W/map_a.json" "$W/map_a2.json" <<'PY'
import json, sys
fa2 = json.load(open(sys.argv[1]))
a = json.load(open(sys.argv[2]))
a2 = json.load(open(sys.argv[3]))
fa2['declarations_identical_to_a'] = a['declarations'] == a2['declarations']
fa2['declaration_count'] = len(a2['declarations'])
json.dump(fa2, open(sys.argv[1], 'w'), indent=2)
print(f"  rebuild declarations identical to A: "
      f"{fa2['declarations_identical_to_a']} "
      f"({fa2['declaration_count']} declarations)")
PY
python3 "$G/lib/falsify_binding.py" "$W/map_a.json" "$W/facts_a.json" \
    "$W/map_b.json" "$W/facts_b.json" "$W" "$W/facts_a2.json"
echo "exit=$?  (asserted: 0)"
echo
echo "############ 5. THE ARMS MUST BE LOAD-BEARING ############"
cat <<'TXT'
  A suite of refusals proves nothing unless it can fail. Each control removes
  ONE check from a copy of the verifier, so each proves the check it names:

    bind removed    -- the release-binding comparisons go, so any map binds to
                       any release. Every identity swap must flip.
    digest removed  -- the digest comparison goes, so a tampered map binds. The
                       tamper-without-re-digest arm must flip, and only it.
TXT
echo
for mode in bind digest; do
  echo "  --- control: $mode ---"
  must "weaken-verifier:$mode" python3 "$G/lib/weaken_verifier.py" \
      "$G/lib/verify_binding.py" "$W/weak_$mode.py" "$mode"
  SM1_VERIFIER="$W/weak_$mode.py" python3 "$G/lib/falsify_binding.py" \
      "$W/map_a.json" "$W/facts_a.json" "$W/map_b.json" "$W/facts_b.json" \
      "$W" "$W/facts_a2.json" 2>&1 | tail -3 | sed 's/^/    /'
done
echo
echo "############ 6. LIMITS ############"
cat <<'TXT'
  Binding detects a map presented against the WRONG RELEASE, and a map whose
  own bytes are corrupt or tampered. It does NOT detect a map that was
  deliberately rewritten AND re-digested -- that is forgery, and defeating it
  needs a signature over the map, which is a signing change and outside this
  lane's boundary.

  Stated because the falsification makes the distinction visible: arms that
  tamper without re-digesting refuse as MODULE_INTEGRITY, while arms that swap
  a field and re-digest refuse as HOST_IDENTITY -- and a swap that re-digests
  AND matches the release would bind. Nothing here claims otherwise.
TXT
} > "$G/evidence/g6_binding.txt" 2>&1

T="$G/evidence/g6_binding.txt"
want 'no producer failed' '' "$PF"
python3 "$G/lib/verify_binding.py" "$W/map_a.json" "$W/facts_a.json" "$W/v_a.json" >/dev/null 2>&1
want 'map A binds to release A' 0 "$?"
python3 "$G/lib/verify_binding.py" "$W/map_b.json" "$W/facts_b.json" "$W/v_b.json" >/dev/null 2>&1
want 'map B binds to release B' 0 "$?"
python3 "$G/lib/verify_binding.py" "$W/map_a.json" "$W/facts_b.json" "$W/v_x.json" >/dev/null 2>&1
want 'map A refuses release B' 1 "$?"
want 'that refusal is HOST_IDENTITY' HOST_IDENTITY \
     "$(python3 -c "import json;print(json.load(open('$W/v_x.json'))['categories'][0])")"
python3 "$G/lib/falsify_binding.py" "$W/map_a.json" "$W/facts_a.json" \
    "$W/map_b.json" "$W/facts_b.json" "$W" "$W/facts_a2.json" >/dev/null 2>&1
want 'every binding field swap refuses' 0 "$?"
want 'the transcript records EVERY_SWAP_REFUSED' 1 \
     "$(grep -c 'SM1_G6_BINDING_FALSIFICATION: EVERY_SWAP_REFUSED' "$T")"
want 'the two releases genuinely differ in kernel hash' differ \
     "$(python3 -c "
import json
a=json.load(open('$W/facts_a.json'));b=json.load(open('$W/facts_b.json'))
print('differ' if a['release_kernel_hash']!=b['release_kernel_hash'] else 'same')")"
want 'the rebuild really has identical declarations' True \
     "$(python3 -c "import json;print(json.load(open('$W/facts_a2.json'))['declarations_identical_to_a'])")"
want 'the rebuild differs in AOT digest but not in kernel' differ-aot-same-kernel \
     "$(python3 -c "
import json
a=json.load(open('$W/facts_a.json'));c=json.load(open('$W/facts_a2.json'))
print('differ-aot-same-kernel' if a['release_aot_sha256']!=c['release_aot_sha256']
      and a['release_kernel_hash']==c['release_kernel_hash'] else 'unexpected')")"
# Control outcomes are asserted EXACTLY, so a control that starts failing the
# wrong number of arms -- or none -- cannot pass as "the control failed".
for mode in bind digest; do
  python3 "$G/lib/weaken_verifier.py" "$G/lib/verify_binding.py" \
      "$W/weak_$mode.py" "$mode" >/dev/null 2>&1
done
B_OUT=$(SM1_VERIFIER="$W/weak_bind.py" python3 "$G/lib/falsify_binding.py" \
    "$W/map_a.json" "$W/facts_a.json" "$W/map_b.json" "$W/facts_b.json" \
    "$W" "$W/facts_a2.json" 2>&1)
want 'removing the binding checks fails the identity arms' 1 "$?"
want 'and fails exactly the ten identity arms' 'arms=19 passed=9 failed=10' \
     "$(echo "$B_OUT" | grep -o 'arms=19 passed=9 failed=10')"
D_OUT=$(SM1_VERIFIER="$W/weak_digest.py" python3 "$G/lib/falsify_binding.py" \
    "$W/map_a.json" "$W/facts_a.json" "$W/map_b.json" "$W/facts_b.json" \
    "$W" "$W/facts_a2.json" 2>&1)
want 'removing the digest check fails the integrity arm' 1 "$?"
want 'and fails exactly that one arm' 'arms=19 passed=18 failed=1' \
     "$(echo "$D_OUT" | grep -o 'arms=19 passed=18 failed=1')"
want 'the weakener refuses a missing anchor' 1 \
     "$(python3 "$G/lib/weaken_verifier.py" "$W/weak_bind.py" /dev/null bind \
        >/dev/null 2>&1; echo $?)"
cp "$W/map_a.json" "$G/evidence/map_probe.json"
cp "$W/v_a.json" "$G/evidence/verify_probe.json"

{
  echo
  echo "ASSERTIONS (${#ASSERTIONS[@]} checked)"
  printf '%s\n' "${ASSERTIONS[@]}"
  echo
  echo "SM1_G6: $([ "$rc" = 0 ] && echo BINDING_ENFORCED || echo FAILED)"
} >> "$T"
printf '%s\n' "${ASSERTIONS[@]}"
echo "SM1_G6: $([ "$rc" = 0 ] && echo BINDING_ENFORCED || echo FAILED)"
exit "$rc"
