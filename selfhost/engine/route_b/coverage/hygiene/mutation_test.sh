#!/usr/bin/env bash
#
# mutation_test.sh -- prove that the ALLOCATOR is what protects the semantics.
#
# A hygiene suite that passes tells you the suite passed. It does not tell you
# WHICH code made it pass -- and this project has twice had a check that could
# not fail read as a result (see RESULT.md, "Two harness faults"). So the
# allocator is mutated to its pre-repair behaviour -- always `self` -- and the
# suite must go RED on exactly the cases that were UNSAFE before the repair.
#
# If the suite stays green under the mutation, the repair is not what is
# holding, and neither is the evidence.
#
# The producer source is restored from a checksummed backup by a trap, so an
# interrupted run cannot leave a mutated producer behind.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../../../../.." >/dev/null 2>&1 && pwd)"
TARGET="$REPO/packages/shorebird_cli/lib/src/route_b_producer.dart"
BACKUP="$(mktemp)"
WORK="${WORK:-$(mktemp -d)}"
mkdir -p "$WORK"

# THREE buckets, because "the suite goes red" is not one claim.
#
# CAPTURE cases: the author BINDS `self` in a scope that encloses a receiver
# access. Without the allocator each is accepted, compiles, and means something
# else. Every one must be UNSAFE under the mutation.
EXPECT_RED=(A_local_self_body B_closure_param_self C_closure_param_self_used
            E_closure_local_self F_local_function_param_self
            G_nested_closures_self H_contains_candidate_0
            I_contains_several_candidates)

# COLLISION case: the clash is in the SAME scope as the inserted parameter, so
# dart2bytecode refuses two parameters of one name. Loud, not silent.
EXPECT_LOUD=(D_target_param_self)

# NOT-A-CAPTURE cases, and they are the reason this file has three buckets
# rather than one. `J` reads a legitimate MEMBER named `self` -- that is
# `this.self`, a member access, not a binding -- so it lowers correctly with or
# without the allocator, and the first draft of this test wrongly demanded it go
# red. `K` spells no `self` in its declaration at all. Both must stay SAFE under
# the mutation: they show the allocator is not being credited for cases it does
# not fix, and that the rename does not damage a member that happens to be named
# `self`.
EXPECT_GREEN=(J_member_named_self K_no_self_preservation)

cp "$TARGET" "$BACKUP"
before=$(shasum -a 256 "$TARGET" | cut -d' ' -f1)
restore() {
  cp "$BACKUP" "$TARGET"
  after=$(shasum -a 256 "$TARGET" | cut -d' ' -f1)
  rm -f "$BACKUP"
  if [ "$after" != "$before" ]; then
    echo "FATAL: producer not restored ($before -> $after)" >&2; exit 3
  fi
  echo "producer restored, sha256 $after"
}
trap restore EXIT

# ---- PRESERVATION, measured in ONE directory ------------------------------
# The claim is that a declaration with no `self` lowers to exactly what it
# lowered to before the repair. Comparing two runs in two temp directories does
# NOT show that: the compiled bytecode embeds the replacement's absolute source
# path, so two work dirs differ in the bytecode even when the source is
# identical. Both runs therefore use the SAME path, and the unmutated artifacts
# are copied aside before the mutated run overwrites them.
PRESERVE=K_no_self_preservation
echo "==> preservation baseline: $PRESERVE with the allocator"
rm -rf "$WORK/$PRESERVE"
WORK="$WORK" bash "$HERE/run_hygiene.sh" "$PRESERVE" > "$WORK/preserve_pre.log" 2>&1
mkdir -p "$WORK/preserve_pre"
cp "$WORK/$PRESERVE/out/replacement_0.dart" \
   "$WORK/$PRESERVE/out/replacement_0.bytecode" "$WORK/preserve_pre/"

