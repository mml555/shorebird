#!/usr/bin/env bash
#
# run_site.sh -- 2B.1c-SITE. Is a super site's fileOffset a CROSS-VERSION
# identity, or only stable across optimization of one source version?
#
# The 0015 intrinsic takes the offset the analyzer read from the PATCHED kernel
# and searches the RELEASE import kernel's original body for a
# SuperMethodInvocation at that same offset. That is only sound if the offset
# means the same thing in both source versions.
#
# `s2b1/run_2b1.sh` could not have caught this: it authors its own replacement
# against the UNPATCHED source and points at that source's own site, so release
# and patch are the same body there.
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
WORK="${WORK:-$(mktemp -d)}"
RELEASE_SRC="${RELEASE_SRC:-$HERE/../s2b1c/base.dart}"
PATCH_SRC="${PATCH_SRC:-$HERE/../s2b1c/patched.dart}"

DART_TREE="$SRC/flutter/third_party/dart"
DART="$OUT/dart-sdk/bin/dart"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
URI=package:dynamic_modules/target.dart
mkdir -p "$WORK/lib" "$WORK/.dart_tool"
cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$WORK/",
    "packageUri": "lib/", "languageVersion": "3.9" } ] }
JSON

build() { # <src> <out> <mode...>
  cp "$1" "$WORK/lib/target.dart"
  ( cd "$WORK" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
      "${@:3}" --packages .dart_tool/package_config.json -o "$WORK/$2" "$URI" ) >/dev/null 2>&1
}
sites() { # <src> <dill>
  "$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
    "$HERE/../s2b0/dump_sites.dart" "$1" "$OUT/vm_platform.dill" \
    package:dynamic_modules/ "$2" | grep '^{' || true
}

build "$RELEASE_SRC" release_import.dill --no-aot --no-link-platform
build "$PATCH_SRC"   patched_noaot.dill  --no-aot --no-link-platform
build "$PATCH_SRC"   patched_aot.dill    --aot

sites "$RELEASE_SRC" "$WORK/release_import.dill" > "$WORK/release.jsonl"
sites "$PATCH_SRC"   "$WORK/patched_noaot.dill"  > "$WORK/pnoaot.jsonl"
sites "$PATCH_SRC"   "$WORK/patched_aot.dill"    > "$WORK/paot.jsonl"

python3 - "$WORK" <<'PY'
import json, os, sys
w = sys.argv[1]

def load(name):
    out = {}
    for line in open(os.path.join(w, name)):
        d = json.loads(line)
        out.setdefault((d['site'], d['member']), []).append(d['fileOffset'])
    return out

rel, pn, pa = load('release.jsonl'), load('pnoaot.jsonl'), load('paot.jsonl')
print('%-34s %10s %10s %10s' % ('site', 'RELEASE', 'PATCH', 'PATCH'))
print('%-34s %10s %10s %10s' % ('', 'import', 'no-AOT', 'AOT'))
print('-' * 68)
keys = sorted(set(rel) | set(pn) | set(pa))
opt_stable = True
cross_stable = True
for k in keys:
    r = rel.get(k, ['-'])[0]
    a = pn.get(k, ['-'])[0]
    b = pa.get(k, ['-'])[0]
    print('%-34s %10s %10s %10s' % ('%s super.%s' % k, r, a, b))
    if a != b:
        opt_stable = False
    if r != a:
        cross_stable = False

print()
print('offset stable across OPTIMIZATION (patched no-AOT vs patched AOT): %s'
      % ('YES' if opt_stable else 'NO'))
print('offset stable across SOURCE VERSION (release vs patch)          : %s'
      % ('YES' if cross_stable else 'NO'))
print()
if opt_stable and not cross_stable:
    print('FINDING: fileOffset is stable across optimization of ONE source')
    print('version, and is NOT a cross-version site identity.')
    print()
    print('So the 0015 rule -- take the offset from the patched kernel and')
    print('find the site at that offset in the RELEASE body -- is unsound. In')
    print('this specimen the offsets simply do not match and the compiler')
    print('refuses, which is safe. The hazard is a program where they DO')
    print('coincide: the compiler would then verify the argument shape of a')
    print('DIFFERENT call site than the one being lowered.')
    sys.exit(1)
if cross_stable:
    print('The offsets happen to match in this specimen. That is a property of')
    print('this fixture, not of the product, and must not be relied on.')
    sys.exit(1)
print('UNEXPECTED: offsets differ across optimization. Investigate before')
print('drawing any conclusion about cross-version identity.')
sys.exit(1)
