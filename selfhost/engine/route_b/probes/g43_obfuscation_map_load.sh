#!/usr/bin/env bash
# cspell:words dartaotruntime obfuscat bijective
#
# g43_obfuscation_map_load.sh -- can gen_snapshot LOAD an obfuscation map, and
# is the result actually consistent?
#
# WHY THIS EXISTS. An obfuscated Route B release was unpatchable: the CLI
# correctly passes the RELEASE's own map to the patch build
# (`--obfuscate --load-obfuscation-map=<map> --strip`), and our gen_snapshot
# advertised `--save-obfuscation-map` ONLY, so the AOT step exited 255 long
# before Route B was reached. That was a KNOWN ENGINE GAP, not a device
# question. 0008-dart-load-obfuscation-map.patch closes it.
#
# THE FLAG ALONE IS NOT THE GATE. Accepting the flag and then renaming
# inconsistently would be worse than refusing it: the patch would build, ship,
# and bind to names the release does not have.
#
# ---------------------------------------------------------------------------
# WHAT THE FIRST VERSION OF THIS PROBE GOT WRONG, AND HOW WE KNOW
#
# It compiled THE SAME KERNEL TWICE -- save map A, then reload A while saving
# B. Measured on 2026-08-13 against the fixed gen_snapshot, that design CANNOT
# FAIL: every identifier in the second compilation is already present in the
# loaded map, so RenameImpl finds all of them and NewAtomicRename is never
# called. The rename cursor is never consulted. All three cursor modes --
# including the two deliberately broken ones -- reported 0 collisions:
#
#     specimen = same kernel twice
#     mode 1 (correct)      4574 pairs   drift 0   collisions 0
#     mode 0 (no restore)   4574 pairs   drift 0   collisions 0   <-- broken!
#     mode 2 (refuted rule) 4574 pairs   drift 0   collisions 0   <-- broken!
#
# A probe that cannot fail proves nothing. The cursor only matters when the
# second compilation introduces NEW identifiers -- which is exactly what a
# patch build is. So this probe now compiles two DIFFERENT programs: a
# "release" and a "patch" that contains the release's identifiers plus many
# new ones. Against that specimen the same three modes separate cleanly:
#
#     specimen = release, then release+new
#     mode 1 (correct)      5117 pairs   drift 0   collisions  0
#     mode 0 (no restore)   5117 pairs   drift 0   collisions 44
#     mode 2 (refuted rule) 5117 pairs   drift 0   collisions 81
#
# Note DRIFT IS ZERO IN ALL THREE. Consistency (arm c) passes even with a wrong
# cursor, so arm (d) is the only arm that catches this class of bug, and arm
# (e) is the only thing that proves arm (d) is alive.
# ---------------------------------------------------------------------------
#
# THE CURSOR QUESTION, MADE MEASURABLE. The saved state carries a rename cursor
# (`name_`) alongside the pairs, but the JSON map carries PAIRS ONLY.
# `NewAtomicRename` loops only while a candidate is an IDENTITY rename -- it
# does not reject a name already in use as a VALUE -- so a load that leaves the
# cursor at zero restarts at `a` and hands two distinct identifiers the same
# obfuscated name. Route B resolves its target by library URI and name at
# attach time, so that surfaces on device as "function not found" with every
# flag check passing first.
#
# The reconstruction rule is derived in 0008's header: the renames form a
# bijective base-52 numeral (alphabet [a-zA-Z], `name_[0]` least significant),
# so the cursor is the greatest generated value ordered by LENGTH then by
# digits read from the LAST character backwards, over values that are not
# identity renames.
#
# THE MAP FORMAT, measured from a real 629 KB map our own engine produced for
# release 35 (`airgap_app/build/shorebird/obfuscation_map.json`): a FLAT JSON
# ARRAY of strings, even length, consecutive [original, renamed] pairs --
# 39,660 entries -- and it does contain empty-string pairs, which a parser must
# tolerate rather than reject.
#
# RUNTIME: ~10 minutes, dominated by two gen_kernel runs from source.
#
# exit 0  the flag exists AND every semantic property holds AND the probe has
#         demonstrated it can see the failures it claims to test
# exit 1  the flag exists but a property FAILED -- worse than absence
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
check_gt() { # <label> <got> <floor>
  if [ "${2:-0}" -gt "$3" ] 2>/dev/null; then
    echo "  PASS  $1 -> $2"; pass=$((pass+1));
  else echo "  FAIL  $1: got '$2', want > $3"; fail=$((fail+1)); fi
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
  echo "purpose -- see selfhost/plans/H4-gen-snapshot-obfuscation-map.md."
  echo "Do NOT read this as 'obfuscated patching is broken but close': nothing"
  echo "about consistency has been measured at all."
  exit 2
fi

# --- the specimens ----------------------------------------------------------
# A "release" and a "patch" that shares the release's identifiers and adds many
# new ones. The asymmetry is the whole point: only new identifiers consult the
# rename cursor.
mkdir -p "$WORK/m"
gen_specimen() { # <path> <extra-classes>
  local path="$1" extra="$2" i
  : > "$path"
  for i in $(seq 0 19); do
    echo "class _Rel$i { int _rf${i}a = $i; int _rf${i}b = $i; String _rm$i() => '$i'; }" >> "$path"
  done
  if [ "$extra" -gt 0 ]; then
    for i in $(seq 0 $((extra - 1))); do
      echo "class _Pat$i { int _pf${i}a = $i; int _pf${i}b = $i; String _pm$i() => '$i'; }" >> "$path"
    done
  fi
  echo "void main() {" >> "$path"
  for i in $(seq 0 19); do
    echo "  print(_Rel$i()._rf${i}a + _Rel$i()._rf${i}b); print(_Rel$i()._rm$i());" >> "$path"
  done
  if [ "$extra" -gt 0 ]; then
    for i in $(seq 0 $((extra - 1))); do
      echo "  print(_Pat$i()._pf${i}a + _Pat$i()._pf${i}b); print(_Pat$i()._pm$i());" >> "$path"
    done
  fi
  echo "}" >> "$path"
}
gen_specimen "$WORK/m/release.dart" 0
gen_specimen "$WORK/m/patch.dart" 40

for s in release patch; do
  "$DART" "$GEN_KERNEL" --platform "$PLATFORM" --aot \
    -o "$WORK/m/$s.dill" "$WORK/m/$s.dart" >/dev/null 2>&1 ||
    die "gen_kernel failed for $s"
done

snap() { # <name> <dill> <extra gen_snapshot args...>
  local name="$1" dill="$2"; shift 2
  "$GEN_SNAPSHOT" --snapshot_kind=app-aot-elf --obfuscate --strip \
    --elf="$WORK/m/$name.aot" "$@" "$WORK/m/$dill.dill" \
    >"$WORK/m/$name.log" 2>&1
}

echo
echo "2. compile the release, then compile the patch while LOADING the release's map"
snap rel release --save-obfuscation-map="$WORK/m/REL.json" ||
  { echo "  FAIL  the release compilation failed"; sed -n '1,5p' "$WORK/m/rel.log"; exit 1; }
snap pat patch --load-obfuscation-map="$WORK/m/REL.json" \
                --save-obfuscation-map="$WORK/m/PAT.json" ||
  { echo "  FAIL  the patch compilation failed"; sed -n '1,5p' "$WORK/m/pat.log"; exit 1; }
check "both maps written" \
  "$([ -s "$WORK/m/REL.json" ] && [ -s "$WORK/m/PAT.json" ] && echo yes || echo no)" yes

# The falsification runs. Same inputs, deliberately wrong cursor rules.
for mode in 0 2; do
  snap "pat$mode" patch --load-obfuscation-map="$WORK/m/REL.json" \
       --save-obfuscation-map="$WORK/m/PAT$mode.json" \
       --obfuscation_cursor_mode=$mode ||
    { echo "  FAIL  the mode=$mode compilation failed"; exit 1; }
done

# --- the analyzer -----------------------------------------------------------
analyze() { # <released-map> <patched-map> -> "drift=<n> collisions=<n>"
  python3 - "$1" "$2" <<'PY'
import json, sys
def pairs(p):
    d = json.load(open(p))
    assert isinstance(d, list) and len(d) % 2 == 0, "not an even-length array"
    # Empty-string pairs occur in real maps and carry no information.
    return {d[i]: d[i+1] for i in range(0, len(d), 2) if d[i]}
A, B = pairs(sys.argv[1]), pairs(sys.argv[2])
drift = [(k, A[k], B[k]) for k in A if k in B and B[k] != A[k]]
missing = [k for k in A if k not in B]
inv = {}
for k, v in B.items():
    inv.setdefault(v, []).append(k)
collisions = {v: ks for v, ks in inv.items() if len(ks) > 1}
print(f"a_pairs={len(A)} b_pairs={len(B)} drift={len(drift)} missing={len(missing)}")
print(f"collisions={len(collisions)}")
for k, a, b in drift[:5]:
    print(f"  DRIFT {k}: release={a} patch={b}")
for v, ks in list(collisions.items())[:5]:
    print(f"  COLLISION {v} <- {ks}")
PY
}

read_field() { sed -n "s/.*$2=\([0-9]*\).*/\1/p" "$1" | head -1; }

analyze "$WORK/m/REL.json" "$WORK/m/PAT.json" > "$WORK/m/verdict.txt"
cat "$WORK/m/verdict.txt"
drift=$(read_field "$WORK/m/verdict.txt" drift)
collisions=$(sed -n 's/^collisions=\([0-9]*\).*/\1/p' "$WORK/m/verdict.txt" | head -1)

echo
echo "3. the semantics that make the flag worth having"
check "every rename in the release survives into the patch (consistency)" \
  "${drift:-?}" 0
check "no two identifiers share an obfuscated name (the cursor question)" \
  "${collisions:-?}" 0

# --- e. can this probe actually fail? ---------------------------------------
echo
echo "4. CAN THIS PROBE FAIL? (the same measurement, with the cursor sabotaged)"
echo "   A green arm 3 means nothing unless a wrong cursor turns it red."
for mode in 0 2; do
  analyze "$WORK/m/REL.json" "$WORK/m/PAT$mode.json" > "$WORK/m/verdict$mode.txt"
  c=$(sed -n 's/^collisions=\([0-9]*\).*/\1/p' "$WORK/m/verdict$mode.txt" | head -1)
  d=$(read_field "$WORK/m/verdict$mode.txt" drift)
  case $mode in
    0) label="cursor NOT restored (naive)" ;;
    2) label="refuted lowercase-only rule" ;;
  esac
  check_gt "mode=$mode $label -- collisions detected" "${c:-0}" 0
  # Consistency must still hold: this is what proves the collision arm, and not
  # some unrelated breakage, is what mode 0/2 perturbs.
  check "mode=$mode drift stays 0 (only the cursor was sabotaged)" "${d:-?}" 0
done

echo
echo "--------------------------------------------------"
echo "obfuscation-map load: $pass passed, $fail failed"
echo "work dir kept: $WORK"
echo
echo "WHAT A GREEN RUN LICENSES: a patch build can reproduce the release's naming,"
echo "so an obfuscated release becomes patchable AT ALL, and the cursor is restored"
echo "correctly rather than accidentally. It says nothing about the device arm --"
echo "that needs a mint, an obfuscated release and a patch on R1."
[ "$fail" -eq 0 ] || exit 1
