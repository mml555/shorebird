#!/usr/bin/env bash
# cspell:words dartaotruntime dynmod nopc
#
# private_receiver.sh -- can a patch replace a method on a PRIVATE class?
#
# In Flutter this is the common case, not an edge case: a StatefulWidget's State
# class is private by convention, so `_FooState.initState` is the shape a real
# patch usually targets. The compatibility study measured it -- seven of fourteen
# blocked targets in its pilot were methods of one `_FullscreenVideoViewerState`.
#
# TWO WALLS, AND THIS PROBE EXISTS TO SHOW THEY ARE BOTH REAL. Neither half is
# sufficient, and each fails in a different place, which is exactly why they were
# mistaken for one problem:
#
#   G3.6c  COMPILE.  `_FooState self` cannot be written in the replacement's
#          synthetic library at all -- privacy is library-scoped. The producer
#          emits `dynamic self` instead, so the private class is never named.
#   G3.6d  RUN TIME.  A `library:` interface item retains PUBLIC classes and
#          members only, so a private class and its members are retained by
#          nothing and the AOT precompiler removes them outright. The generator
#          now emits a `class:` item per private class.
#
# So the arms are a matched pair. `retained` is the product path. `not_retained`
# regenerates the SAME release with --no-private-classes and must FAIL -- if it
# passed, the retention half would be decoration and the interface could be
# narrowed. A negative control is the only way to know a fix is load-bearing.
#
# Host, not device: this is a producer-and-retention question. The device
# round-trip is separate, and per PARITY.md §3 a passing run here earns BUILT.
#
#   private_receiver.sh
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
# The v6 cell: its analyzer reports receiver writes, and the CLI pins
# supportedRouteBAnalysisVersion to 6. An older cell is refused by the resolver,
# which is the invariant keeping a patch on the toolchain that built its release.
ENGINE=${ENGINE:-aa9155840d6c1e71b015bbcff1e06eaea7e73e17}
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

# The target class is PRIVATE, which is the whole point. `label` is public, so
# the body needs no private MEMBER -- this probe isolates the private-CLASS wall
# from the private-member one, which is a separate goal (G3.6e).
stage() { # <method body source>
  cp "$RB/packaging/container_target.dart" "$WORK/lib/container_target.dart"
  BODY="$1" python3 - "$WORK/lib/container_target.dart" <<'PY'
import os, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace(
    "void _state(String when) =>",
    """class _Hidden {
  String label = 'NEW-PRIV';

  @pragma('vm:never-inline')
  %s
}

void _state(String when) =>""" % os.environ['BODY'],
    1,
)
s = s.replace(
    "print('$when alpha=${alpha()} beta=${beta()}');",
    "print('$when alpha=${alpha()} beta=${beta()} "
    "hidden=${_Hidden().value()}');",
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
SDK_MEMBERS='dart:core#print,dart:core#DateTime.now,dart:core#DateTime.get:millisecondsSinceEpoch'
cd "$WORK"

# `arm <label> <extra gen_dynamic_interface args> <want value>`
#
# The release is rebuilt PER ARM rather than shared, because the interface is an
# input to the release kernel: the two arms differ in what the RELEASE retained,
# not in what the patch asked for. Sharing a release would measure nothing.
arm() { # <label> <interface flags> <expected app value>
  local label="$1" diFlags="$2" wantValue="$3"
  local dir="$WORK/$label"; mkdir -p "$dir/lib" "$dir/.dart_tool"
  # Each arm is its own package root, because each builds its own release.
  cat > "$dir/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$dir/", "packageUri": "lib/",
    "languageVersion": "3.9" },
  { "name": "crypto", "rootUri": "file://$PKGS_DIR/crypto", "packageUri": "lib/",
    "languageVersion": "3.4" },
  { "name": "typed_data", "rootUri": "file://$PKGS_DIR/typed_data",
    "packageUri": "lib/", "languageVersion": "3.4" } ] }
