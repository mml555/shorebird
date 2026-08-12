#!/usr/bin/env bash
# cspell:words dartaotruntime SBRBPTCH sbrb pathlib prepass
#
# d_private.sh -- Rung D: private / library-scoped identity.
#
# Stays inside the shape that already works (static, no arguments), so nothing
# here can be confused with rung C's blocker. Three questions, in order:
#
#   1. does the release interface RETAIN a private app member?
#   2. can the synthetic replacement library REFER to it?
#   3. if the spelling matches, does Dart's library-scoped private identity
#      still prevent the bind?
#
# (2) is expected to be the wall: `_privateHelper` belongs to the app library's
# identity, and the replacement is a different library. Measured rather than
# designed around.
#
# A fourth arm asks something the first three do not: can a replacement carry
# its OWN private helper? That is the practical workaround if (2) is fatal, and
# it is a different claim from patching an existing private member.
#
# On the host: a compile refusal closes the question without a device, and rung
# C showed that is where these fail.
#
#   d_private.sh
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
RETAIN_PRIVATE="${RETAIN_PRIVATE:-}" python3 - "$WORK/lib/container_target.dart" <<'PY'
import os, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()

# A public field and an instance method whose body ignores the receiver. The
# value routes through DateTime.now() for the usual reason: a literal is
# constant-folded even under vm:never-inline, and the probe would then report a
# working mechanism as OLD.
# A PRIVATE app member a patch might want to call. Nothing in the release calls
# it; it survives only if the interface retains it by name, which is exactly
# question (1).
s = s.replace(
    "void _state(String when) =>",
    """@pragma('vm:never-inline')
String _privateHelper() =>
    DateTime.now().millisecondsSinceEpoch >= 0 ? 'NEW-D' : 'X';

void _state(String when) =>""",
    1,
)

# RETAIN_PRIVATE=1 makes the RELEASE name `_privateHelper` in a branch that never
# runs, which is the pattern `helper` and `tagged` already use in the other
# fixtures: TFA keeps a member the program mentions, so the --aot prepass kernel
# still contains it and the generator can name it in the interface.
#
# WHY THIS IS A KNOB AND NOT THE DEFAULT. Question (1) of this probe -- "a private
# member NOTHING calls is tree-shaken before the interface can retain it" -- is a
# real finding and the default must keep asking it. The knob exists so the
# RETENTION wall and the PRIVACY wall can be tested one at a time; with both
# conflated, a failure says only "something about privates is wrong".
if os.environ.get('RETAIN_PRIVATE'):
    s = s.replace(
        "void _state(String when) =>",
        """// Never true. Present so TFA keeps `_privateHelper` in the --aot kernel.
final bool _keepPrivate = DateTime.now().millisecondsSinceEpoch < 0;
String _retainPrivateHelper() => _keepPrivate ? _privateHelper() : '';

void _state(String when) =>""",
        1,
    )
    s = s.replace(
        "print('BUILD_ID",
        "if (_keepPrivate) print(_retainPrivateHelper());\n  print('BUILD_ID",
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

  # RESOLVE_IN_LIBRARY=1 opts into the CFE mechanism G3.6e adds -- the compiled
  # replacement also resolves names in the app library's own namespace, which is
  # what the debugger's expression evaluation has always done. Default OFF, so
  # this probe's recorded baseline is unchanged and the two runs are comparable:
  # arm 2 (reference_private) is expected to FAIL without it and PASS with it.
  local resolveArgs=()
  if [[ -n "${RESOLVE_IN_LIBRARY:-}" ]]; then
    resolveArgs=(--resolve-private-names-in-library "$URI")
  fi

  # `${arr[@]+"${arr[@]}"}` and not `"${arr[@]}"`: this rig's bash is 3.2, where
  # expanding an EMPTY array under `set -u` is an unbound-variable error. The
  # plain form aborted this probe's first flagged run at the control arm.
  if ! "$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" \
      --import-dill import.dill ${resolveArgs[@]+"${resolveArgs[@]}"} \
      --packages .dart_tool/package_config.json \
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
    --target "$URI#alpha=$dir/repl.bytecode" >/dev/null 2>&1
  set +e
  "$AOT_RUNTIME" app.aot "$dir/patch.sbrb" > "$dir/run.log" 2>&1
  set -e

  local got
  got=$(sed -n 's/^after  alpha=\([^ ]*\).*/\1/p' "$dir/run.log" | tail -1)
  grep -q '^APPLY' "$dir/run.log" && echo "  $(grep -m1 '^APPLY' "$dir/run.log")"
  if grep -qE "Unable to find|error:" "$dir/run.log"; then
    echo "  runtime: $(grep -m1 -E 'Unable to find|error:' "$dir/run.log" | sed 's/^.*error: //')"
  fi
  echo "  alpha = ${got:-<no value; the process did not get that far>}"

  if [ "$got" = "$want" ]; then
    echo "  PASS  $label"; pass=$((pass+1))
  else
    echo "  FAIL  $label (wanted $want)"
    sed 's/^/      /' "$dir/run.log" | head -6
    fail=$((fail+1))
  fi
}

note "1. does the interface retain the private member?"
if grep -q "member: '_privateHelper'" di.yaml; then
  echo "  PASS  _privateHelper is named in the interface"; pass=$((pass+1))
else
  echo "  FAIL  _privateHelper is NOT retained"; fail=$((fail+1))
  grep -c "member:" di.yaml | sed 's/^/      named members: /'
  # Not a generator bug. The interface is generated from the --aot prepass
  # kernel, so TFA has already dropped anything unreachable; a private member
  # nothing calls is gone before the generator can name it. Public members do
  # not care, because the `library:` wildcard retains them at build time
  # without needing to be enumerated. Confirmed by running the same generator
  # against the NON-AOT kernel, where it IS present.
  echo "      (the --aot prepass tree-shook it; the non-AOT kernel still has it)"
fi

note "control — static, no args, no references"
run_arm control \
  "@pragma('dyn-module:entry-point')
String alpha() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'NEW-D-ctl' : 'X';" \
  'NEW-D-ctl'

note "2. can the replacement REFER to the app's private member?"
# Privacy in Dart is library-scoped, and the replacement is a different library
# however the name is spelled.
run_arm reference_private \
  "@pragma('dyn-module:entry-point')
String alpha() => _privateHelper();" \
  'NEW-D'

note "4. can the replacement carry its OWN private helper?"
# A different claim: not patching an existing private member, but shipping new
# private code inside the payload. This is the practical workaround if (2) is
# fatal, so it is worth knowing independently.
run_arm own_private \
  "String _mine() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'NEW-D-own' : 'X';

@pragma('dyn-module:entry-point')
String alpha() => _mine();" \
  'NEW-D-own'

echo
echo "--------------------------------------------------"
echo "probe D: $pass passed, $fail failed"
echo "work dir kept: $WORK"
[ "$fail" -eq 0 ] || exit 1
