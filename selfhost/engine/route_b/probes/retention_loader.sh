#!/usr/bin/env bash
# cspell:words dartaotruntime prepass sbrb rtdep expectcheck noinline
#
# retention_loader.sh -- what does the REAL loader do with a replacement body
# that names a dependency symbol the release's dynamic interface does not list,
# and what does the CLI's retention check (analysis 18) say about the same body?
#
# Host only: a release container is built with a dependency package (`rtdep`)
# standing in for Flutter, a real interface (gen_dynamic_interface, policy p2),
# a real AOT snapshot (gen_snapshot), and each arm's body is compiled by
# dart2bytecode and ATTACHED to that snapshot by the reference installer
# (packaging/container_target.dart), exactly as fw_use_binding.sh does. The
# same body, as a patched whole program, goes through the analyzer and the
# CLI's `RouteBRetention`, so each row reads "loader | check".
#
# The release's own code (rtdep/lib/rtdep.dart is the dependency, the container
# calls it):
#   named by the app      Box(1,2)  Box.describe  topUsed  pick  Shape.name
#   reached, NOT named    Box.show (describe calls it), Box.a (show reads it),
#                         Box.fmt, Box.fmt2 (never-inline), topInner,
#                         Circle and Circle.name (pick allocates it)
#   never reached         Box.b  Box.sum  Box.twice  Box.named  Box.unused
#                         Box.counter  class Other  topUnused
#
# Outcome per arm: BOUND (the replacement ran), ABORT (the loader's FATAL:
# "Unable to find ..."), THROWS (loaded, failed when run), OTHER, or
# COMPILE-REFUSED. The probe PRINTS the table and fails only when an arm's
# outcome differs from the recorded EXPECT (so a runtime change shows up).
#
#   OUT=$HOME/shorebird-engine/flutter/engine/src/out/host_release_arm64_ddm \
#     retention_loader.sh <route_b dir>
set -euo pipefail
SRC=${SRC:-$HOME/shorebird-engine/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64_ddm}
HERE=$(cd "$(dirname "$0")" && pwd)
RB=$1
REPO=$(cd "$RB/../../.." && pwd)
WORK=${WORK:-$REPO/../tmp/retention_loader_work}
rm -rf "$WORK"; mkdir -p "$WORK/lib" "$WORK/rtdep/lib" "$WORK/.dart_tool"
WORK=$(cd "$WORK" && pwd)
DART_TREE=$SRC/flutter/third_party/dart
DART=$OUT/dart-sdk/bin/dart
KERNEL_PKGS="--packages=$DART_TREE/.dart_tool/package_config.json"
GEN_KERNEL=$DART_TREE/pkg/vm/bin/gen_kernel.dart
DART2BC=$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart
GEN_SNAPSHOT=$OUT/gen_snapshot
AOT_RUNTIME=$OUT/dartaotruntime
PKGS_DIR=$DART_TREE/third_party/pkg/core/pkgs
CLI_PKGS=$REPO/.dart_tool/package_config.json
PLAT=$OUT/vm_platform.dill
cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$WORK/", "packageUri": "lib/", "languageVersion": "3.9" },
  { "name": "rtdep", "rootUri": "file://$WORK/rtdep/", "packageUri": "lib/", "languageVersion": "3.9" },
  { "name": "crypto", "rootUri": "file://$PKGS_DIR/crypto", "packageUri": "lib/", "languageVersion": "3.4" },
  { "name": "typed_data", "rootUri": "file://$PKGS_DIR/typed_data", "packageUri": "lib/", "languageVersion": "3.4" } ] }
JSON
URI=package:dynamic_modules/container_target.dart
cd "$WORK"

cat > rtdep/lib/rtdep.dart <<'DART'
class Box {
  final int a;
  final int b;
  Box(this.a, this.b);
  Box.named(this.a) : b = 0;
  int get sum => a + b;
  int twice() => a * 2;
  String describe() => show();
  String show() => '[${fmt(a)}${fmt2(a)}]';
  static String fmt(int x) => 'v$x';
  @pragma('vm:never-inline')
  static String fmt2(int x) => 'w$x';
  static String unused(int x) => 'u$x';
  static int counter = 0;
}

