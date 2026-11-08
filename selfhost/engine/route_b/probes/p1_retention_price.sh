#!/usr/bin/env bash
# cspell:words dartaotruntime prepass nonaot ljust getsize memberctor
#
# p1_retention_price.sh -- what does separating CLASS IDENTITY from CONSTRUCTION
# authority cost a release?
#
# `probes/p1_dead_allocatability.sh` established the mechanism: a bare `class:`
# item under `callable:` grants a private class's PUBLIC CONSTRUCTORS, because
# upstream's `_Annotator.visitClass` walks `node.constructors` through
# `_visitPublicMembers`. It also established the fix that works -- name the
# class's MEMBERS individually and emit no bare class item (Cfix3 attaches and
# reads privates; Cfix4 refuses construction) -- and that a constructor can be
# opted back in EXACTLY, `member: ''` for the unnamed one (C6).
#
# What is not established is the PRICE. Naming members individually is more
# interface entries than one class item; the question is whether it is also more
# RETENTION, and that is a snapshot question.
#
# THREE POLICIES, everything else identical:
#
#   current      bare private `class:` items                      (today)
#   member       no bare private class item; every non-constructor
#                member of those classes named explicitly
#   memberctor   member, plus EVERY constructor named explicitly
#                -- the upper bound, not a proposal: it prices the
#                   worst case where every class needs construction
#
# TWO AXES, because a release pays both and this repo has been burned by
# reporting one: snapshot size WITHOUT and WITH `--patchable_static_calls`.
#
# THE VACUITY GATE, inherited from measure_real_app.sh and it is the reason that
# script exists in the shape it does: A COST ARM MUST PROVE ITS TREATMENT CHANGED
# THE THING BEING PRICED BEFORE IT REPORTS A DELTA. If the three interfaces come
# out with the same counts, there is no experiment and +0.00% means nothing.
#
# WHICH IS NOW THIS PROBE'S OWN STATE, and that is the correct outcome rather
# than a defect: `gen_dynamic_interface.dart` stopped emitting bare private
# `class:` items on 2026-08-25 -- the change this probe was written to price --
# so "current" and "member-only" are the same interface and the gate refuses to
# report a delta. It is kept as the record of the measurement that licensed the
# change, and it still prices the transition against a generator that predates
# it. `probes/p1_generator_capability_gate.sh` is what gates the emission now.
#
# Sizes are host-arm64, not iOS. The DELTAS transfer; the absolute bytes do not.
#
# THREE SCALE POINTS, because the first two understate the bookkeeping:
#
#   --toy    container_target.dart: 2 private classes. A dial-reading.
#   --real   the airgap Flutter fixture, TFA on, 469-library kernel. A real
#            PROGRAM -- but its own app code has only 1 private constructor and
#            19 private-class members, so it prices realism, not breadth.
#   --synth  200 generated private classes x (2 ctors + 4 members). Prices the
#            SHAPE: does explicit enumeration cost grow with private-class count?
#
# The framework-wide variant (every library's privates, not just the app's) is
# NOT a fourth scale point: measure_real_app.sh already recorded that arm as
# "does not build" under the current policy, so there is nothing to compare.
#
#   probes/p1_retention_price.sh [--toy | --real | --synth | --both | --all]
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
# Kept overridable so the self-snapshot below can pass the real locations
# through: once this file is re-run from a temp copy, `$0` no longer says
# where the repo is.
HERE="${HERE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)}"
RB="${RB:-$(cd "$HERE/.." >/dev/null 2>&1 && pwd)}"
REPO="${REPO:-$(cd "$RB/../../.." >/dev/null 2>&1 && pwd)}"
WORK="${WORK:-$(mktemp -d)}"

DART_TREE="$SRC/flutter/third_party/dart"
DART="$OUT/dart-sdk/bin/dart"
KERNEL_PKGS="--packages=$DART_TREE/.dart_tool/package_config.json"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
GEN_SNAPSHOT="$OUT/gen_snapshot"
PKGS_DIR="$DART_TREE/third_party/pkg/core/pkgs"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }
WHICH="${1:---both}"

