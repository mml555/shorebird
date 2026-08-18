#!/usr/bin/env bash
# cspell:words dartaotruntime prepass nonaot ljust getsize precommitted PRECOMMITTED wonderous rjust hashlib hexdigest
#
# policy_arms.sh -- price P1/P2/P3 on a real app, on BOTH axes.
#
# The private-retention policy is a product decision with two halves, and a script
# that reported one of them would decide it by omission:
#
#   COST                 interface / snapshot deltas per arm
#   AUTHORITY EXPANSION  the capability manifest per arm -- what a future patch can
#                        actually reach, including what it can CONSTRUCT
#
# The four decision dimensions were precommitted in PARITY.md §3 BEFORE this script
# existed: patchability gained, binary cost, capability breadth, skipped/refused
# coverage. None of them is the criterion alone, and "smallest binary" or "largest
# reach" must not become the criterion once the numbers are visible.
#
# WHY A DEDICATED SCRIPT rather than another axis in measure_real_app.sh: that harness
# already crosses library breadth x private-class breadth x enumeration source, and its
# arms are about the MECHANISM. These arms are about POLICY, they need the capability
# manifest that measure_real_app.sh knows nothing about, and they must all share one
# pinned app state so the only difference between them is `--policy`.
#
# EVERY ARM USES --private-dill. That is not a variable here: without it the private
# enumeration reads the tree-shaken prepass, and on a real app it emits names the
# annotator cannot resolve (`get:_file` for ThrottledSaveLoadMixin) which fails the
# whole interface. Correctness first, then policy.
#
#   APP=~/compat-corpus/wonderous \
#   ENTRY=package:wonders/main.dart \
#   APP_PREFIX=package:wonders/ policy_arms.sh
#
# Defaults to the airgap fixture, which is a MECHANISM fixture: it has no TFA-dead
# privates, so its arms will differ little and the vacuity note below will say so.
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
RB="$(cd "$HERE/.." >/dev/null 2>&1 && pwd)"
REPO="$(cd "$RB/../../.." >/dev/null 2>&1 && pwd)"
APP="${APP:-$REPO/selfhost/fixtures/airgap_app}"
ENTRY="${ENTRY:-package:airgap_probe/main.dart}"
APP_PREFIX="${APP_PREFIX:-package:airgap_probe/}"
WORK="${WORK:-$(mktemp -d)}"

DART_TREE="$SRC/flutter/third_party/dart"
DART="$OUT/dart-sdk/bin/dart"
KERNEL_PKGS="--packages=$DART_TREE/.dart_tool/package_config.json"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
PLATFORM="$OUT/flutter_patched_sdk/platform_strong.dill"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }

[ -f "$PLATFORM" ] || die "no Flutter platform dill at $PLATFORM"
[ -d "$APP" ] || die "no app at $APP"

kernel() { # kernel <out.dill> [extra gen_kernel args...]
  local out="$1"; shift
  (cd "$APP" && "$DART" "$GEN_KERNEL" --platform "$PLATFORM" \
    --target flutter --aot --tfa \
    --packages .dart_tool/package_config.json "$@" \
    -o "$out" "$ENTRY") >/dev/null 2>&1 || return 1
}
snap() { # snap <out.aot> <in.dill>
  "$OUT/gen_snapshot" --deterministic --patchable_static_calls \
    --snapshot_kind=app-aot-elf --elf="$1" "$2" >/dev/null 2>&1 || return 1
}

# ---------------------------------------------------------------------------
# PROVENANCE FIRST. A recorded number that cannot be tied to what produced it is a
# number someone will later have to re-earn.
note "provenance"
{
  echo "app           : $APP"
  echo "entry         : $ENTRY"
  echo "app prefix    : $APP_PREFIX"
  if git -C "$APP" rev-parse HEAD >/dev/null 2>&1; then
    echo "app commit    : $(git -C "$APP" rev-parse HEAD)"
    echo "app dirty     : $(git -C "$APP" status --porcelain | wc -l | tr -d ' ') file(s)"
  fi
  echo "pubspec.lock  : $(shasum -a 256 "$APP/pubspec.lock" 2>/dev/null | cut -d' ' -f1)"
  echo "engine tree   : $SRC"
  echo "gen_snapshot  : $(shasum -a 256 "$OUT/gen_snapshot" | cut -d' ' -f1)"
  echo "platform dill : $(shasum -a 256 "$PLATFORM" | cut -d' ' -f1)"
  echo "generator     : $(shasum -a 256 "$RB/gen_dynamic_interface.dart" | cut -d' ' -f1)"
} | tee "$WORK/provenance.txt" | sed 's/^/    /'

