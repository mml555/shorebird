#!/usr/bin/env bash
# cspell:words dartaotruntime sbrbptch
#
# c1_lowered.sh -- the AUTOMATIC producer must reach rung C1's result.
#
# c_receiver.sh proved C1 with a HAND-WRITTEN replacement:
#
#     String value(RouteBThing self) => self.label;
#
# while the app source it stood in for declares an ordinary instance getter
# method with no parameters. This asks whether the CLI's analyzer and producer,
# given only the two kernels, arrive at that same replacement on their own --
# and whether the container they build still runs to NEW-C1.
#
# Two separate claims, checked separately, because they fail for different
# reasons:
#
#   TEXT      the lowered source is exactly the source that was device-proven
#             -> a lowering bug
#   BEHAVIOUR the container installs and the app's own call site reads NEW-C1
#             -> a compile, packing or attach bug
#
# The text check is the one that makes the behaviour check meaningful: identical
# source through the same cell is identical payload semantics by construction,
# so a passing pair says the automatic path reproduces the hand-packed one
# rather than merely also working.
#
# Host, not device: this is a producer question. The device round-trip is the
# separate, later proof, and it runs the true Flutter platform.
#
#   c1_lowered.sh
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
# The cell for the engine whose dart2bytecode accepts a one-parameter entry
# point -- the whole lowering depends on that relaxation.
ENGINE=${ENGINE:-54fb8772a037aaec97f3f472d33c96a8529b2dec}
CELL_ZIP=${CELL_ZIP:-$REPO/selfhost/cdn/overlay/download.shorebird.dev/shorebird/$ENGINE/route-b-compiler-darwin-arm64.zip}

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }
pass=0; fail=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1));
  else echo "  FAIL  $1"; echo "        got : $2"; echo "        want: $3";
    fail=$((fail+1)); fi
}

[ -x "$DART" ] || die "no host dart at $DART"
[ -f "$CELL_ZIP" ] || die "no compiler cell at $CELL_ZIP"
[ -f "$CLI_PKGS" ] || die "no package config at $CLI_PKGS (run dart pub get)"
mkdir -p "$WORK/lib" "$WORK/.dart_tool"

# The same program rung C ran, so a difference here is the producer and not the
# fixture. `stage <body>` writes the target class with the given method body.
stage() { # <method body source>
  cp "$RB/packaging/container_target.dart" "$WORK/lib/container_target.dart"
  BODY="$1" python3 - "$WORK/lib/container_target.dart" <<'PY'
import os, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace(
    "void _state(String when) =>",
    """class RouteBThing {
  String label = 'NEW-C1';

  @pragma('vm:never-inline')
  %s
}

void _state(String when) =>""" % os.environ['BODY'],
    1,
)
s = s.replace(
    "print('$when alpha=${alpha()} beta=${beta()}');",
    "print('$when alpha=${alpha()} beta=${beta()} "
    "thing=${RouteBThing().value()}');",
    1,
)
p.write_text(s)
PY
}

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

note "release -- the instance method the patch will replace"
# Routed through DateTime.now() for the usual reason: a literal is
# constant-folded even under vm:never-inline, and a working mechanism would
# then report OLD.
stage "String value() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-c' : 'X';"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o prepass.dill "$URI" >/dev/null
"$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill prepass.dill \
  --out di.yaml --sdk-members \
  'dart:core#print,dart:core#DateTime.now,dart:core#DateTime.get:millisecondsSinceEpoch' \
  2>/dev/null
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
  -o base.dill "$URI" >/dev/null
"$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
  --elf=app.aot base.dill
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot \
  --no-link-platform --packages .dart_tool/package_config.json \
  -o import.dill "$URI" >/dev/null
BUILD_ID=$("$AOT_RUNTIME" app.aot | sed -n 's/^BUILD_ID //p')
[ -n "$BUILD_ID" ] || die "no release build id"
echo "  release: $BUILD_ID"
echo "  engine : $ENGINE"

# Both supported spellings, run through the whole path separately. They are the
# SAME kernel node and differ only in the lexical edit -- an insert versus a
# replace -- so one passing says nothing about the other.
arm() { # <label> <patch method source>
  local label="$1" body="$2"
  local dir="$WORK/$label"; mkdir -p "$dir"

  note "$label -- patch source: $(printf '%s' "$body" | tr -s ' \n' ' ')"
  stage "$body"
  "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
    --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
    -o "$dir/patched.dill" "$URI" >/dev/null

  # Not fatal on its own: the producer writes the replacement source BEFORE
  # compiling it, so a compile failure still leaves the text to check -- and the
  # text is what distinguishes a lowering bug from a cell that is too old.
  set +e
  "$DART" --packages="$CLI_PKGS" "$HERE/cli_lower.dart" \
    "$CELL_ZIP" "$WORK/base.dill" "$dir/patched.dill" "$WORK/import.dill" \
    "$BUILD_ID" "$dir/cli" "$WORK" "$OUT/vm_platform.dill" "$ENGINE" \
    2>&1 | tee "$dir/cli.log" | sed 's/^/  /'
  set -e

  local got
  if [ -f "$dir/cli/replacement_0.dart" ]; then
    sed 's/^/  | /' "$dir/cli/replacement_0.dart"
    # Trimmed: the slice keeps the declaration's own indentation and its
    # annotations, which are the source's, not the lowering's.
    got=$(grep -m1 'String value' "$dir/cli/replacement_0.dart" \
      | sed 's/^[[:space:]]*//' || true)
  else
    got='<the producer wrote no replacement source>'
  fi
  check "$label: lowered source is the source rung C1 proved" \
    "$got" 'String value(RouteBThing self) => self.label;'

  local container
  container=$(sed -n 's/^ *OUT=//p' "$dir/cli.log")
  if [ ! -f "$container" ]; then
    echo "  FAIL  $label: the CLI produced no container"; fail=$((fail+1)); return
  fi

  set +e
  "$AOT_RUNTIME" app.aot "$container" > "$dir/run.log" 2>&1
  set -e
  grep -q '^APPLY' "$dir/run.log" && echo "  $(grep -m1 '^APPLY' "$dir/run.log")"
  # The app's OWN call site, not the reference installer's smoke invocation:
  # that one enters the target from C++ with a null receiver, which for a body
  # dereferencing `self` throws NoSuchMethodError. Correct, and unrelated.
  local thing
  thing=$(sed -n 's/^after .*thing=//p' "$dir/run.log" | tail -1)
  echo "  thing = ${thing:-<no value; the process did not get that far>}"
  check "$label: the app reads the patched value" "$thing" 'NEW-C1'
  [ "$thing" = 'NEW-C1' ] || sed 's/^/      /' "$dir/run.log" | head -8
}

# An ordinary bare getter -- what an app author actually writes. Nobody types
# `self` here; the lowering has to introduce both the parameter and the prefix.
arm bare_getter "String value() => label;"

# The explicit spelling. Same kernel node, different edit: `this.` is REPLACED
# rather than prefixed, and getting that wrong yields `this.self.label`.
arm explicit_this "String value() => this.label;"

echo
echo "--------------------------------------------------"
echo "C1 via the automatic producer: $pass passed, $fail failed"
echo "work dir kept: $WORK"
[ "$fail" -eq 0 ] || exit 1
