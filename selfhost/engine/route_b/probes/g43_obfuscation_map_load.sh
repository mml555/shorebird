#!/usr/bin/env bash
# cspell:words dartaotruntime obfuscat
#
# g43_obfuscation_map_load.sh -- can gen_snapshot LOAD an obfuscation map, and is
# the result actually consistent?
#
# WHY THIS EXISTS. An obfuscated Route B release is unpatchable today: the CLI
# correctly passes the RELEASE's own map to the patch build
# (`--obfuscate --load-obfuscation-map=<map> --strip`), and our gen_snapshot
# advertises `--save-obfuscation-map` ONLY, so the AOT step exits 255 long before
# Route B is reached. That is a KNOWN ENGINE GAP, not a device question.
#
# THE FLAG ALONE IS NOT THE GATE. Accepting the flag and then renaming
# inconsistently would be worse than refusing it: the patch would build, ship, and
# bind to names the release does not have. So this probe measures the SEMANTICS:
#
#   a. the flag is advertised at all;
#   b. a second compilation that LOADS map A reproduces every rename in A;
#   c. no two distinct identifiers in the second map share an obfuscated name.
#
# (c) IS THE CURSOR QUESTION, MADE MEASURABLE. The saved state carries a rename
# cursor (`name_`) alongside the pairs, but the JSON map carries PAIRS ONLY.
# `NewAtomicRename` loops only while a candidate is an IDENTITY rename -- it does
# not reject a name already in use as a VALUE -- so a load that leaves the cursor
# at zero restarts at `a` and can hand two distinct identifiers the same obfuscated
# name. Nothing in the reference binary's strings mentions a cursor, so this is a
# real risk rather than a hypothetical one.
#
# THE MAP FORMAT, measured from a real 629 KB map our own engine produced for
# release 35 (`airgap_app/build/shorebird/obfuscation_map.json`): a FLAT JSON ARRAY
# of strings, even length, consecutive [original, renamed] pairs -- 39,660 entries,
# and it does contain empty-string pairs, which a parser must tolerate rather than
# reject. That is the input contract, and it agrees with the reference binary's
# error strings ("expected '['", "expected '\"'", "odd number of entries").
#
# exit 0  the flag exists AND both semantic properties hold
# exit 1  the flag exists but a semantic property FAILED -- worse than absence
# exit 2  NOT RUNNABLE: the flag does not exist yet (the H4 work is unstarted)
# exit 3  usage/environment
set -uo pipefail

OUT=${OUT:-/Volumes/build/route-b/flutter/engine/src/out/host_release_arm64}
SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
DART_TREE=$SRC/flutter/third_party/dart
WORK=${WORK:-$(mktemp -d)}

GEN_SNAPSHOT=$OUT/gen_snapshot
DART=$OUT/dart-sdk/bin/dart
GEN_KERNEL=$DART_TREE/pkg/vm/bin/gen_kernel.dart
PLATFORM=$OUT/vm_platform.dill

pass=0; fail=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "  PASS  $1 -> $2"; pass=$((pass+1));
  else echo "  FAIL  $1: got '$2', want '$3'"; fail=$((fail+1)); fi
}
die() { echo "ERROR: $*" >&2; exit 3; }

[ -x "$GEN_SNAPSHOT" ] || die "no gen_snapshot at $GEN_SNAPSHOT"
[ -x "$DART" ] || die "no dart at $DART"
[ -f "$PLATFORM" ] || die "no vm_platform.dill at $PLATFORM"

echo "G4.3: does gen_snapshot load an obfuscation map, consistently?"
echo

# --- a. the flag ------------------------------------------------------------
echo "1. is the flag advertised?"
help=$("$GEN_SNAPSHOT" --help 2>&1)
if printf '%s' "$help" | grep -q -- "--load-obfuscation-map"; then
  echo "  PASS  --load-obfuscation-map is advertised"
  pass=$((pass+1))
else
  echo "  ABSENT  --load-obfuscation-map is not advertised"
  printf '%s' "$help" | grep -o -- "--save-obfuscation-map=[^ ]*" | head -1 |
    sed 's/^/          (only /; s/$/ exists)/'
  echo
  echo "NOT RUNNABLE, and that is a finding rather than a failure: the semantic"
  echo "arms below cannot be constructed until the flag exists. This is H4's whole"
  echo "purpose -- see selfhost/plans/H4-gen-snapshot-obfuscation-map.md, whose"
  echo "steps 1-2 recovered the contract from the previous pin's fork binary."
  echo "Do NOT read this as 'obfuscated patching is broken but close': nothing"
  echo "about consistency has been measured at all."
  exit 2
