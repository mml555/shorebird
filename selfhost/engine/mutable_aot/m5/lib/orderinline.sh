set -u
O=/Volumes/build/route-b/flutter/engine/src/out/maot_host
W=/private/tmp/claude-501/-Users-mendell-shorebird/541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/sizemat
T=$W/edgediff
NS=ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e
# ONE invocation carries both traces, so the ordinal and the inlining decision
# it is being correlated with come from the same compilation.
run() {
  tag=$1; shift
  $O/gen_snapshot --snapshot_kind=app-aot-elf --elf=$T/$tag.oi.aot \
    --maot_namespace=$NS --maot_disable_retention_roots \
    --trace_precompiler --print_inlining_tree "$@" $W/k1.dill \
    > /dev/null 2> $T/$tag.oi.err
  echo "$tag rc=$? precompiling=$(grep -c '^Precompiling' $T/$tag.oi.err) trees=$(grep -c '^Inlining into:' $T/$tag.oi.err)"
}
run C --maot_disable_call_indirection
run B