# RUN FROM A SNAPSHOT OF THIS FILE. The real arm takes minutes, and bash re-reads
# a running script from a byte offset -- so editing this file mid-run makes the
# shell resume at the wrong place and execute garbage. That happened twice while
# this probe was being written: both times the table had already printed and
# matched a clean re-run, but the tail of the log was nonsense. Cheap to prevent.
if [ "${P1_PRICE_SNAPSHOT:-}" != 1 ]; then
  mkdir -p "$WORK"
  cp "$0" "$WORK/$(basename "$0")"
  P1_PRICE_SNAPSHOT=1 WORK="$WORK" HERE="$HERE" RB="$RB" REPO="$REPO" \
    exec bash "$WORK/$(basename "$0")" "$@"
fi

[ -x "$DART" ] || die "no host dart at $DART"
echo "work: $WORK"

# ------------------------------------------------------------------ transform
# Rewrite a generated interface into one of the three policies, using the kernel
# as the authority on which members are constructors -- a name cannot say
# (`_mk` could be either), and `dump_private_members.dart` asks the kernel.
transform() { # <in.yaml> <members.txt> <mode> <out.yaml>
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import re, sys
src, members_file, mode, dst = sys.argv[1:5]
lines = open(src).read().splitlines()

by_class = {}
for line in open(members_file).read().splitlines():
    if not line.strip():
        continue
    lib, cls, kind, name = line.split('|', 3)
    by_class.setdefault((lib, cls), {'ctor': [], 'member': []})[kind].append(name)

out, i, dropped, classes = [], 0, 0, []
while i < len(lines):
    m = re.match(r"\s*class: '(_[^']*)'\s*$", lines[i])
    nxt = lines[i + 1] if i + 1 < len(lines) else ''
    if m and not re.match(r'\s*member:', nxt):
        # A BARE private class item. `- library: X` is the line before it.
        libLine = re.match(r"\s*- library: '([^']*)'\s*$", out[-1]) if out else None
        if libLine:
            classes.append((libLine.group(1), m.group(1)))
            if mode != 'current':
                out.pop()
                dropped += 1
                i += 1
                continue
    out.append(lines[i]); i += 1

emitted_m = emitted_c = 0
if mode != 'current':
    for lib, cls in classes:
        info = by_class.get((lib, cls))
        if info is None:
            continue
        for name in info['member']:
            out += [f"  - library: '{lib}'", f"    class: '{cls}'",
                    f"    member: '{name}'"]
            emitted_m += 1
        if mode == 'memberctor':
            for name in info['ctor']:
                out += [f"  - library: '{lib}'", f"    class: '{cls}'",
                        f"    member: '{name}'"]
                emitted_c += 1

open(dst, 'w').write('\n'.join(out) + '\n')
print(f"{len(classes)} {emitted_m} {emitted_c} {dropped}")
PY
}

snapshot() { # <out.aot> <in.dill> [flags...]
  local out="$1" dill="$2"; shift 2
  # --deterministic so a size delta is a real delta, not build nondeterminism.
  "$GEN_SNAPSHOT" --deterministic "$@" --snapshot_kind=app-aot-elf \
    --elf="$out" "$dill" >/dev/null 2>&1 || die "gen_snapshot failed for $out"
}