class Other {
  const Other();
  String hi() => 'hi';
}

abstract class Shape {
  String name();
}

class Circle extends Shape {
  @override
  String name() => 'circle';
}

class Square extends Shape {
  @override
  String name() => 'square';
}

Shape pick(int i) => i.isEven ? Circle() : Square();

String topUsed() => topInner();
String topInner() => 'top';
String topUnused() => 'tu';
DART

cp "$RB/packaging/container_target.dart" lib/container_target.dart
python3 - lib/container_target.dart <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace("import 'dart:io';", "import 'dart:io';\nimport 'package:rtdep/rtdep.dart';", 1)
old = "void _state(String when) => print('$when alpha=${alpha()} beta=${beta()}');"
assert old in s
s = s.replace(old, "void _state(String when) => print('$when alpha=${alpha()} beta=${beta()} box=${Box(1, 2).describe()} top=${topUsed()} pick=${pick(3).name()}');")
p.write_text(s)
PY
cp lib/container_target.dart release_source.dart

echo "==> release: interface, kernels, snapshot"
"$DART" "$GEN_KERNEL" --platform "$PLAT" --aot --packages .dart_tool/package_config.json -o prepass.dill "$URI" >/dev/null
"$DART" "$GEN_KERNEL" --platform "$PLAT" --no-aot --no-link-platform --packages .dart_tool/package_config.json -o import.dill "$URI" >/dev/null
"$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill prepass.dill --private-dill import.dill --policy p2 --include package:dynamic_modules/ --out di.yaml --manifest manifest.json --sdk-members \
  'dart:core#print,dart:core#DateTime.now,dart:core#DateTime.get:millisecondsSinceEpoch' 2>&1 | sed 's/^/  /'
"$DART" "$GEN_KERNEL" --platform "$PLAT" --aot --packages .dart_tool/package_config.json --dynamic-interface di.yaml -o base.dill "$URI" >/dev/null
"$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf --elf=app.aot base.dill
BUILD_ID=$("$AOT_RUNTIME" app.aot | sed -n 's/^BUILD_ID //p')
grep -A2 'rtdep' di.yaml | head -40 | sed 's/^/  di: /'

FAILS=0
ROWS=()
arm() {
  local label=$1 expect=$2 expectcheck=$3 expr=$4 import=${5:-}
  [ -z "${ONLY:-}" ] || [[ $label =~ $ONLY ]] || return 0
  local d=$WORK/arm_$label; mkdir -p "$d"
  echo; echo "==> $label: $expr"
  # The patched whole program, for the analyzer and the CLI.
  cp release_source.dart lib/container_target.dart
  EXPR="$expr" python3 - lib/container_target.dart <<'PY'
import os, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = "String alpha() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-a' : 'X';"
assert old in s
p.write_text(s.replace(old, "String alpha() => 'NEW-a${%s}';" % os.environ['EXPR']))
PY
  local check="HARNESS-FAILED"
  if "$DART" "$GEN_KERNEL" --platform "$PLAT" --aot --packages .dart_tool/package_config.json --dynamic-interface di.yaml -o "$d/patched.dill" "$URI" >"$d/gen_kernel.log" 2>&1 &&
     "$DART" $KERNEL_PKGS "$RB/coverage/analyze_coverage.dart" --include package:dynamic_modules/ --base-dill base.dill --patched-dill "$d/patched.dill" --out "$d/coverage.json" >"$d/analyze.log" 2>&1; then
    "$DART" --packages="$CLI_PKGS" "$HERE/cli_retention.dart" "$d/coverage.json" di.yaml manifest.json > "$d/verdict.log" 2>&1 || true
    if grep -F "$URI#alpha" "$d/verdict.log" | grep -q '^OK'; then check=ACCEPT
    elif grep -F "$URI#alpha" "$d/verdict.log" | grep -q '^REFUSED'; then check=REFUSE
    else check="NO-VERDICT"; fi
  fi
  # The loader.
  printf "import 'package:rtdep/rtdep.dart';\n%s\n@pragma('dyn-module:entry-point')\nString alpha() => 'NEW-a\${%s}';\n" "$import" "$expr" > "$d/repl.dart"
  local outcome
  if ! "$DART" "$DART2BC" --platform "$PLAT" --import-dill import.dill -o "$d/repl.bytecode" "$d/repl.dart" >"$d/compile.log" 2>&1; then
    outcome=COMPILE-REFUSED
  else
    "$DART" "$RB/packaging/pack_patch.dart" --release-build-id "$BUILD_ID" --out "$d/patch.sbrb" --target "$URI#alpha=$d/repl.bytecode" >/dev/null 2>&1
    set +e; "$AOT_RUNTIME" app.aot "$d/patch.sbrb" > "$d/run.log" 2>&1; set -e
    if grep -q 'after  alpha=NEW-a' "$d/run.log"; then outcome=BOUND
    elif grep -q 'Unable to find' "$d/run.log"; then outcome=ABORT
    elif grep -qi 'NoSuchMethod\|Unhandled exception' "$d/run.log"; then outcome=THROWS
    else outcome=OTHER; fi
    grep -m2 'Unable to find\|NoSuchMethod\|Unhandled' "$d/run.log" | sed 's/^/  loader: /' || true
    grep -m1 'after  alpha=' "$d/run.log" | sed 's/^/  ran: /' || true
  fi
  grep -F "$URI#alpha" "$d/verdict.log" 2>/dev/null | sed 's/^/  cli: /' | cut -c1-300 || true
  local status=PASS
  [ "$outcome" = "$expect" ] && [ "$check" = "$expectcheck" ] || { status="FAIL(expected $expect/$expectcheck)"; FAILS=$((FAILS+1)); }
  ROWS+=("$label|$outcome|$check|$status")
}

