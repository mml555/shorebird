#!/usr/bin/env bash
# cspell:words dartaotruntime SBRBPTCH sbrb dynmod
#
# a0_core_binding.sh -- Probe A0, on the host, before spending a release.
#
# ONE QUESTION: can a Route B replacement body bind a named `dart:core` symbol?
#
# The device gate answered "no" for `DateTime.now()`, but it answered it with
# NO dynamic interface in play at all -- the product path has never passed one,
# and the fixture's target was reachable only because it carries a hand-written
# @pragma('vm:entry-point'). So the device result is not evidence about
# retention policy; it is evidence that the policy is absent.
#
# This runs the full compile/attach loop on the host, where a cycle is a minute
# rather than a release, and varies exactly one thing: which SDK members the
# generated dynamic interface declares.
#
# THREE ARMS, and the control is the point:
#
#   control   a body with no external symbol -- must PASS, or the harness is
#             broken rather than the retention policy
#   negative  a body using a core symbol NOT declared -- must FAIL, or the
#             declaration is not what makes it work
#   positive  the same body with the symbol declared -- the actual question
#
# An arm that "passes" without its negative failing proves nothing, which is the
# trap this whole project keeps rediscovering.
#
#   a0_core_binding.sh [identical|datetime]
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
CASE=${1:-identical}

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }
pass=0; fail=0

# The body under test, and the SDK members it needs declared.
case "$CASE" in
  identical)
    # Deliberately simpler than DateTime.now(): ONE top-level function, no
    # class, no constructor, no factory, no subsequent member access. If this
    # does not bind, nothing more complicated will, and the diagnosis stays
    # small.
    BODY="identical(1, 1) ? 'NEW-a' : 'X'"
    MEMBERS='dart:core#identical'
    ;;
  datetime)
    # A0.2 -- replay the exact shape that failed on the device. A class, a
    # factory constructor, and an instance getter on the result.
    BODY="DateTime.now().millisecondsSinceEpoch >= 0 ? 'NEW-a' : 'X'"
    MEMBERS='dart:core#DateTime.now,dart:core#DateTime.get:millisecondsSinceEpoch'
    ;;
  *) die "unknown case: $CASE (want identical|datetime)" ;;
esac

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
run_arm() { # <label> <sdk-members> <expect: bind|refuse>
  local label="$1" members="$2" expect="$3"
  local dir="$WORK/$label"; mkdir -p "$dir"

  "$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" \
    --dill base.dill --out "$dir/di.yaml" --sdk-members "$members" 2>/dev/null
  kernel "$dir/release.dill" --dynamic-interface "$dir/di.yaml"
  "$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
    --elf="$dir/app.aot" "$dir/release.dill"

  cat > "$dir/repl.dart" <<DART
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
  elif [ "$expect" = refuse ] && [ "$bound" = no ]; then
    echo "  PASS  $label (did not bind, as expected)"; pass=$((pass+1))
  else
    echo "  FAIL  $label (expected $expect, bound=$bound)"
    sed 's/^/      /' "$dir/run.log" | head -6
    fail=$((fail+1))
  fi
}

note "control — a body with no external symbol"
BODY_SAVED="$BODY"; BODY="'NEW-a'"
run_arm control 'dart:core#print' bind
BODY="$BODY_SAVED"

note "negative — '$CASE' body, symbol NOT declared"
run_arm negative 'dart:core#print' refuse

note "positive — '$CASE' body, declaring $MEMBERS"
run_arm positive "$MEMBERS" bind

# THE TAX. Retention is release-time and every future release pays it, so the
# cost of the widening is reported rather than assumed. The naive alternative --
# a whole `dart:core` library item -- was measured at +310% and is the thing
# this must not accidentally recreate under another name.
note "retention tax"
base=$(wc -c < "$WORK/negative/app.aot" | tr -d ' ')
widened=$(wc -c < "$WORK/positive/app.aot" | tr -d ' ')
di_base=$(wc -c < "$WORK/negative/di.yaml" | tr -d ' ')
di_wide=$(wc -c < "$WORK/positive/di.yaml" | tr -d ' ')
printf '  interface : %s -> %s bytes\n' "$di_base" "$di_wide"
printf '  snapshot  : %s -> %s bytes (%+d, %s%%)\n' "$base" "$widened" \
  "$((widened - base))" \
  "$(python3 -c "print(f'{($widened-$base)/$base*100:+.4f}')")"
printf '  members   : %s -> %s named SDK entries\n' \
  "$(grep -c 'member:' "$WORK/negative/di.yaml")" \
  "$(grep -c 'member:' "$WORK/positive/di.yaml")"

echo
echo "--------------------------------------------------"
echo "probe A0 ($CASE): $pass passed, $fail failed"
echo "work dir kept: $WORK"
[ "$fail" -eq 0 ] || exit 1