# ---------------------------------------------------------------- one fixture
price() { # <label> <srcdir> <outdir> <entry> <prefix> <platform> <target-args...>
  local label=$1 src=$2 dir=$3 entry=$4 prefix=$5 platform=$6; shift 6
  local targetArgs=("$@")
  # Read from srcdir, write ONLY into outdir, with absolute paths. The real
  # fixture is shared and its package_config.json resolves a sibling package
  # RELATIVELY, so it can neither be copied nor written to -- copying it was the
  # first thing tried and it broke that import.
  mkdir -p "$dir"
  cd "$src"

  kern() { # <out.dill> [extra args...]
    local o="$1"; shift
    "$DART" "$GEN_KERNEL" --platform "$platform" "${targetArgs[@]}" \
      --packages .dart_tool/package_config.json "$@" -o "$dir/$o" "$entry" \
      >"$dir/$o.log" 2>&1 || { sed -n 1,6p "$dir/$o.log" >&2
        die "$label: gen_kernel failed for $o (see $dir/$o.log)"; }
  }

  note "$label: plain kernel (no retention at all)"
  kern plain.dill
  note "$label: non-AOT import kernel (the full private surface)"
  kern import.dill --no-aot --no-link-platform

  note "$label: generated interface (current policy)"
  # shellcheck disable=SC2086
  "$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" \
    --dill "$dir/plain.dill" --private-dill "$dir/import.dill" \
    --include "$prefix" --out "$dir/di_current.yaml" \
    --manifest "$dir/manifest.json" >/dev/null 2>&1 \
    || die "$label: gen_dynamic_interface failed"
  # shellcheck disable=SC2086
  "$DART" $KERNEL_PKGS "$RB/dump_private_members.dart" "$dir/import.dill" \
    "$prefix" > "$dir/members.txt" || die "$label: dump_private_members failed"

  local cur mem mct
  cur=$(transform "$dir/di_current.yaml" "$dir/members.txt" current    "$dir/di_cur.yaml")
  mem=$(transform "$dir/di_current.yaml" "$dir/members.txt" member     "$dir/di_mem.yaml")
  mct=$(transform "$dir/di_current.yaml" "$dir/members.txt" memberctor "$dir/di_mct.yaml")
  echo "    private classes / members emitted / ctors emitted / class items dropped"
  printf '      current    : %s\n      member     : %s\n      memberctor : %s\n' \
    "$cur" "$mem" "$mct"

  # THE VACUITY GATE. Identical interfaces price nothing.
  if cmp -s "$dir/di_cur.yaml" "$dir/di_mem.yaml"; then
    echo "    VACUOUS: current and member-only interfaces are byte-identical."
    echo "    Nothing was priced. Report no delta from this fixture."
    return 1
  fi
  local classCount; classCount=$(echo "$cur" | cut -d' ' -f1)
  if [ "$classCount" -eq 0 ]; then
    echo "    VACUOUS: this fixture has no private classes to reprice."
    return 1
  fi

  note "$label: kernels per policy"
  kern k_cur.dill --dynamic-interface "$dir/di_cur.yaml"
  kern k_mem.dill --dynamic-interface "$dir/di_mem.yaml"
  kern k_mct.dill --dynamic-interface "$dir/di_mct.yaml"

  note "$label: snapshots, each with and without the call form"
  snapshot "$dir/a_stock.aot"    "$dir/plain.dill"
  snapshot "$dir/a_stock_cf.aot" "$dir/plain.dill" --patchable_static_calls
  snapshot "$dir/b_cur.aot"      "$dir/k_cur.dill"
  snapshot "$dir/b_cur_cf.aot"   "$dir/k_cur.dill" --patchable_static_calls
  snapshot "$dir/c_mem.aot"      "$dir/k_mem.dill"
  snapshot "$dir/c_mem_cf.aot"   "$dir/k_mem.dill" --patchable_static_calls
  snapshot "$dir/d_mct.aot"      "$dir/k_mct.dill"
  snapshot "$dir/d_mct_cf.aot"   "$dir/k_mct.dill" --patchable_static_calls

  python3 - "$dir" "$label" <<'PY'
import os, sys
d, label = sys.argv[1], sys.argv[2]
def size(n): return os.path.getsize(os.path.join(d, n))
def yamlBytes(n): return os.path.getsize(os.path.join(d, n))
stock = size('a_stock.aot'); cur = size('b_cur.aot')
rows = [
    ('stock (no retention)', 'a_stock.aot', 'a_stock_cf.aot', None),
    ('current policy',       'b_cur.aot',   'b_cur_cf.aot',   'di_cur.yaml'),
    ('member-only',          'c_mem.aot',   'c_mem_cf.aot',   'di_mem.yaml'),
    ('member + all ctors',   'd_mct.aot',   'd_mct_cf.aot',   'di_mct.yaml'),
]
w = max(len(r[0]) for r in rows)
print()
print(f"  {label}")
print(f"  {'policy'.ljust(w)}  {'yaml B':>9}  {'AOT':>11} {'vs stock':>9} {'vs current':>11}   "
      f"{'+call form':>11} {'vs stock':>9}")
print('  ' + '-' * (w + 68))
for name, plain, cf, yml in rows:
    p, c = size(plain), size(cf)
    yb = f"{yamlBytes(yml):,}" if yml else '-'
    print(f"  {name.ljust(w)}  {yb:>9}  {p:>11,} {(p-stock)/stock*100:>+8.2f}% "
          f"{(p-cur)/cur*100:>+10.2f}%   {c:>11,} {(c-stock)/stock*100:>+8.2f}%")
print()
PY
  cd - >/dev/null
}