# arm <label> <expected loader outcome> <expected CLI check> <expression> [import]
arm control                BOUND   ACCEPT "''"
arm sdk_instance_unnamed   THROWS  ACCEPT "'abc'.toUpperCase()"
arm inst_named_ctor_box    BOUND   ACCEPT "Box(1, 2).describe()"
arm inst_reached_unnamed   THROWS  ACCEPT "Box(1, 2).show()"
arm inst_field_reached     THROWS  ACCEPT "Box(1, 2).a"
arm inst_field_unread      THROWS  ACCEPT "Box(1, 2).b"
arm inst_getter_uncalled   THROWS  ACCEPT "Box(1, 2).sum"
arm inst_method_uncalled   THROWS  ACCEPT "Box(1, 2).twice()"
arm static_reached         ABORT   REFUSE "Box.fmt(3)"
arm static_unreached       ABORT   REFUSE "Box.unused(3)"
arm static_field_untouched ABORT   REFUSE "Box.counter"
arm ctor_never_called      ABORT   REFUSE "Box.named(3).a"
arm class_never_used       ABORT   REFUSE "const Other().hi()"
arm top_reached            ABORT   REFUSE "topInner()"
arm top_unused             ABORT   REFUSE "topUnused()"
arm sdk_static_unnamed     ABORT   REFUSE "int.parse('1')"
arm local_type_only        BOUND   ACCEPT "(() { Other? o; return o == null; })()"
# `never-inline` does not keep a static nothing names (still ABORT).
arm static_noinline_reached ABORT  REFUSE "Box.fmt2(3)"
# KNOWN CONSERVATIVE REFUSAL: the snapshot HAS this class (pick allocates it),
# the loader binds, and the interface does not name it, so nothing at patch time
# says it is there. Recorded so nobody reads the check as exact.
arm class_allocated_unnamed BOUND  REFUSE "(pick(2) as Circle).name()"

echo; echo "== TABLE (loader outcome | CLI retention check)"
printf '  %-26s %-16s %-8s %s\n' arm loader check status
for r in "${ROWS[@]}"; do IFS='|' read -r a b c d <<<"$r"; printf '  %-26s %-16s %-8s %s\n' "$a" "$b" "$c" "$d"; done
[ "$FAILS" -eq 0 ] && echo "ALL AS RECORDED" || { echo "$FAILS DIFFER"; exit 1; }
