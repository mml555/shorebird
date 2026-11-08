#!/usr/bin/env bash
# cspell:words dartaotruntime dart2bytecode dynmod
#
# g37_param_abi.sh -- G3.7: can a replacement declare the target's OWN parameters?
#
# THE LARGEST SINGLE UNLOCK IN THE MEASUREMENT, and the last clause of the
# architectural question. PARITY §3 prices it at 33.2 % of structural reach, and
# parameters appear in 6 of 10 real patches -- more than privacy, which is why the
# two are measured separately and never credited to each other.
#
# Upstream requires a `dyn-module:entry-point` to be a static NO-ARGUMENT method.
# Patch 0004 relaxed that to zero-or-one so an instance method's receiver could be
# an ordinary first parameter, and capped it there ON PURPOSE so that "relax the
# restriction" could not quietly become a general arity change. Patch 0006 is that
# general change, made deliberately: any number of REQUIRED POSITIONAL parameters.
#
# WHAT THIS PROBE ANSWERS, and it is only answerable by running:
#
#   the lowering is unit-tested (route_b_producer_test.dart) and the compiler
#   contract is pinned (c_entrypoint_arity.sh) -- but neither says whether the
#   AOT caller's ARGUMENTS actually arrive, in order, in an interpreted body. The
#   call site pushes (receiver, a, b, ...) per its own ArgumentsDescriptor; this
#   asks whether the interpreted entry point binds them positionally as they come.
#
# OUTCOMES, PRECOMMITTED (the precommitment rule: written before the run, here,
# where the next reader finds them):
#
#   one_param   NEW-ARG        -> a single source parameter arrives. G3.7's core
#                                 claim, and the 33.2 % slice becomes reachable.
#   two_params  NEW-a-7        -> arguments arrive IN ORDER and keep their types;
#                                 an int is not boxed into the wrong slot.
#   named       REFUSED by CLI -> the analyzer refuses what the compiler refuses.
#                                 A pass here that reached the compiler instead
#                                 would move the error from patch time to compile
#                                 time, where its message names bytecode.
#   opt         REFUSED by CLI -> optional positionals stay refused because their
#                                 defaults live in the AOT function the
#                                 replacement stands in for.
#
#   ANY arm printing the release's own OLD- value while the CLI reported success
#   is the fold/dispatch class of failure, NOT an arity result -- stop and run
#   assert_result_consumed.sh before attributing it.
#
# All four arms share ONE release, so a refusal cannot be blamed on differently
# built release bytes. Host, not device: per PARITY's rule a host probe earns
# BUILT, and the device gate rides the next mint.
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
RB="$(cd "$HERE/.." >/dev/null 2>&1 && pwd)"
REPO="$(cd "$RB/../../.." >/dev/null 2>&1 && pwd)"
WORK=${WORK:-$(mktemp -d)}

DART_TREE=$SRC/flutter/third_party/dart
DART=$OUT/dart-sdk/bin/dart
KERNEL_PKGS="--packages=$DART_TREE/.dart_tool/package_config.json"
CLI_PKGS="${CLI_PKGS:-$REPO/.dart_tool/package_config.json}"
GEN_KERNEL=$DART_TREE/pkg/vm/bin/gen_kernel.dart
GEN_SNAPSHOT=$OUT/gen_snapshot
AOT_RUNTIME=$OUT/dartaotruntime
PKGS_DIR=$DART_TREE/third_party/pkg/core/pkgs
ENGINE=${ENGINE:-g37localhost}
CELL_ZIP=${CELL_ZIP:-$WORK/cell.zip}

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }
pass=0; fail=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1));
  else echo "  FAIL  $1: got '$2', want '$3'"; fail=$((fail+1)); fi
}

[ -x "$DART" ] || die "no host dart at $DART"
[ -x "$GEN_SNAPSHOT" ] || die "no gen_snapshot at $GEN_SNAPSHOT"

