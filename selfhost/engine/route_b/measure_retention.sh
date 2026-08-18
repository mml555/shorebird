#!/usr/bin/env bash
# cspell:words dynmod killgate dartaotruntime getsize ljust
#
# measure_retention.sh -- what Route B costs a release, on both axes at once.
#
# Route B charges a release twice, and the two costs are independent:
#
#   1. CALL FORM   -- --patchable_static_calls makes each static call load the
#                     callee's Function and branch through Function.entry_point_
#                     instead of a baked target.
#   2. RETENTION   -- a dynamic interface keeps symbols a future patch might
#                     bind to, instead of tree-shaking them away.
#
# Spike B measured retention alone (+0.93%) against a hand-written three-member
# interface, which is not a shape any release can ship: nobody knows in advance
# which members a patch will touch. This measures the shape a release CAN ship
# -- whole-library retention, generated from the app's own kernel by
# gen_dynamic_interface.dart -- and crosses it with the call form, because a
# release pays both and the sum is what the step 7 veto will judge.
#
# NOTE ON THE ORDER OF OPERATIONS, which is not incidental: the interface is
# generated FROM a kernel, so the kernel gets built twice -- once plain to
# discover the libraries, then again with the interface applied. A real release
# pipeline has the same shape.
#
# This is still a toy program. It is a dial-reading, not the veto.
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
WORK="${WORK:-$(mktemp -d)}"

DART_TREE="$SRC/flutter/third_party/dart"
DART="$OUT/dart-sdk/bin/dart"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
GEN_SNAPSHOT="$OUT/gen_snapshot"
TARGET_URI="package:dynamic_modules/target.dart"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

[ -d "$OUT" ] || die "no build at $OUT"
grep -q 'dart_dynamic_modules = true' "$OUT/args.gn" 2>/dev/null \
  || die "dart_dynamic_modules is not true in $OUT/args.gn"

mkdir -p "$WORK/lib" "$WORK/.dart_tool"
cp "$REPO/selfhost/engine/killgate/target.dart" "$WORK/lib/target.dart"
cat > "$WORK/.dart_tool/package_config.json" <<JSON
{
  "configVersion": 2,
  "packages": [
    {
      "name": "dynamic_modules",
      "rootUri": "file://$WORK/",
      "packageUri": "lib/",
      "languageVersion": "3.9"
    }
  ]
}
JSON

kernel() {  # kernel <out.dill> [--dynamic-interface <yaml>]
  local out="$1"; shift
  "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
    --packages "$WORK/.dart_tool/package_config.json" \
    "$@" -o "$out" "$TARGET_URI" 2>"$out.err" \
    || { cat "$out.err" >&2; die "gen_kernel failed for $out"; }
}

snapshot() {  # snapshot <out.aot> <in.dill> [extra gen_snapshot flags...]
  local out="$1" dill="$2"; shift 2
  # --deterministic so a size delta is a real delta and not build nondeterminism.
  "$GEN_SNAPSHOT" --deterministic "$@" \
    --snapshot_kind=app-aot-elf --elf="$out" "$dill" >/dev/null 2>&1 \
    || die "gen_snapshot failed for $out"
}

note "kernel: no retention (baseline)"
kernel "$WORK/plain.dill"

note "generating a dynamic interface from that kernel"
"$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
  "$HERE/gen_dynamic_interface.dart" \
  --dill "$WORK/plain.dill" --out "$WORK/di_generated.yaml"

# Sweep retention BREADTH rather than reporting one number. The first run of
# this script reported whole-library retention at +405% and that single figure,
# on its own, reads as "Route B is dead". It is not: it says the SDK half of the
# policy cannot be library-scoped. Only a sweep separates those two claims.
note "kernel: app-only retention"
"$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
  "$HERE/gen_dynamic_interface.dart" \
  --dill "$WORK/plain.dill" --no-sdk --out "$WORK/di_app.yaml"
kernel "$WORK/app.dill" --dynamic-interface "$WORK/di_app.yaml"

note "kernel: app + named SDK members (the shipping policy)"
kernel "$WORK/core.dill" --dynamic-interface "$WORK/di_generated.yaml"

note "kernel: app + WHOLE dart:core (the expensive alternative)"
"$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
  "$HERE/gen_dynamic_interface.dart" \
  --dill "$WORK/plain.dill" --sdk-libraries dart:core --out "$WORK/di_whole.yaml"
kernel "$WORK/retained.dill" --dynamic-interface "$WORK/di_whole.yaml"

note "snapshots: each breadth, with and without the call form"
snapshot "$WORK/a_plain.aot"     "$WORK/plain.dill"
snapshot "$WORK/a_plain_cf.aot"  "$WORK/plain.dill"    --patchable_static_calls
snapshot "$WORK/b_app.aot"       "$WORK/app.dill"
snapshot "$WORK/b_app_cf.aot"    "$WORK/app.dill"      --patchable_static_calls
snapshot "$WORK/c_core.aot"      "$WORK/core.dill"
snapshot "$WORK/c_core_cf.aot"   "$WORK/core.dill"     --patchable_static_calls
snapshot "$WORK/d_all.aot"       "$WORK/retained.dill"
snapshot "$WORK/d_all_cf.aot"    "$WORK/retained.dill" --patchable_static_calls

python3 - "$WORK" <<'PY'
import os, sys
w = sys.argv[1]
def size(n): return os.path.getsize(os.path.join(w, n))
base = size('a_plain.aot')
rows = [
    ('none (stock AOT)',            'a_plain.aot', 'a_plain_cf.aot'),
    ('app libraries only',          'b_app.aot',   'b_app_cf.aot'),
    ('app + named SDK members',     'c_core.aot',  'c_core_cf.aot'),
    ('app + WHOLE dart:core',       'd_all.aot',   'd_all_cf.aot'),
]
w0 = max(len(r[0]) for r in rows)
print()
print(f"{'retention breadth'.ljust(w0)}  {'plain':>11} {'vs base':>9}   {'+call form':>11} {'vs base':>9}")
print('-' * (w0 + 46))
for label, plain, cf in rows:
    p, c = size(plain), size(cf)
    print(f"{label.ljust(w0)}  {p:>11,} {(p-base)/base*100:>+8.2f}%   "
          f"{c:>11,} {(c-base)/base*100:>+8.2f}%")
print()
print("Call form alone is the cheap axis. Retention is the expensive one, and")
print("it is expensive in the SDK, not in the app.")
print()
PY

echo "work dir kept: $WORK"
