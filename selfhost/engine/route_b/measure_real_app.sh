#!/usr/bin/env bash
# cspell:words dynmod killgate airgap tfa getsize ljust
#
# measure_real_app.sh -- Route B step 7, size half, on a REAL Flutter app.
#
# Every size number before this one came from a toy program: a few hundred
# lines, one library, no framework. Those are dial-readings. This one is the
# veto: the airgap fixture is a real Flutter app (469 libraries in its kernel,
# 25 MB of it), compiled against the Flutter platform dill with TFA on, exactly
# as a release is.
#
# WHAT IT CANNOT TELL YOU. This snapshots for the macOS host, not iOS -- the
# iOS engine port has not happened. Absolute bytes are therefore not an iOS
# release size; the DELTAS are the transferable part, since both arms compile
# the same kernel with the same compiler and differ only in the flags.
#
# Frame time is not measured here at all and cannot be from a snapshot: it needs
# the app running on a device. That half of the step 7 veto is open.
#
# Prerequisite: the Flutter platform dill in the Route B tree --
#   ninja -C out/host_release_arm64 flutter_patched_sdk/platform_strong.dill
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../../.." >/dev/null 2>&1 && pwd)"
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
note() { echo "==> $*"; }

[ -f "$PLATFORM" ] || die "no Flutter platform dill; build flutter_patched_sdk/platform_strong.dill first"
[ -d "$APP" ] || die "no app at $APP"

kernel() { # kernel <out.dill> [extra gen_kernel args...]
  local out="$1"; shift
  (cd "$APP" && "$DART" "$GEN_KERNEL" --platform "$PLATFORM" \
    --target flutter --aot --tfa \
    --packages .dart_tool/package_config.json "$@" \
    -o "$out" "$ENTRY") >/dev/null 2>&1 || die "gen_kernel failed for $out"
}
snap() { # snap <out.aot> <in.dill> [flags...]
  local out="$1" dill="$2"; shift 2
  "$OUT/gen_snapshot" --deterministic "$@" \
    --snapshot_kind=app-aot-elf --elf="$out" "$dill" >/dev/null 2>&1 \
    || die "gen_snapshot failed for $out"
}

note "kernel: no retention"
kernel "$WORK/app.dill"

note "interfaces: app-only, and the naive all-libraries policy"
"$DART" "$KERNEL_PKGS" "$HERE/gen_dynamic_interface.dart" \
  --dill "$WORK/app.dill" --include "$APP_PREFIX" --out "$WORK/di_app.yaml"
"$DART" "$KERNEL_PKGS" "$HERE/gen_dynamic_interface.dart" \
  --dill "$WORK/app.dill" --out "$WORK/di_all.yaml"

note "kernels with retention"
kernel "$WORK/app_app.dill" --dynamic-interface "$WORK/di_app.yaml"
kernel "$WORK/app_all.dill" --dynamic-interface "$WORK/di_all.yaml"

note "snapshots"
snap "$WORK/base.aot" "$WORK/app.dill"
snap "$WORK/cf.aot"   "$WORK/app.dill"     --patchable_static_calls
snap "$WORK/app.aot"  "$WORK/app_app.dill" --patchable_static_calls
snap "$WORK/all.aot"  "$WORK/app_all.dill" --patchable_static_calls

python3 - "$WORK" <<'PY'
import os, sys
w = sys.argv[1]
size = lambda n: os.path.getsize(os.path.join(w, n))
base = size('base.aot')
rows = [
    ('baseline (stock AOT)',                    'base.aot'),
    ('+ call form',                             'cf.aot'),
    ('+ call form + app-only retention',        'app.aot'),
    ('+ call form + ALL libraries retained',    'all.aot'),
]
width = max(len(r[0]) for r in rows)
print()
print(f"{'configuration'.ljust(width)}  {'bytes':>12}  {'vs baseline':>12}")
print('-' * (width + 30))
for label, f in rows:
    s = size(f)
    print(f'{label.ljust(width)}  {s:>12,}  {(s-base)/base*100:>+11.2f}%')
print()
print('The shipping policy is the third row. The fourth is what a generator')
print('that retained every library would have cost -- kept measurable so the')
print('policy stays a decision rather than a default.')
PY

echo "work dir kept: $WORK"