# ---------------------------------------------------------------------------
# ONE PINNED APP STATE, shared by every arm. The prepass and the import kernel are
# built ONCE: if each arm rebuilt them, an arm difference could come from a rebuild
# rather than from its policy.
note "shared kernels (built once, so the only per-arm difference is --policy)"
kernel "$WORK/prepass.dill" || die "prepass failed"
kernel "$WORK/import.dill" --no-aot --no-link-platform || die "import kernel failed"
snap "$WORK/base.aot" "$WORK/prepass.dill" || die "baseline snapshot failed"
baseBytes=$(stat -f%z "$WORK/base.aot")
echo "    baseline snapshot: $baseBytes bytes (no retention)"

# ---------------------------------------------------------------------------
for pol in p1 p2 p3; do
  note "arm $pol"
  di="$WORK/di_$pol.yaml"; mf="$WORK/mf_$pol.json"

  # shellcheck disable=SC2086
  "$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" \
    --dill "$WORK/prepass.dill" --private-dill "$WORK/import.dill" \
    --include "$APP_PREFIX" --policy "$pol" \
    --out "$di" --manifest "$mf" 2>&1 | sed -n 's/^/    /p'

  if kernel "$WORK/rel_$pol.dill" --dynamic-interface "$di"; then
    if snap "$WORK/arm_$pol.aot" "$WORK/rel_$pol.dill"; then
      echo "    snapshot: $(stat -f%z "$WORK/arm_$pol.aot") bytes"
    else
      echo "SNAPSHOT-FAILED" > "$WORK/arm_$pol.failed"
      echo "    snapshot: FAILED"
    fi
  else
    # A policy that cannot produce a buildable release is a RESULT, not an error:
    # it removes that policy from the candidate set, which is what the arms are for.
    echo "KERNEL-FAILED" > "$WORK/arm_$pol.failed"
    echo "    release kernel: DOES NOT BUILD"
  fi
done

# ---------------------------------------------------------------------------
note "results"
python3 - "$WORK" "$baseBytes" <<'PY'
import json, os, sys
w, base = sys.argv[1], int(sys.argv[2])
arms = ['p1', 'p2', 'p3']

def size(p):
    return os.path.getsize(os.path.join(w, p)) if os.path.exists(os.path.join(w, p)) else None

print()
print('TABLE 1 - COST')
print(f"  {'arm':4}  {'interface':>10}  {'snapshot':>12}  {'vs baseline':>12}")
print('  ' + '-' * 44)
for a in arms:
    di = size(f'di_{a}.yaml')
    aot = size(f'arm_{a}.aot')
    if aot is None:
        why = 'DOES NOT BUILD'
        if os.path.exists(os.path.join(w, f'arm_{a}.failed')):
            why = open(os.path.join(w, f'arm_{a}.failed')).read().strip()
        print(f'  {a:4}  {di or 0:>10,}  {why:>12}  {"n/a":>12}')
        continue
    print(f'  {a:4}  {di:>10,}  {aot:>12,}  {(aot-base)/base*100:>+11.2f}%')

print()
print('TABLE 2 - AUTHORITY EXPANSION (the capability manifest)')
hdr = ('arm', 'top', 'static', 'instance', 'classes', 'implicitCtor', 'refused')
print('  ' + '  '.join(h.rjust(12) for h in hdr))
print('  ' + '-' * 96)
for a in arms:
    mfp = os.path.join(w, f'mf_{a}.json')
    if not os.path.exists(mfp):
        continue
    c = json.load(open(mfp))['counts']
    row = (a, c['privateTopLevelCallable'], c['privateStaticsCallable'],
           c['privateInstanceCallable'], c['privateClassesConstructible'],
           c['implicitlyConstructible'], c['refused'])
    print('  ' + '  '.join(str(v).rjust(12) for v in row))

# THE VACUITY GATE, same discipline as measure_real_app.sh: arms that produced
# identical interfaces priced nothing, and saying so beats reporting a delta of zero
# as though it were a finding.
print()
import hashlib
digests = {}
for a in arms:
    p = os.path.join(w, f'di_{a}.yaml')
    if os.path.exists(p):
        digests[a] = hashlib.sha256(open(p, 'rb').read()).hexdigest()[:12]
print('INTERFACE DIGESTS:', ' '.join(f'{a}={d}' for a, d in digests.items()))
dupes = [a for a in digests if list(digests.values()).count(digests[a]) > 1]
if dupes:
    print(f'  VACUOUS PAIR(S): {sorted(dupes)} produced identical interfaces --')
    print('  those arms priced nothing relative to each other.')
else:
    print('  all arms differ; each delta prices a real difference.')

print()
print('THE FOUR PRECOMMITTED DIMENSIONS (PARITY.md §3) - none is the criterion alone:')
print('  1 patchability gained   2 binary cost   3 capability breadth   4 skipped/refused')
PY

echo
echo "work dir kept: $WORK"
