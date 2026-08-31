#!/usr/bin/env bash
#
# run_2b0.sh -- D-SUPER-2B.0. The permanent argument-gate control.
#
# Re-measures the three-kernel fact rather than remembering it, then runs the
# SHIPPING gate over both sites, then states the mutation explicitly:
#
#   SOURCE         super.tag('a', 7)   two arguments
#   IMPORT KERNEL  call site           two
#   AOT KERNEL     call site           ZERO   <- TFA specialised the callee
#
# If admission asked the AOT kernel, `super.tag('a', 7)` would be admitted as a
# zero-argument call. That is why the source is the authority.
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../../../../.." >/dev/null 2>&1 && pwd)"
WORK="${WORK:-$(mktemp -d)}"

DART_TREE="$SRC/flutter/third_party/dart"
DART="$OUT/dart-sdk/bin/dart"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
CLI_PKGS="${CLI_PKGS:-$REPO/.dart_tool/package_config.json}"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }
fail=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then printf '  PASS  %-46s %s\n' "$1" "$2"
  else printf '  FAIL  %-46s got %s want %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

[ -x "$DART" ] || die "no host dart at $DART"
[ -f "$CLI_PKGS" ] || die "no package config at $CLI_PKGS"

mkdir -p "$WORK/lib" "$WORK/.dart_tool"
cp "$HERE/arg_specimen.dart" "$WORK/lib/main.dart"
cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "corpus", "rootUri": "file://$WORK/", "packageUri": "lib/",
    "languageVersion": "3.9" } ] }
JSON

note "kernels"
( cd "$WORK" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
    --packages .dart_tool/package_config.json -o aot.dill package:corpus/main.dart ) >/dev/null
( cd "$WORK" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
    --no-aot --no-link-platform \
    --packages .dart_tool/package_config.json -o import.dill package:corpus/main.dart ) >/dev/null

note "argument count PER KERNEL, at the same site"
"$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
  "$HERE/dump_sites.dart" "$WORK/lib/main.dart" "$OUT/vm_platform.dill" \
  package:corpus/ "$WORK/import.dill" "$WORK/aot.dill" | tee "$WORK/sites.txt" | sed 's/^/    /'

read_field() { # <dill-label> <site> <field>
  python3 - "$WORK/sites.txt" "$1" "$2" "$3" <<'PY'
import json, sys
path, dill, site, field = sys.argv[1:5]
cur = None
for line in open(path):
    line = line.strip()
    if line.startswith('==='):
        cur = line.strip('= ')
        continue
    if not line.startswith('{'):
        continue
    d = json.loads(line)
    if cur == dill and d['site'] == site:
        print(d[field]); break
else:
    print('MISSING')
PY
}

ARG_OFF=$(read_field import.dill ArgChild.target fileOffset)
ZERO_OFF=$(read_field import.dill ZeroChild.target fileOffset)

note "the three-kernel fact"
check "import kernel: ArgChild site args"  "$(read_field import.dill ArgChild.target callSiteArgs)" "2"
check "AOT kernel:    ArgChild site args"  "$(read_field aot.dill ArgChild.target callSiteArgs)"    "0"
check "site offset is the SAME in both"    "$ARG_OFF" "$(read_field aot.dill ArgChild.target fileOffset)"

note "the SHIPPING source gate, at those offsets"
gate() { "$DART" --packages="$CLI_PKGS" "$HERE/gate_driver.dart" \
           "$WORK/lib/main.dart" "$1" "$2"; }
check "source gate: super.tag('a', 7)" "$(gate "$ARG_OFF" tag)"    "hasArguments"
check "source gate: super.plain()"     "$(gate "$ZERO_OFF" plain)" "zeroArguments"

note "THE MUTATION, stated rather than implied"
aot_args=$(read_field aot.dill ArgChild.target callSiteArgs)
if [ "$aot_args" = "0" ]; then
  echo "  An admission rule of \"AOT call-site args == 0\" would ADMIT"
  echo "  super.tag('a', 7): the AOT kernel reports $aot_args arguments for it."
  echo "  The source gate refuses the same site. The choice of authority is"
  echo "  therefore load-bearing, not documentary."
else
  echo "  MUTATION VACUOUS: the AOT kernel reports $aot_args args, so this"
  echo "  specimen no longer demonstrates the hole. Investigate before trusting"
  echo "  any result above."
  fail=$((fail+1))
fi

echo
if [ "$fail" -ne 0 ]; then echo "RESULT: $fail check(s) FAILED"; exit 1; fi
echo "RESULT: PASS — source is the authority for argument presence."
echo "work dir kept: $WORK"
