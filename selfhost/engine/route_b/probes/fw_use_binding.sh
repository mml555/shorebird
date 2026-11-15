#!/usr/bin/env bash
# cspell:words dartaotruntime SBRBPTCH sbrb dynmod
#
# fw_use_binding.sh -- can a replacement body name a type and a member from a
# package the app already uses, outside the app's own libraries?
#
# The first `build()` patch on a device died at load:
#
#   bytecode_reader.cc: 1173: error: Unable to find class BuildContext in
#   Library:'package:flutter/src/widgets/framework.dart'
#
# The release kept the app's libraries whole and four named SDK members, and
# nothing from Flutter. A patch's signature and body name framework classes
# and members by name, and AOT keeps no name nobody declared.
# gen_dynamic_interface.dart now retains what the app's own code uses outside
# the app; this probe is that change on the host, with package:crypto standing
# in for Flutter (the target already calls `sha256.convert(...)`).
#
#   control      a body naming nothing                    -- must bind
#   negative     the crypto body, --no-framework-uses     -- must NOT bind, and
#                must fail at load naming package:crypto
#   positive     the crypto body, framework uses retained,
#                one walk of the import kernel read under
#                --platform (what a release does)         -- must bind
#   two-walks    the same without --platform (a cell
#                minted before it): import + prepass      -- must bind
#   sdk-instance --framework-members with-sdk-instance,
#                to measure the tax the default avoids    -- must bind
#
# Every arm also fails if the generator reports a declaration it could not
# walk: that costs the release those names silently on a real app.
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
RB="$(cd "$HERE/.." >/dev/null 2>&1 && pwd)"
WORK=${WORK:-$(mktemp -d)}

DART_TREE=$SRC/flutter/third_party/dart
DART=$OUT/dart-sdk/bin/dart
KERNEL_PKGS="--packages=$DART_TREE/.dart_tool/package_config.json"
GEN_KERNEL=$DART_TREE/pkg/vm/bin/gen_kernel.dart
DART2BC=$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart
GEN_SNAPSHOT=$OUT/gen_snapshot
AOT_RUNTIME=$OUT/dartaotruntime
PKGS_DIR=$DART_TREE/third_party/pkg/core/pkgs

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }
pass=0; fail=0

# Only names the target itself uses: it calls sha256.convert(...).toString()
# and compares strings. `.isNotEmpty` here failed at load, correctly: the
# target never uses it, so nothing kept it.
BODY="(sha256.convert([1]) as Digest).toString() == 'x' ? 'X' : 'NEW-a'"
MEMBERS='dart:core#print'
[ -x "$DART" ] || die "no host dart at $DART"
mkdir -p "$WORK/lib" "$WORK/.dart_tool"

# The release under test is packaging/container_target.dart -- the SAME program
# verify_patch_flow.sh uses, because it carries the reference installer. A
# hand-rolled target that only PRINTS a value never applies the container, and
# then every arm "passes" for the same wrong reason. (That is exactly what the
# first version of this probe did.)
cp "$RB/packaging/container_target.dart" "$WORK/lib/container_target.dart"
cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$WORK/", "packageUri": "lib/",
    "languageVersion": "3.9" },
  { "name": "crypto", "rootUri": "file://$PKGS_DIR/crypto", "packageUri": "lib/",
    "languageVersion": "3.4" },
  { "name": "typed_data", "rootUri": "file://$PKGS_DIR/typed_data",
    "packageUri": "lib/", "languageVersion": "3.4" } ] }
JSON
URI=package:dynamic_modules/container_target.dart
cd "$WORK"

kernel() { # <out> [extra...]
  "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
    --packages .dart_tool/package_config.json "${@:2}" -o "$1" "$URI" >/dev/null
}

note "pass 1: plain kernel, to generate the interface from"
kernel base.dill
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot \
  --no-link-platform --packages .dart_tool/package_config.json \
  -o import.dill "$URI" >/dev/null

