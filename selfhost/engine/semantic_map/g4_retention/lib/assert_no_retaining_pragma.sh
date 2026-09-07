#!/usr/bin/env bash
# cspell:words dartaotruntime dill bytecode dynmod
# assert_no_retaining_pragma.sh -- SM1-G4 (#53) CONFOUND ASSERTION.
#
# Must pass before any withheld-retention arm means anything.
#
# THE CONFOUND, as G0 recorded it (VM_ENTRY_POINT_RETAINS_INDEPENDENTLY):
# `@pragma('vm:entry-point')` retains a symbol regardless of the dynamic-
# interface contract. SL1-G6A's `missing_retained_import` control passed while
# measuring nothing for exactly this reason.
#
# THE SECOND CONFOUND, and it is the sharper one: the two mechanisms are
# INDISTINGUISHABLE DOWNSTREAM. `dynamic_interface_annotator.dart` lowers
# di.yaml's `callable:` list into `@pragma('dyn-module:callable')` annotations,
# and `pkg/vm/lib/transformations/pragma.dart` routes that pragma through the
# SAME `getEntryPointTypeFromOptions` handler as `vm:entry-point` -- the cases
# sit at lines 184 and 253 of that file and both yield a
# `ParsedEntryPointPragma`. "Retained via the dynamic interface" and "retained
# via the pragma" therefore look identical at load, so an arm that cannot say
# WHICH mechanism retained the subject is not measuring the contract.
#
# So this asserts, in order:
#   1. the subject source exists                (existence-guarded)
#   2. built with NO contract, the subject carries NO retaining pragma
#   3. built WITH the contract, the subject carries the CONTRACT pragmas
#      -- proving the contract was actually applied, and by which mechanism
#   4. THE MECHANISM CONTROL: the same host plus vm:entry-point, with `callable`
#      withheld, no longer fails -- i.e. the pragma masks the withheld contract
#      and any arm measured on such a subject would be vacuous
#
# Checks 2 and 3 read the BUILT KERNEL, not the source text. A source grep
# cannot tell a pragma from a comment about a pragma -- this gate's own subject
# explains the confound in its header -- and di.yaml's entries never appear in
# the source at all.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
G="$(cd -- "$HERE/.." >/dev/null 2>&1 && pwd)"
SM="$(cd -- "$G/.." >/dev/null 2>&1 && pwd)"
SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
DT=${DT:-$SRC/flutter/third_party/dart}
DART="$OUT/dart-sdk/bin/dart"
GK="$DT/pkg/vm/bin/gen_kernel.dart"
D2B="$DT/pkg/dart2bytecode/bin/dart2bytecode.dart"
FAILED=0
fail() { echo "  FAILED  $*"; FAILED=1; }
ok()   { echo "  ok      $*"; }

SUBJ="$G/probe/host.dart"
DEMO="$G/probe/host_pragma.dart"

# ---- 1. the subject must EXIST -------------------------------------------
if [[ -f "$SUBJ" && -f "$DEMO" ]]; then
  ok "subject and confound demonstrator exist"
else
  fail "probe sources are MISSING, so every retention result below would be
            vacuous. Fatal rather than a finding."
  echo "PRAGMA_CONFOUND=FATAL_MISSING"; exit 2
fi

W=${W:-${TMPDIR:-/tmp}}/sm1_g4_confound
rm -rf "$W"; mkdir -p "$W/lib" "$W/.dart_tool"
cp "$SUBJ" "$W/lib/host.dart"
cp "$DEMO" "$W/lib/host_pragma.dart"
cp "$G/probe/m_patch.dart" "$W/"
sed 's|package:dynamic_modules/host.dart|package:dynamic_modules/host_pragma.dart|' \
  "$G/probe/m_patch.dart" > "$W/m_patch_pragma.dart"
printf '{"configVersion":2,"packages":[{"name":"dynamic_modules","rootUri":"file://%s/","packageUri":"lib/","languageVersion":"3.9"}]}' "$W" \
  > "$W/.dart_tool/package_config.json"
PKG="$W/.dart_tool/package_config.json"

kernel() { # <out.dill> <uri> [di.yaml]
  if [[ -n "${3:-}" ]]; then
    "$DART" "$GK" --platform "$OUT/vm_platform.dill" --aot --packages "$PKG" \
      --dynamic-interface "$3" -o "$1" "$2" >/dev/null 2>&1
  else
    "$DART" "$GK" --platform "$OUT/vm_platform.dill" --aot --packages "$PKG" \
      -o "$1" "$2" >/dev/null 2>&1
  fi
}
pragmas() { # <dill> <out.json>
  "$DART" --packages="$DT/.dart_tool/package_config.json" "$HERE/dump_pragmas.dart" \
    --dill "$1" --include package:dynamic_modules/ --out "$2" >/dev/null 2>&1
}
count() { python3 -c "import json;print(json.load(open('$1'))['$2'])"; }

