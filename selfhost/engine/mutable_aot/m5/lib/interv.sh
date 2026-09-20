set -u
O=/Volumes/build/route-b/flutter/engine/src/out/maot_host
W=/private/tmp/claude-501/-Users-mendell-shorebird/541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/sizemat
T=$W/edgediff
NS=ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e
# INTERVENTION. The claimed chain is:
#   AlwaysInline(get:isEmpty) == (cached optimized_instruction_count in (0,10))
#   -> the AOT "do not inline intrinsics" bail is skipped
#   -> isEmpty folds into the inlined isNotEmpty body
#   -> isNotEmpty contributes no emitted instruction
#   -> it is not in resolveUri's inline tree
#   -> it is not retained.
# Setting the getter/setter threshold to 0 makes AlwaysInline unconditionally
# false for getters, which must restore the retention in the production arm and
# must leave the control arm unchanged. Either failure refutes the chain.
run() {
  tag=$1; shift
  $O/gen_snapshot --snapshot_kind=app-aot-elf --elf=$T/$tag.iv.aot \
    --maot_namespace=$NS --maot_disable_retention_roots \
    --maot_dump_retained=$T/$tag.iv.retained "$@" $W/k1.dill \
    > /dev/null 2> $T/$tag.iv.err
  rc=$?
  n=$(wc -l < $T/$tag.iv.retained 2>/dev/null || echo -1)
  k=$(grep -c '^dart:core__StringBase@0150898_get_isNotEmpty$' $T/$tag.iv.retained 2>/dev/null || echo 0)
  echo "$tag rc=$rc retained=$n isNotEmpty=$k"
}
run Bthr0 --inline_getters_setters_smaller_than=0
run Cthr0 --maot_disable_call_indirection --inline_getters_setters_smaller_than=0
