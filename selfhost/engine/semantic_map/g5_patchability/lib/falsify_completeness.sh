#!/usr/bin/env bash
# Positive control for verify_completeness.sh.
#
# An enumeration that cannot come out wrong proves nothing. This builds a copy
# of the tree with ONE planted addition -- a second function calling
# FlowGraphInliner::NextInlineId, the exact shape of a new registration site
# the completeness argument would have to account for -- and requires that
#
#   * the baseline tree passes every check;
#   * the control tree is COMPLETE (a missing file must never be mistaken for
#     a flipped check: an earlier version of this control copied a broken tree
#     and reported DRIFTED for that reason, while the NextInlineId checks it
#     was supposed to flip actually PASSED);
#   * the plant is present and observable;
#   * EXACTLY the two NextInlineId checks flip, and nothing else.
#
# usage: falsify_completeness.sh <dart-tree-root> <control-tree-dir>
set -uo pipefail
D="${1:?usage: falsify_completeness.sh <dart-tree-root> <control-tree-dir>}"
CTL="${2:?usage: falsify_completeness.sh <dart-tree-root> <control-tree-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
V="$HERE/verify_completeness.sh"
rc=0
EXPECT_FLIP=(
  'NextInlineId call sites (excluding decl/defn)'
  'NextInlineId call site is in inliner.cc'
)

echo "=== baseline: every check must pass ==="
base_out=$("$V" "$D" 2>&1); base_rc=$?
echo "$base_out"
echo "exit=$base_rc"
[ "$base_rc" = 0 ] || { echo "  ASSERTION FAILED: baseline did not hold"; rc=1; }

echo
echo "=== building the control tree ==="
rm -rf "$CTL"; mkdir -p "$CTL/runtime"
# Plain cp into an existing parent. An earlier version tried `cp -c -R src dst`
# first; that fails across volumes, and the `|| cp -R` fallback then ran with
# dst already partly created, nesting the tree at vm/vm/... -- so `grep -r`
# still found content while every direct path was missing.
cp -R "$D/runtime/vm" "$CTL/runtime/" || { echo "  copy failed"; exit 2; }

REQUIRED=(
  vm/compiler/backend/inliner.cc
  vm/compiler/backend/inliner.h
  vm/compiler/backend/flow_graph.h
  vm/compiler/backend/il_test_helper.cc
  vm/compiler/backend/il_serializer.cc
  vm/compiler/call_specializer.cc
  vm/compiler/aot/precompiler.cc
  vm/compiler/aot/aot_call_specializer.cc
  vm/compiler/jit/compiler.cc
  vm/compiler/method_recognizer.cc
  vm/compiler/recognized_methods_list.h
  vm/object.cc
)
missing=0
for f in "${REQUIRED[@]}"; do
  [ -f "$CTL/runtime/$f" ] || { echo "  MISSING $f"; missing=1; }
done
if [ "$missing" != 0 ]; then
  echo "  ASSERTION FAILED: control tree incomplete -- a missing file would"
  echo "  masquerade as a flipped check. Refusing to run the control."
  exit 1
fi
echo "  control tree complete: ${#REQUIRED[@]} required files present"

echo
echo "=== planting one second NextInlineId call site ==="
python3 - "$CTL/runtime/vm/compiler/backend/inliner.cc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
anchor = "intptr_t FlowGraphInliner::NextInlineId(const Function& function,"
assert anchor in s, 'anchor not found; the plant would be silent'
p.write_text(s.replace(anchor,
  "void ShorebirdControlSecondSite(FlowGraphInliner* i, const Function& f,\n"
  "                                const InstructionSource& src) {\n"
  "  i->NextInlineId(f, src);  // PLANTED: a second registration site\n"
  "}\n\n" + anchor, 1))
PY
[ $? = 0 ] || { echo "  ASSERTION FAILED: the plant did not apply"; exit 1; }

# The plant must be OBSERVABLE, not merely attempted.
planted=$(grep -c 'ShorebirdControlSecondSite' \
            "$CTL/runtime/vm/compiler/backend/inliner.cc")
calls=$(grep -c 'NextInlineId' "$CTL/runtime/vm/compiler/backend/inliner.cc")
base_calls=$(grep -c 'NextInlineId' "$D/runtime/vm/compiler/backend/inliner.cc")
echo "  planted symbol occurrences: $planted"
echo "  NextInlineId mentions in inliner.cc: baseline=$base_calls control=$calls"
if [ "$planted" -lt 1 ] || [ "$calls" -ne $((base_calls + 1)) ]; then
  echo "  ASSERTION FAILED: the planted call site is not observable"
  rc=1
fi

echo
echo "=== control: EXACTLY the NextInlineId checks may flip ==="
ctl_out=$("$V" "$CTL" 2>&1); ctl_rc=$?
echo "$ctl_out"
echo "exit=$ctl_rc"
[ "$ctl_rc" != 0 ] || { echo "  ASSERTION FAILED: control did not fail"; rc=1; }

flipped=$(echo "$ctl_out" | sed -n 's/^  FAIL  \(.*[^ ]\)  *got .*/\1/p' \
          | sed 's/ *$//' | sort)
expected=$(printf '%s\n' "${EXPECT_FLIP[@]}" | sort)
if [ "$flipped" = "$expected" ]; then
  echo "  the flipped set is exactly the NextInlineId checks"
else
  echo "  ASSERTION FAILED: flipped set is not the expected set"
  echo "  --- flipped ---"; echo "$flipped"
  echo "  --- expected ---"; echo "$expected"
  rc=1
fi

rm -rf "$CTL"
echo
if [ "$rc" = 0 ]; then
  echo 'SM1_G5_COMPLETENESS_CONTROL: VALID_AND_SENSITIVE'
else
  echo 'SM1_G5_COMPLETENESS_CONTROL: INVALID'
fi
exit "$rc"