# ------------------------------------------------------------------- fixtures
if [ "$WHICH" = --synth ] || [ "$WHICH" = --all ]; then
  S="$WORK/synth"; mkdir -p "$S/lib" "$S/.dart_tool"
  python3 - "$S/lib/synth.dart" <<'GEN'
import sys
n = 200
out = ["// GENERATED by probes/p1_retention_price.sh -- 200 private classes.",
       "// Each body routes through DateTime.now() so TFA cannot fold it to a",
       "// literal, which is the trap container_target.dart documents.", ""]
for i in range(n):
    out += [
        f"class _C{i} {{",
        f"  final String tag;",
        f"  _C{i}() : tag = 'a{i}';",
        f"  _C{i}._mk() : tag = 'b{i}';",
        f"  @pragma('vm:never-inline')",
        f"  String m{i}() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'm' : 'X';",
        f"  @pragma('vm:never-inline')",
        f"  String _p{i}() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'p' : 'X';",
        f"  String get _g{i} => DateTime.now().millisecondsSinceEpoch >= 0 ? 'g' : 'X';",
        f"  final String _f{i} = DateTime.now().millisecondsSinceEpoch >= 0 ? 'f' : 'X';",
        "}",
        "",
    ]
# Every class is mentioned as a TYPE and one is allocated, so none of this is
# dead by construction -- the point is to price the interface, not tree-shaking.
out.append("final List<Object?> _slots = <Object?>[")
out += [f"  _C{i}()," for i in range(n)]
out += ["];", "",
        "void main() => print('classes=${_slots.length}');", ""]
open(sys.argv[1], 'w').write('\n'.join(out))
GEN
  cat > "$S/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "synth", "rootUri": "file://$S/", "packageUri": "lib/",
    "languageVersion": "3.9" } ] }
JSON
  price "SYNTH -- 200 private classes" "$S" "$S" \
    package:synth/synth.dart package:synth \
    "$OUT/vm_platform.dill" --aot || true
fi

if [ "$WHICH" = --toy ] || [ "$WHICH" = --both ] || [ "$WHICH" = --all ]; then
  T="$WORK/toy"; mkdir -p "$T/lib" "$T/.dart_tool"
  cp "$RB/packaging/container_target.dart" "$T/lib/container_target.dart"
  cat > "$T/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$T/", "packageUri": "lib/",
    "languageVersion": "3.9" },
  { "name": "crypto", "rootUri": "file://$PKGS_DIR/crypto", "packageUri": "lib/",
    "languageVersion": "3.4" },
  { "name": "typed_data", "rootUri": "file://$PKGS_DIR/typed_data",
    "packageUri": "lib/", "languageVersion": "3.4" } ] }
JSON
  price "TOY -- container_target.dart" "$T" "$T" \
    package:dynamic_modules/container_target.dart package:dynamic_modules \
    "$OUT/vm_platform.dill" --aot || true
fi

if [ "$WHICH" = --real ] || [ "$WHICH" = --both ] || [ "$WHICH" = --all ]; then
  APP="${APP:-$REPO/selfhost/fixtures/airgap_app}"
  PLATFORM="$OUT/flutter_patched_sdk/platform_strong.dill"
  [ -f "$PLATFORM" ] || die "no Flutter platform dill at $PLATFORM"
  [ -d "$APP" ] || die "no app at $APP"
  R="$WORK/real"; mkdir -p "$R"
  price "REAL -- airgap_app (Flutter, TFA)" "$APP" "$R" \
    package:airgap_probe/main.dart package:airgap_probe/ \
    "$PLATFORM" --target flutter --aot --tfa || true
fi

echo "work dir kept: $WORK"