fi

# --- the specimen -----------------------------------------------------------
mkdir -p "$WORK/m"
cat > "$WORK/m/main.dart" <<'DART'
// Enough distinct private identifiers that a rename COLLISION is likely if the
// cursor is not restored: the second compilation restarts its candidate sequence
// at `a` and can reissue a name the loaded map already spent.
class _Alpha { int _one = 1; int _two = 2; String _three() => '3'; }
class _Beta  { int _four = 4; int _five = 5; String _six() => '6'; }
class _Gamma { int _seven = 7; int _eight = 8; String _nine() => '9'; }
void main() {
  print(_Alpha()._one + _Beta()._four + _Gamma()._seven);
  print('${_Alpha()._three()}${_Beta()._six()}${_Gamma()._nine()}');
}
DART

"$DART" "$GEN_KERNEL" --platform "$PLATFORM" --aot \
  -o "$WORK/m/app.dill" "$WORK/m/main.dart" >/dev/null 2>&1 ||
  die "gen_kernel failed"

snap() { # <name> <extra gen_snapshot args...>
  local name="$1"; shift
  "$GEN_SNAPSHOT" --snapshot_kind=app-aot-elf --obfuscate --strip \
    --elf="$WORK/m/$name.aot" "$@" "$WORK/m/app.dill" >"$WORK/m/$name.log" 2>&1
}

echo
echo "2. compile twice: save A, then LOAD A while saving B"
snap first --save-obfuscation-map="$WORK/m/A.json" ||
  { echo "  FAIL  the save-only compilation failed"; sed -n '1,5p' "$WORK/m/first.log"; exit 1; }
snap second --load-obfuscation-map="$WORK/m/A.json" \
            --save-obfuscation-map="$WORK/m/B.json" ||
  { echo "  FAIL  the load compilation failed"; sed -n '1,5p' "$WORK/m/second.log"; exit 1; }
check "both maps written" \
  "$([ -s "$WORK/m/A.json" ] && [ -s "$WORK/m/B.json" ] && echo yes || echo no)" yes

# --- b + c. the semantics ---------------------------------------------------
python3 - "$WORK/m/A.json" "$WORK/m/B.json" <<'PY' > "$WORK/m/verdict.txt"
import json, sys
def pairs(p):
    d = json.load(open(p))
    assert isinstance(d, list) and len(d) % 2 == 0, "not an even-length array"
    # Empty-string pairs occur in real maps and carry no information.
    return {d[i]: d[i+1] for i in range(0, len(d), 2) if d[i]}
A, B = pairs(sys.argv[1]), pairs(sys.argv[2])
kept = [k for k in A if k in B and B[k] == A[k]]
drift = [(k, A[k], B[k]) for k in A if k in B and B[k] != A[k]]
missing = [k for k in A if k not in B]
inv = {}
for k, v in B.items():
    inv.setdefault(v, []).append(k)
collisions = {v: ks for v, ks in inv.items() if len(ks) > 1}
print(f"a_pairs={len(A)} b_pairs={len(B)} kept={len(kept)} drift={len(drift)} missing={len(missing)}")
print(f"collisions={len(collisions)}")
for k, a, b in drift[:5]:
    print(f"  DRIFT {k}: A={a} B={b}")
for v, ks in list(collisions.items())[:5]:
    print(f"  COLLISION {v} <- {ks}")
PY
cat "$WORK/m/verdict.txt"
drift=$(sed -n 's/.*drift=\([0-9]*\).*/\1/p' "$WORK/m/verdict.txt" | head -1)
collisions=$(sed -n 's/^collisions=\([0-9]*\).*/\1/p' "$WORK/m/verdict.txt" | head -1)

echo
echo "3. the semantics that make the flag worth having"
check "every rename in A survives into B (consistency)" "${drift:-?}" 0
check "no two identifiers share an obfuscated name (the cursor question)" \
  "${collisions:-?}" 0

echo
echo "--------------------------------------------------"
echo "obfuscation-map load: $pass passed, $fail failed"
echo "work dir kept: $WORK"
echo
echo "WHAT A GREEN RUN LICENSES: a patch build can reproduce the release's naming,"
echo "so an obfuscated release becomes patchable AT ALL. It says nothing about the"
echo "device arm -- that needs a mint, an obfuscated release and a patch on R1."
[ "$fail" -eq 0 ] || exit 1