# ---- the cell, staged from the build tree ----------------------------------
#
# Same seven files and same names publish_route_b_compiler.sh uses, so the CLI's
# resolver sees production's shape. Staged, not published: this probe exists to
# decide whether the mint should happen.
note "staging an unpublished cell from $OUT"
FLUTTER_PLATFORM=${FLUTTER_PLATFORM:-/Volumes/build/route-b/published_sdk/flutter_patched_sdk_product/platform_strong.dill}
stage=$WORK/cell; mkdir -p "$stage"
cp "$OUT/zip_archives/dart2bytecode_aot.snapshot" "$stage/dart2bytecode.aot"
cp "$OUT/dartaotruntime" "$stage/dartaotruntime"
cp "$OUT/vm_platform.dill" "$stage/vm_platform.dill"
cp "$OUT/zip_archives/route_b_analyze.aot" "$stage/route_b_analyze.aot"
cp "$OUT/zip_archives/route_b_gen_kernel.aot" "$stage/route_b_gen_kernel.aot"
cp "$OUT/zip_archives/route_b_gen_dynamic_interface.aot" \
  "$stage/route_b_gen_dynamic_interface.aot"
cp "$FLUTTER_PLATFORM" "$stage/flutter_platform_strong.dill"
{
  echo "Route B compiler cell (UNPUBLISHED, staged by g37_param_abi.sh)"
  echo "engine revision : $ENGINE"
  for f in dartaotruntime dart2bytecode.aot vm_platform.dill \
    route_b_analyze.aot route_b_gen_kernel.aot \
    route_b_gen_dynamic_interface.aot flutter_platform_strong.dill; do
    echo "$f : $(shasum -a 256 "$stage/$f" | cut -d' ' -f1)"
  done
} > "$stage/PROVENANCE.txt"
(cd "$stage" && zip -q -r "$CELL_ZIP" .)

# ---- the app --------------------------------------------------------------
#
# FOUR parameter shapes on one PUBLIC class, so the accepted and refused arms run
# against identical release bytes. Public on purpose: privacy is a different goal
# and mixing them would let one pass be credited to the other.
#
# Every release body is DateTime-routed. A body returning one constant has its
# RESULT replaced at the call site, and the arm would then report a working
# mechanism as OLD -- see assert_result_consumed.sh, which exists because that
# cost six device runs.
stage_app() { # <one-body> <two-body> <named-body> <opt-body> <dir>
  local dir="$5"
  cp "$RB/packaging/container_target.dart" "$dir/lib/container_target.dart"
  ONE="$1" TWO="$2" NAMED="$3" OPT="$4" \
  python3 - "$dir/lib/container_target.dart" <<'PY'
import os, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace(
    "void _state(String when) =>",
    """class Params {
  String label = 'L';

  @pragma('vm:never-inline')
  %s

  @pragma('vm:never-inline')
  %s

  @pragma('vm:never-inline')
  %s

  @pragma('vm:never-inline')
  %s
}

void _state(String when) =>""" % (os.environ['ONE'], os.environ['TWO'],
                                 os.environ['NAMED'], os.environ['OPT']),
    1,
)
s = s.replace(
    "print('$when alpha=${alpha()} beta=${beta()}');",
    "print('$when one=${Params().one('ARG')} two=${Params().two('a', 7)} "
    "named=${Params().named(x: 'n')} opt=${Params().opt('o')}');",
    1,
)
p.write_text(s)
PY
}

package_config() { # <dir>
  cat > "$1/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$1/", "packageUri": "lib/",
    "languageVersion": "3.9" },
  { "name": "crypto", "rootUri": "file://$PKGS_DIR/crypto", "packageUri": "lib/",
    "languageVersion": "3.4" },
  { "name": "typed_data", "rootUri": "file://$PKGS_DIR/typed_data",
    "packageUri": "lib/", "languageVersion": "3.4" } ] }
JSON
}

URI=package:dynamic_modules/container_target.dart
SDK_MEMBERS='dart:core#print,dart:core#DateTime.now,dart:core#DateTime.get:millisecondsSinceEpoch'

# The RELEASE forms, all non-foldable.
R_ONE="String one(String x) => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-\$x' : 'X';"
R_TWO="String two(String a, int b) => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-\$a-\$b' : 'X';"
R_NAMED="String named({String x = 'd'}) => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-\$x' : 'X';"
R_OPT="String opt(String a, [String b = 'd']) => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-\$a\$b' : 'X';"