# One arm per SDK member list. Everything else is held constant.
run_arm() { # <label> <sdk-members> <expect: bind|refuse> [load-error regex]
  local label="$1" members="$2" expect="$3" load_error="${4:-}"
  local dir="$WORK/$label"; mkdir -p "$dir"

  # The app is the target's own package; package:crypto is "the framework".
  # $FW_FLAG is split on purpose: it holds zero or more flags.
  # shellcheck disable=SC2086
  "$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" \
    --dill base.dill --private-dill import.dill --out "$dir/di.yaml" \
    --include package:dynamic_modules/ --sdk-members "$members" \
    $FW_FLAG 2> "$dir/gen.log"
  grep -m1 'framework uses' "$dir/gen.log" | sed 's/^ */  generator: /' || true
  if grep -q 'framework walk failed' "$dir/gen.log"; then
    echo "  FAIL  $label (the generator could not walk a declaration)"
    grep 'framework walk failed' "$dir/gen.log" | sed 's/^/      /' | head -4
    fail=$((fail+1)); return
  fi
  kernel "$dir/release.dill" --dynamic-interface "$dir/di.yaml"
  "$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
    --elf="$dir/app.aot" "$dir/release.dill"

  cat > "$dir/repl.dart" <<DART
import 'package:crypto/crypto.dart';

@pragma('dyn-module:entry-point')
String alpha() => $BODY;
DART

  # A compile failure and a LOAD failure are different answers, so they are
  # reported separately rather than as one "it did not work".
  if ! "$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" \
      --import-dill import.dill -o "$dir/repl.bytecode" "$dir/repl.dart" \
      > "$dir/compile.log" 2>&1; then
    echo "  compile: FAILED"
    sed 's/^/      /' "$dir/compile.log" | head -4
    [ "$expect" = refuse ] && { echo "  PASS  $label (refused at compile)"; pass=$((pass+1)); return; }
    echo "  FAIL  $label (expected to bind, refused at compile)"; fail=$((fail+1)); return
  fi

  # Attach and read the value back. This is the load-time binding question.
  # The release identity the container must carry, from the snapshot itself.
  local build_id
  build_id=$("$AOT_RUNTIME" "$dir/app.aot" | sed -n 's/^BUILD_ID //p')
  "$DART" "$RB/packaging/pack_patch.dart" --release-build-id "$build_id" \
    --out "$dir/patch.sbrb" --target "$URI#alpha=$dir/repl.bytecode" \
    >/dev/null 2>&1

  set +e
  "$AOT_RUNTIME" "$dir/app.aot" "$dir/patch.sbrb" > "$dir/run.log" 2>&1
  set -e

  # BOUND means the replacement actually ran: the installer prints the value it
  # reads back AFTER attaching. Anything else -- a refusal, a load error, or a
  # silent no-op -- is not bound.
  local bound="no"
  grep -q 'after  alpha=NEW-a' "$dir/run.log" && bound="yes"

  echo "  interface: $(grep -c . "$dir/di.yaml") lines, sdk-members='$members'"
  if grep -q 'Unable to find' "$dir/run.log"; then
    echo "  load: $(grep -m1 'Unable to find' "$dir/run.log" | sed 's/^.*error: //')"
  fi
  echo "  interface: $(wc -c < "$dir/di.yaml" | tr -d ' ') bytes, $(grep -c 'member:' "$dir/di.yaml") named members"
  echo "  snapshot: $(wc -c < "$dir/app.aot" | tr -d ' ') bytes"
  grep -q '^APPLY' "$dir/run.log" && echo "  $(grep -m1 '^APPLY' "$dir/run.log")"

  if [ "$expect" = bind ] && [ "$bound" = yes ]; then
    echo "  PASS  $label (bound)"; pass=$((pass+1))
  elif [ "$expect" = refuse ] && [ "$bound" = no ] && [ -n "$load_error" ] &&
      ! grep -Eq "$load_error" "$dir/run.log"; then
    # Not binding for some other reason (a crash, a refusal) would pass a
    # bare "did not bind" for the wrong reason.
    echo "  FAIL  $label (did not bind, but not with /$load_error/)"
    sed 's/^/      /' "$dir/run.log" | head -6
    fail=$((fail+1))
  elif [ "$expect" = refuse ] && [ "$bound" = no ]; then
    echo "  PASS  $label (did not bind, as expected)"; pass=$((pass+1))
  else
    echo "  FAIL  $label (expected $expect, bound=$bound)"
    sed 's/^/      /' "$dir/run.log" | head -6
    fail=$((fail+1))
  fi
}

note "control - a body with no external symbol"
BODY_SAVED="$BODY"; BODY="'NEW-a'"
FW_FLAG=--no-framework-uses run_arm control "$MEMBERS" bind
BODY="$BODY_SAVED"

note "negative - the crypto body, framework uses NOT retained"
FW_FLAG=--no-framework-uses run_arm negative "$MEMBERS" refuse \
  'Unable to find .*package:crypto'

note "positive - the crypto body, framework uses retained (one walk, --platform)"
FW_FLAG="--platform $OUT/vm_platform.dill" run_arm positive "$MEMBERS" bind

note "two-walks - the same, without --platform"
FW_FLAG= run_arm two-walks "$MEMBERS" bind

note "sdk-instance - dart: instance members reached through code retained too"
FW_FLAG="--platform $OUT/vm_platform.dill --framework-members with-sdk-instance" \
  run_arm sdk-instance "$MEMBERS" bind

note "retention tax, against the negative arm"
base=$(wc -c < "$WORK/negative/app.aot" | tr -d ' ')
for arm in positive two-walks sdk-instance; do
  [ -f "$WORK/$arm/app.aot" ] || continue
  widened=$(wc -c < "$WORK/$arm/app.aot" | tr -d ' ')
  printf '  %-12s: %s -> %s bytes (%+d, %s%%)\n' "$arm" "$base" "$widened" \
    "$((widened - base))" \
    "$(python3 -c "print(f'{($widened-$base)/$base*100:+.4f}')")"
done
printf '  retained  : %s framework members, %s type entries\n' \
  "$(grep -c 'member:' "$WORK/positive/di.yaml")" \
  "$(sed -n '/^can-be-used-as-type:/,$p' "$WORK/positive/di.yaml" | grep -c 'library:')"

echo
echo "--------------------------------------------------"
echo "framework-use binding: $pass passed, $fail failed"
echo "work dir kept: $WORK"
[ "$fail" -eq 0 ] || exit 1