JSON

  note "$label -- interface flags: ${diFlags:-<none, the product path>}"
  (
    cd "$dir"
    # RELEASE: the method returns OLD. Routed through DateTime.now() because a
    # literal is constant-folded even under vm:never-inline, and a working
    # mechanism would then report OLD for the wrong reason.
    WORK="$dir" stage "String value() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-priv' : 'X';"

    "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
      --packages .dart_tool/package_config.json -o prepass.dill "$URI" >/dev/null
    # shellcheck disable=SC2086
    "$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill prepass.dill \
      --out di.yaml --sdk-members "$SDK_MEMBERS" $diFlags 2>&1 \
      | sed -n 's/^/    /p'
    echo "    private classes in interface: $(grep -c "class: '_" di.yaml || true)"

    "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
      --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
      -o base.dill "$URI" >/dev/null
    "$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
      --elf=app.aot base.dill
    "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot \
      --no-link-platform --packages .dart_tool/package_config.json \
      -o import.dill "$URI" >/dev/null

    # PATCH: an ordinary bare receiver read. Nobody writes `self`; the lowering
    # introduces both the parameter and the prefix, and because the enclosing
    # class is private the parameter must come out `dynamic`.
    WORK="$dir" stage "String value() => label;"
    "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
      --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
      -o patched.dill "$URI" >/dev/null
  )

  local buildId
  buildId=$("$AOT_RUNTIME" "$dir/app.aot" | sed -n 's/^BUILD_ID //p')
  [ -n "$buildId" ] || die "$label: no release build id"

  set +e
  "$DART" --packages="$CLI_PKGS" "$HERE/cli_lower.dart" \
    "$CELL_ZIP" "$dir/base.dill" "$dir/patched.dill" "$dir/import.dill" \
    "$buildId" "$dir/cli" "$dir" "$OUT/vm_platform.dill" "$ENGINE" \
    2>&1 | tee "$dir/cli.log" | sed 's/^/    /'
  set -e

  local got='<the producer wrote no replacement source>'
  if [ -f "$dir/cli/replacement_0.dart" ]; then
    got=$(grep -m1 'String value' "$dir/cli/replacement_0.dart" \
      | sed 's/^[[:space:]]*//' || true)
  fi
  # The lowering is the SAME in both arms -- it is a producer decision and knows
  # nothing about retention. Asserting it in both is what proves a failure in the
  # control arm is retention and not a lowering regression.
  check "$label: private class lowered to a dynamic receiver" \
    "$got" 'String value(dynamic self) => self.label;'

  local container
  container=$(sed -n 's/^ *OUT=//p' "$dir/cli.log")
  local value='<no value; the process did not get that far>'
  if [ -n "$container" ] && [ -f "$container" ]; then
    set +e
    (cd "$dir" && "$AOT_RUNTIME" app.aot "$container" > run.log 2>&1)
    set -e
    grep -q '^APPLY' "$dir/run.log" \
      && echo "    $(grep -m1 '^APPLY' "$dir/run.log")"
    value=$(sed -n 's/^after .*hidden=\([^ ]*\).*/\1/p' "$dir/run.log" | tail -1)
    value=${value:-'<no value; the process did not get that far>'}
  fi
  echo "    hidden = $value"
  check "$label: the app reads $wantValue" "$value" "$wantValue"
  [ "$value" = "$wantValue" ] || sed 's/^/        /' "$dir/run.log" 2>/dev/null | head -6
}

note "release + patch, twice: with the private class retained, and without"

# THE PRODUCT PATH. Both halves in place.
arm retained "" NEW-PRIV

# THE NEGATIVE CONTROL. Same release, same patch, same lowering -- only the
# release's retention differs. This MUST fail to reach NEW-PRIV: the class and
# its members are retained by nothing, so the interpreted `self.label` has
# nothing to resolve against. If this arm passes, the `class:` items are
# decoration and G3.6d should be reconsidered rather than shipped.
arm not_retained --no-private-classes OLD-priv

echo
echo "--------------------------------------------------"
echo "private_receiver: $pass passed, $fail failed"
echo "work dir kept: $WORK"
[ "$fail" -eq 0 ] || exit 1