note "one release, four parameter shapes"
dir=$WORK/release; mkdir -p "$dir/lib" "$dir/.dart_tool"
package_config "$dir"
(
  cd "$dir"
  stage_app "$R_ONE" "$R_TWO" "$R_NAMED" "$R_OPT" "$dir"
  "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
    --packages .dart_tool/package_config.json -o prepass.dill "$URI" >/dev/null
  "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot \
    --no-link-platform --packages .dart_tool/package_config.json \
    -o import.dill "$URI" >/dev/null
  # shellcheck disable=SC2086
  "$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill prepass.dill \
    --private-dill import.dill --policy p2 --out di.yaml \
    --manifest manifest.json --sdk-members "$SDK_MEMBERS" 2>&1 \
    | sed -n 's/^/    /p'
  "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
    --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
    -o base.dill "$URI" >/dev/null
  "$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
    --elf=app.aot base.dill
)
buildId=$("$AOT_RUNTIME" "$dir/app.aot" | sed -n 's/^BUILD_ID //p')
[ -n "$buildId" ] || die "no release build id"
echo "    release: $buildId"
echo "    baseline: $("$AOT_RUNTIME" "$dir/app.aot" | sed -n 's/^before //p')"

# ---- arms -----------------------------------------------------------------
arm() { # <label> <one> <two> <named> <opt> <field> <want value|REFUSED>
  local label="$1" field="$6" want="$7"
  local armDir="$dir/$label"; mkdir -p "$armDir/lib" "$armDir/.dart_tool"
  note "$label"
  package_config "$armDir"
  ( cd "$armDir"
    stage_app "$2" "$3" "$4" "$5" "$armDir"
    "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
      --packages .dart_tool/package_config.json --dynamic-interface "$dir/di.yaml" \
      -o "$armDir/patched.dill" "$URI" >/dev/null )

  set +e
  "$DART" --packages="$CLI_PKGS" "$HERE/cli_lower.dart" \
    "$CELL_ZIP" "$dir/base.dill" "$armDir/patched.dill" "$dir/import.dill" \
    "$buildId" "$armDir/cli" "$dir" "$OUT/vm_platform.dill" "$ENGINE" \
    "$dir/manifest.json" > "$armDir/cli.log" 2>&1
  set -e
  sed -n 's/^/    /p' "$armDir/cli.log" | tail -6

  if [ "$want" = REFUSED ]; then
    local got='<the CLI did not refuse>'
    grep -qi 'refus\|unsupported' "$armDir/cli.log" && got=refused
    check "$label: the CLI refuses at patch time" "$got" refused
    { grep -m1 -io "takes [a-z ]*parameters" "$armDir/cli.log" || true; } \
      | sed 's/^/        reason: /'
    return
  fi

  [ -f "$armDir/cli/replacement_0.dart" ] && \
    sed -n 's/^/    | /p' "$armDir/cli/replacement_0.dart" | tail -2
  local container
  container=$(sed -n 's/^ *OUT=//p' "$armDir/cli.log")
  if [ ! -f "$container" ]; then
    check "$label: the CLI produced a container" 'no' 'yes'; return
  fi
  set +e
  "$AOT_RUNTIME" "$dir/app.aot" "$container" > "$armDir/run.log" 2>&1
  set -e
  grep -q '^APPLY' "$armDir/run.log" && sed -n 's/^/    /p; /^APPLY/q' "$armDir/run.log" | tail -1
  local got
  got=$(sed -n "s/^after .*$field=\([^ ]*\).*/\1/p" "$armDir/run.log" | tail -1)
  check "$label: the app reads the patched value" "${got:-<none>}" "$want"
  [ "$got" = "$want" ] || sed 's/^/      /' "$armDir/run.log" | head -6
}

# ONE source parameter: G3.7's core claim.
arm one_param "String one(String x) => 'NEW-\$x';" \
  "$R_TWO" "$R_NAMED" "$R_OPT" one NEW-ARG

# TWO, of different types, to prove order and typing rather than mere arity.
arm two_params "$R_ONE" "String two(String a, int b) => 'NEW-\$a-\$b';" \
  "$R_NAMED" "$R_OPT" two NEW-a-7

# The two refusals. Same release bytes, so these are controls.
arm named_refused "$R_ONE" "$R_TWO" \
  "String named({String x = 'd'}) => 'NEW-\$x';" "$R_OPT" named REFUSED

arm opt_refused "$R_ONE" "$R_TWO" "$R_NAMED" \
  "String opt(String a, [String b = 'd']) => 'NEW-\$a\$b';" opt REFUSED

echo
echo "--------------------------------------------------"
echo "G3.7 parameter ABI: $pass passed, $fail failed"
echo "work dir kept: $WORK"
[ "$fail" -eq 0 ] || exit 1
