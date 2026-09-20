set -u
O=/Volumes/build/route-b/flutter/engine/src/out/maot_host
W=/private/tmp/claude-501/-Users-mendell-shorebird/541d1f40-74f1-4642-a5e6-6219048476c9/scratchpad/stage43
NS=ec782f4bc74f19fe85cb6348a5a448960590a183cfe2a6ed6f7962cb8e5f6b0e
# Same two arms with EVERY diagnostic flag removed. If the snapshot is the same
# size, "diagnostics enabled but nonserialized" is measured rather than assumed.
$O/gen_snapshot --snapshot_kind=app-aot-elf --elf=$W/A_nodiag.aot \
  --maot_namespace=$NS $W/k0.dill > /dev/null 2>&1
echo "A_nodiag rc=$? bytes=$(stat -f%z $W/A_nodiag.aot)"
$O/gen_snapshot --snapshot_kind=app-aot-elf --elf=$W/C_nodiag.aot \
  --maot_namespace=$NS --maot_disable_retention_roots \
  --maot_install_trampolines $W/k2.dill > /dev/null 2>&1
echo "C_nodiag rc=$? bytes=$(stat -f%z $W/C_nodiag.aot)"
echo "A_diag   bytes=$(stat -f%z $W/A.aot)"
echo "C_diag   bytes=$(stat -f%z $W/C.aot)"
