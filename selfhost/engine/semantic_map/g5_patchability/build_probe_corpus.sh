#!/usr/bin/env bash
# SM1-G5 -- build the probe corpus from checked-in source.
#
# WHY THIS EXISTS. G8 found that the original probe work directory could not be
# rebuilt: its di3.yaml was produced by an invocation nobody recorded, so the
# release kernel and AOT could not be reconstructed. Two candidate invocations
# were tried and neither matched, and guessing further would have manufactured
# a reproduction rather than established one.
#
# So the recipe is now AUTHORED here rather than recovered. The dynamic-interface
# policy is stated as an intent with its arguments spelled out, and the old
# di3.yaml becomes historical evidence whose recipe is unrecoverable -- not a
# target to reverse-engineer.
#
# THE POLICY, and why each part of it:
#
#   --policy p2                  every private member and class of the app's own
#                                libraries. The probe exercises private targets
#                                (_state, _parse, _inlineHelper) and private
#                                classes (_Container, _Target), so a narrower
#                                policy would make those declarations
#                                unreachable and change what the gate measures.
#
#   --include the three app packages
#                                dynamic_modules is the probe; crypto and
#                                typed_data are its real dependencies -- the
#                                container parser verifies sha256 -- so they are
#                                app libraries here, not SDK.
#
#   --sdk-members named, not whole libraries
#                                the probe bodies call print, DateTime.now and
#                                DateTime.millisecondsSinceEpoch. Whole-library
#                                dart:core retention is measured at +310%, so
#                                only these three are named.
#
# FILENAMES. The outputs use the names the banked contract already asserts --
# release3.dill, pre_r.dill, prepass3.dill, di3.yaml, import.dill. They are
# legacy and uninformative, but they are what run_route2.sh, the manifest
# checker and the banked G1 projection all name, and renaming them would change
# recorded provenance for cosmetic reasons. What matters is that the RECIPE is
# now authored; the names are not the reproduction.
#
#   --private-dill the non-AOT kernel
#                                TFA has already tree-shaken the --aot prepass,
#                                so a private member nothing currently calls
#                                cannot be named from it -- and starting to call
#                                one is exactly what a patch may do.
#
# usage: build_probe_corpus.sh <clone-src> <out-dir>
set -uo pipefail
SRC="${1:?usage: build_probe_corpus.sh <clone-src> <out-dir>}"
W="${2:?}"
G="$(cd "$(dirname "$0")" && pwd)"
RB="$(cd "$G/../../route_b" && pwd)"
S="$SRC/out/host_release_arm64"
DT="$SRC/flutter/third_party/dart"
PKGS=/Volumes/build/route-b/flutter/engine/src/flutter/third_party/dart/third_party/pkg/core/pkgs
GK="$S/dartaotruntime $S/gen/gen_kernel_aot.dart.snapshot"
PKG="--packages=$DT/.dart_tool/package_config.json"
rc=0
must() { local w="$1"; shift; "$@" || { echo "  FAILED: $w"; rc=1; return 1; }; }

rm -rf "$W"; mkdir -p "$W/lib" "$W/.dart_tool"
cp "$G/probe/callsite_target.dart" "$W/lib/"
cat > "$W/.dart_tool/package_config.json" <<EOF
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$W/", "packageUri": "lib/", "languageVersion": "3.9" },
  { "name": "crypto", "rootUri": "file://$PKGS/crypto", "packageUri": "lib/", "languageVersion": "3.4" },
  { "name": "typed_data", "rootUri": "file://$PKGS/typed_data", "packageUri": "lib/", "languageVersion": "3.4" } ] }
EOF
CFG="$W/.dart_tool/package_config.json"
ENTRY="$W/lib/callsite_target.dart"
SDK_MEMBERS='dart:core#print,dart:core#DateTime.now,dart:core#DateTime.get:millisecondsSinceEpoch'

echo "  1. pre-AOT kernel (full private surface, and the ABI source)"
must pre $GK --platform "$S/vm_platform.dill" --packages "$CFG" \
    -o "$W/pre_r.dill" "$ENTRY"
