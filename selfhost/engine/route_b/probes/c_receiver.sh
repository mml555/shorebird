#!/usr/bin/env bash
# cspell:words dartaotruntime SBRBPTCH sbrb
#
# c_receiver.sh -- Rung C, split so a failure cannot conflate two questions.
#
#   C0  does the interpreter present the instance receiver in the slot a
#       synthetic TOP-LEVEL function sees as argument 0?
#   C1  can replacement bytecode then USE that receiver to resolve a public
#       instance member against it?
#
# Split because "self.label did not work" has two completely different causes,
# and the remedies point in opposite directions: an ABI/parameter-shape problem
# is a producer question, while a member-resolution problem is a retention one.
# C0 deliberately IGNORES `self`, so it can only fail on the calling convention.
#
# On the host, because this is a VM question and not an iOS one -- the same
# dartaotruntime, the same interpreter, a minute per cycle instead of a release.
# Rung B already proved on hardware that a top-level replacement attaches to an
# instance method at all; this asks what it can see once it runs.
#
# The target program is packaging/container_target.dart, COPIED and augmented,
# so the reference installer is byte-identical to the one every other harness
# uses and the reference file itself stays untouched.
#
#   c_receiver.sh
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

[ -x "$DART" ] || die "no host dart at $DART"
mkdir -p "$WORK/lib" "$WORK/.dart_tool"

cp "$RB/packaging/container_target.dart" "$WORK/lib/container_target.dart"
python3 - "$WORK/lib/container_target.dart" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()

# A public field and an instance method whose body ignores the receiver. The
# value routes through DateTime.now() for the usual reason: a literal is
# constant-folded even under vm:never-inline, and the probe would then report a
# working mechanism as OLD.
s = s.replace(
    "void _state(String when) =>",
    """class RouteBThing {
  String label = 'NEW-C1';

  @pragma('vm:never-inline')
  String value() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-c' : 'X';
}

void _state(String when) =>""",
    1,
)
s = s.replace(
    "print('$when alpha=${alpha()} beta=${beta()}');",
    "print('$when alpha=${alpha()} beta=${beta()} thing=${RouteBThing().value()}');",
    1,
)
p.write_text(s)
PY

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

note "release, with retention declared the way a real release declares it"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o base.dill "$URI" >/dev/null
"$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill base.dill \
  --out di.yaml --sdk-members 'dart:core#print,dart:core#DateTime.now,dart:core#DateTime.get:millisecondsSinceEpoch' 2>/dev/null
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
  -o release.dill "$URI" >/dev/null
"$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
  --elf=app.aot release.dill
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot \
  --no-link-platform --packages .dart_tool/package_config.json \
  -o import.dill "$URI" >/dev/null
BUILD_ID=$("$AOT_RUNTIME" app.aot | sed -n 's/^BUILD_ID //p')
[ -n "$BUILD_ID" ] || die "no release build id"

run_arm() { # <label> <replacement source, pragma included> <expected value>
  local label="$1" body="$2" want="$3"
  local dir="$WORK/$label"; mkdir -p "$dir"

  printf "import '%s';\n\n%s\n" "$URI" "$body" > "$dir/repl.dart"

  if ! "$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" \
      --import-dill import.dill --packages .dart_tool/package_config.json \
      -o "$dir/repl.bytecode" "$dir/repl.dart" > "$dir/compile.log" 2>&1; then
    echo "  compile: REFUSED"
    # `|| true`: with `set -o pipefail` a non-matching grep aborts the whole
    # script, which silently truncated this probe's first run after one arm.
    { grep -m2 -iE "error|should be|exception" "$dir/compile.log" || true; } \
      | sed 's/^/      /'
    echo "  FAIL  $label (did not compile)"; fail=$((fail+1)); return
  fi

  "$DART" "$RB/packaging/pack_patch.dart" --release-build-id "$BUILD_ID" \
    --out "$dir/patch.sbrb" \
    --target "$URI#RouteBThing.value=$dir/repl.bytecode" >/dev/null 2>&1
  set +e
  "$AOT_RUNTIME" app.aot "$dir/patch.sbrb" > "$dir/run.log" 2>&1
  set -e

  local got
  got=$(sed -n 's/^after .*thing=//p' "$dir/run.log" | tail -1)
  grep -q '^APPLY' "$dir/run.log" && echo "  $(grep -m1 '^APPLY' "$dir/run.log")"
  if grep -qE "Unable to find|error:" "$dir/run.log"; then
    echo "  runtime: $(grep -m1 -E 'Unable to find|error:' "$dir/run.log" | sed 's/^.*error: //')"
  fi
  echo "  thing = ${got:-<no value; the process did not get that far>}"

  if [ "$got" = "$want" ]; then
    echo "  PASS  $label"; pass=$((pass+1))
  else
    echo "  FAIL  $label (wanted $want)"
    sed 's/^/      /' "$dir/run.log" | head -6
    fail=$((fail+1))
  fi
}

note "control — rung B's shape, no parameter, receiver ignored"
run_arm control \
  "@pragma('dyn-module:entry-point')
String value() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'NEW-B' : 'X';" \
  'NEW-B'

note "C0 — explicit first parameter, deliberately IGNORED"
# Only the calling convention can make this fail: the body never touches self.
run_arm c0 \
  "@pragma('dyn-module:entry-point')
String value(RouteBThing self) => DateTime.now().millisecondsSinceEpoch >= 0 ? 'NEW-C0' : 'X';" \
  'NEW-C0'

note "C0b — a synthetic INSTANCE method, the other way to carry a receiver"
# The message C0 fails with says "static no-argument", so this asks whether the
# entry-point rule rejects instance-ness as well as arity. If both are refused,
# the boundary is the compiler's entry-point contract and not the interpreter.
run_arm c0b \
  "class RouteBReplacement {
  @pragma('dyn-module:entry-point')
  String value() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'NEW-C0b' : 'X';
}" \
  'NEW-C0b'

note "C1 — the receiver actually used, public member"
# Public `label`, never `_label`: private identity is library-scoped and belongs
# to rung D, where it would contaminate this result.
run_arm c1 \
  "@pragma('dyn-module:entry-point')
String value(RouteBThing self) => self.label;" \
  'NEW-C1'

echo
echo "--------------------------------------------------"
echo "probe C: $pass passed, $fail failed"
echo "work dir kept: $WORK"
[ "$fail" -eq 0 ] || exit 1