# ---- 2. no contract: the subject must carry NO retaining pragma -----------
if kernel "$W/bare.dill" package:dynamic_modules/host.dart && pragmas "$W/bare.dill" "$W/bare.json"; then
  SRCP=$(count "$W/bare.json" retained_by_source_pragma_count)
  CONP=$(count "$W/bare.json" retained_by_contract_count)
  if [[ "$SRCP" == 0 && "$CONP" == 0 ]]; then
    ok "built with NO contract, the subject carries no retaining pragma at all"
    echo "          (source-pragma retained=$SRCP, contract retained=$CONP)"
  else
    fail "the subject is retained without any contract
            (source-pragma retained=$SRCP, contract retained=$CONP).
            Every withheld-retention arm would measure that instead."
  fi
else
  fail "could not build or read the no-contract kernel"
fi

# ---- 3. with the contract: the CONTRACT pragmas must appear ---------------
if kernel "$W/full.dill" package:dynamic_modules/host.dart "$G/probe/di_full.yaml" \
   && pragmas "$W/full.dill" "$W/full.json"; then
  SRCP=$(count "$W/full.json" retained_by_source_pragma_count)
  CONP=$(count "$W/full.json" retained_by_contract_count)
  if [[ "$SRCP" == 0 && "$CONP" -gt 0 ]]; then
    ok "built WITH the contract, retention comes from the contract alone"
    echo "          (source-pragma retained=$SRCP, contract retained=$CONP)"
  else
    fail "with the contract applied the mechanism is not attributable
            (source-pragma retained=$SRCP, contract retained=$CONP)"
  fi
else
  fail "could not build or read the full-contract kernel"
fi

# ---- 4. THE MECHANISM CONTROL --------------------------------------------
# Withholding `callable` from the clean subject aborts the VM. The SAME
# withholding against a subject carrying vm:entry-point must NOT abort -- which
# is what "the pragma masks the contract" means, measured rather than asserted.
build_and_run() { # <lib-uri> <di.yaml> <module-src> <tag>
  local uri=$1 di=$2 mod=$3 tag=$4
  kernel "$W/$tag.dill" "$uri" "$di" || { echo "KERNEL_FAILED"; return; }
  "$OUT/gen_snapshot" --snapshot_kind=app-aot-elf --elf="$W/$tag.aot" "$W/$tag.dill" >/dev/null 2>&1
  "$DART" "$GK" --platform "$OUT/vm_platform.dill" --no-aot --no-link-platform \
    --packages "$PKG" -o "$W/${tag}_import.dill" "$uri" >/dev/null 2>&1
  "$DART" "$D2B" --platform "$OUT/vm_platform.dill" --import-dill "$W/${tag}_import.dill" \
    -o "$W/$tag.bytecode" "$mod" >/dev/null 2>&1 || { echo "BYTECODE_FAILED"; return; }
  "$OUT/dartaotruntime" "$W/$tag.aot" "$W/$tag.bytecode" "file://$mod" > "$W/$tag.run" 2>&1
  echo "rc=$?"
}

sed 's|/host.dart|/host_pragma.dart|' "$G/probe/di_no_callable.yaml" > "$W/di_no_callable_pragma.yaml"
CLEAN=$(build_and_run package:dynamic_modules/host.dart "$G/probe/di_no_callable.yaml" "$W/m_patch.dart" clean)
DEMOR=$(build_and_run package:dynamic_modules/host_pragma.dart "$W/di_no_callable_pragma.yaml" "$W/m_patch_pragma.dart" demo)

echo "          callable withheld, subject CLEAN            -> $CLEAN"
echo "          callable withheld, subject has entry-point  -> $DEMOR"
if [[ "$CLEAN" != "rc=0" && "$DEMOR" == "rc=0" ]]; then
  ok "the pragma MASKS the withheld contract: the same withholding that fails on
          a clean subject succeeds on one carrying vm:entry-point, so an arm
          measured on such a subject would be vacuous"
elif [[ "$CLEAN" == "$DEMOR" ]]; then
  fail "the pragma made no difference ($CLEAN both ways), so this control does
            not establish that the mechanisms are separable here"
else
  fail "unexpected mechanism-control result (clean=$CLEAN demo=$DEMOR)"
fi

if [[ "$FAILED" == 0 ]]; then
  echo "PRAGMA_CONFOUND=CONTROLLED"
else
  echo "PRAGMA_CONFOUND=NOT_CONTROLLED"
fi
exit "$FAILED"