echo "  2. prepass kernel (--aot, no interface yet)"
must prepass $GK --platform "$S/vm_platform.dill" --packages "$CFG" --aot \
    -o "$W/prepass3.dill" "$ENTRY"
echo "  3. dynamic interface, policy p2, arguments authored above"
must interface "$S/dart" $PKG "$RB/gen_dynamic_interface.dart" \
    --dill "$W/prepass3.dill" --private-dill "$W/pre_r.dill" --policy p2 \
    --include 'package:dynamic_modules/' --include 'package:crypto/' \
    --include 'package:typed_data/' --sdk-members "$SDK_MEMBERS" \
    --out "$W/di3.yaml"
echo "  4. release kernel, built WITH that interface"
must release $GK --platform "$S/vm_platform.dill" --packages "$CFG" --aot \
    --dynamic-interface "$W/di3.yaml" -o "$W/release3.dill" "$ENTRY"
echo "  5. release AOT, patchable static calls"
must aot "$S/gen_snapshot" --snapshot_kind=app-aot-elf \
    --patchable_static_calls --elf="$W/app_release.aot" "$W/release3.dill"
echo "  5b. a second AOT from the same kernel -- the note-determinism pair, and"
echo "      the identical-declaration pair G6's similarity arm needs"
must aot_b "$S/gen_snapshot" --snapshot_kind=app-aot-elf \
    --patchable_static_calls --elf="$W/app_release_b.aot" "$W/release3.dill"
echo "  6. G1 projection over the release, ABI from the pre-AOT kernel"
must g1 env -C "$W" "$S/dart" $PKG \
    "$G/../g2_fingerprints/lib/gen_map_rows.dart" \
    --dill release3.dill --pre-dill pre_r.dill \
    --include 'package:dynamic_modules/callsite_target.dart' --out g2_r.json
echo "  7. patch containers for the four demonstrated targets"
ID=$("$S/dartaotruntime" "$W/app_release.aot" | awk '/BUILD_ID/{print $2}')
[ -n "$ID" ] || { echo "  FAILED: no build id"; rc=1; }
for spec in "alpha:repl_alpha.dart:alpha" \
            "basework:repl_basework.dart:Base.work" \
            "smallTarget:repl_smallTarget.dart:smallTarget" \
            "tearOffTarget:repl_tearOffTarget.dart:tearOffTarget"; do
  name="${spec%%:*}"; rest="${spec#*:}"; src="${rest%%:*}"; sel="${rest##*:}"
  must "bytecode:$name" "$S/dartaotruntime" \
      "$S/gen/dart2bytecode.dart.snapshot" \
      --platform "$S/vm_platform.dill" --packages "$CFG" \
      --import-dill "$W/pre_r.dill" -o "$W/$name.bytecode" "$G/probe/$src"
  must "pack:$name" "$S/dart" "$RB/packaging/pack_patch.dart" \
      --release-build-id "$ID" --out "$W/patch_$name.sbrb" \
      --target "package:dynamic_modules/callsite_target.dart#$sel=$W/$name.bytecode"
done

# import.dill is the same non-AOT kernel under the name dart2bytecode expects.
# A real copy, not a symlink: a symlink is not an artifact a digest can bind,
# and an earlier version of this script linked files to themselves and silently
# destroyed them.
cp "$W/pre_r.dill" "$W/import.dill"

echo
echo "  build id: $ID"
for f in pre_r.dill prepass3.dill di3.yaml release3.dill import.dill \
         app_release.aot app_release_b.aot g2_r.json patch_alpha.sbrb \
         patch_basework.sbrb patch_smallTarget.sbrb patch_tearOffTarget.sbrb; do
  if [ -s "$W/$f" ]; then
    printf '  %-22s %12s bytes  %s\n' "$f" \
      "$(wc -c < "$W/$f" | tr -d ' ')" \
      "$(shasum -a 256 "$W/$f" | awk '{print substr($1,1,16)}')"
  else echo "  MISSING $f"; rc=1; fi
done
echo "PROBE_CORPUS: $([ "$rc" = 0 ] && echo BUILT || echo FAILED)"
exit "$rc"