echo "==> mutating the allocator to always return the default"
python3 - "$TARGET" <<'PY'
import io,sys
p=sys.argv[1]; s=io.open(p,encoding='utf-8').read()
old="""  static String _freshReceiverName(String declaration) {
    if (!declaration.contains(_defaultReceiverName)) {
      return _defaultReceiverName;
    }"""
new="""  static String _freshReceiverName(String declaration) {
    return _defaultReceiverName; // MUTATION TEST -- restored by trap
    // ignore: dead_code
    if (!declaration.contains(_defaultReceiverName)) {
      return _defaultReceiverName;
    }"""
assert s.count(old)==1, 'mutation site not found -- refusing to run'
io.open(p,'w',encoding='utf-8').write(s.replace(old,new))
print('  mutated')
PY

echo "==> running the suite under the mutation"
echo "==> preservation under the mutation, into the SAME directory"
rm -rf "$WORK/$PRESERVE"
set +e
WORK="$WORK" bash "$HERE/run_hygiene.sh" "$PRESERVE" > "$WORK/preserve_post.log" 2>&1
set -e
preserve_fail=0
if diff -q "$WORK/preserve_pre/replacement_0.dart" \
           "$WORK/$PRESERVE/out/replacement_0.dart" >/dev/null; then
  echo "  source   BYTE-IDENTICAL"
else
  echo "  source   DIFFERS"; preserve_fail=1
fi
if cmp -s "$WORK/preserve_pre/replacement_0.bytecode" \
          "$WORK/$PRESERVE/out/replacement_0.bytecode"; then
  echo "  bytecode BYTE-IDENTICAL"
else
  echo "  bytecode DIFFERS"; preserve_fail=1
fi

echo
ALL=("${EXPECT_RED[@]}" "${EXPECT_LOUD[@]}" "${EXPECT_GREEN[@]}")
set +e
WORK="$WORK" bash "$HERE/run_hygiene.sh" "${ALL[@]}" > "$WORK/mutant.log" 2>&1
set -e
grep -E "==>|VERDICT" "$WORK/mutant.log" || true

echo
fail=0
verdict_of() {
  awk -v c="$1" '$0 ~ "==> "c"$" {f=1} f && /VERDICT/ {print; exit}' "$WORK/mutant.log"
}
for c in "${EXPECT_RED[@]}"; do
  v=$(verdict_of "$c")
  case "$v" in
    *UNSAFE*) echo "  UNSAFE as required  $c" ;;
    *)        echo "  NOT UNSAFE          $c  -> ${v:-<no verdict>}"; fail=$((fail+1)) ;;
  esac
done
for c in "${EXPECT_LOUD[@]}"; do
  v=$(verdict_of "$c")
  case "$v" in
    *LOUD*) echo "  LOUD as required    $c" ;;
    *)      echo "  NOT LOUD            $c  -> ${v:-<no verdict>}"; fail=$((fail+1)) ;;
  esac
done
for c in "${EXPECT_GREEN[@]}"; do
  v=$(verdict_of "$c")
  case "$v" in
    *SAFE*)  echo "  SAFE as required    $c  (not a capture case)" ;;
    *)       echo "  NOT SAFE            $c  -> ${v:-<no verdict>}"; fail=$((fail+1)) ;;
  esac
done

echo
if [ "$preserve_fail" -ne 0 ]; then
  echo "PRESERVATION FAILED: a declaration with no \`self\` did not lower to"
  echo "the same bytes with and without the allocator."
  exit 1
fi
if [ "$fail" -ne 0 ]; then
  echo "MUTATION TEST FAILED: $fail case(s) did not behave as the buckets say."
  echo "The suite is not measuring what it claims to measure."
  exit 1
fi
echo "MUTATION TEST PASSED: every capture case is UNSAFE without the allocator,"
echo "the collision case is still LOUD, and the two non-capture cases stay SAFE."
echo "So the allocator is what makes the capture cases green -- and it is not"
echo "being credited for the cases it does not fix."
