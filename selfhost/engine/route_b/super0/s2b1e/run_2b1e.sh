#!/usr/bin/env bash
#
# run_2b1e.sh -- can the RELEASE build make an exact super target an AOT
# compilation ROOT, rather than merely a retained name?
#
# Arm C of 2B.1d is the negative control, unchanged: the mixin-application copy
# of `Ticker.close` is retained and nameable, has no compiled code, and a
# DirectCall to it aborts the release at
# `compiler.cc:1152: Attempt to compile function …`.
#
# The observable is never "the pragma is present" or "the interface lists it".
# It is: does the DirectCall bind and execute without asking for compilation.
#
# The patch is identical in every variant (s2b1d/armC_patch.dart). Only the
# RELEASE changes.
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
WORK="${WORK:-$(mktemp -d)}"

DART_TREE="$SRC/flutter/third_party/dart"
DART="$OUT/dart-sdk/bin/dart"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
DART2BC="$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart"
GENERATOR="$DART_TREE/pkg/dart2bytecode/lib/bytecode_generator.dart"
GEN_SNAPSHOT="$OUT/gen_snapshot"
AOT_RUNTIME="$OUT/dartaotruntime"
URI=package:dynamic_modules/target.dart
PATCH="$HERE/../s2b1d/armC_patch.dart"
mkdir -p "$WORK"; fail=0
note() { echo; echo "==> $*"; }

BACKUP="$(mktemp)"; cp "$GENERATOR" "$BACKUP"
before=$(shasum -a 256 "$GENERATOR" | cut -d' ' -f1)
restore() { cp "$BACKUP" "$GENERATOR"
  after=$(shasum -a 256 "$GENERATOR" | cut -d' ' -f1); rm -f "$BACKUP"
  [ "$after" = "$before" ] || { echo "FATAL: generator not restored" >&2; exit 3; }
  echo; echo "dart2bytecode source restored, sha256 $after"; }
trap restore EXIT
python3 "$HERE/../s2b1/apply_0015.py" "$GENERATOR" >/dev/null

variant() { # <name> <releaseSrc> [markClass markMember]
  local name=$1 rel=$2 markClass=${3:-} markMember=${4:-}
  local W="$WORK/$name"; mkdir -p "$W/lib" "$W/.dart_tool"
  cat > "$W/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$W/",
    "packageUri": "lib/", "languageVersion": "3.9" } ] }
JSON
  note "$name  (release: $(basename "$rel"))"
  cp "$rel" "$W/lib/target.dart"
  ( cd "$W" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
      --packages .dart_tool/package_config.json -o discover.dill "$URI" ) >/dev/null
  ( cd "$W" && "$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
      "$HERE/../../gen_dynamic_interface.dart" --dill discover.dill --out di.yaml ) >/dev/null
  ( cd "$W" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
      --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
      -o target.dill "$URI" ) >/dev/null
  if [ -n "$markClass" ]; then
    "$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
      "$HERE/e2_mark_clone.dart" "$W/target.dill" "$markClass" "$markMember" \
      | sed 's/^/    /'
  fi
  set +e
  "$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
    --elf="$W/target.aot" "$W/target.dill" > "$W/snapshot.log" 2>&1
  local src=$?
  set -e
  if [ "$src" -ne 0 ]; then
    # A TOOL FAULT MUST NOT BE SCORABLE. E2's kernel round-trip drops AOT
    # metadata even with every repository registered, and gen_snapshot then
    # blames the frontend. That says nothing about whether marking the clone
    # would work, so it is reported as a harness fault and NOT counted.
    printf '    HARNESS FAULT               gen_snapshot refused the rewritten dill\n'
    grep -oE 'error: .*' "$W/snapshot.log" | head -1 | sed 's/^/      /'
    printf '    VERDICT                     NOT ESTABLISHED (tool, not product)\n'
    echo 0 > "$W/size"
    return
  fi
  local size; size=$(wc -c < "$W/target.aot" | tr -d ' ')

  cp "$PATCH" "$W/lib/target.dart"
  ( cd "$W" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
      --no-aot --no-link-platform \
      --packages .dart_tool/package_config.json -o patched_noaot.dill "$URI" ) >/dev/null
  ( cd "$W" && "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
      --packages .dart_tool/package_config.json -o patched_aot.dill "$URI" ) >/dev/null
  cp "$rel" "$W/lib/target.dart"

  local off
  off=$("$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
      "$HERE/../s2b0/dump_sites.dart" "$PATCH" "$OUT/vm_platform.dill" \
      package:dynamic_modules/ "$W/patched_aot.dill" | grep '^{' \
      | python3 -c "
import sys,json
for l in sys.stdin:
    d=json.loads(l)
    if d['site']=='Leaf.target' and d['member']=='close': print(d['fileOffset']); break
else: print('MISSING')")

  cat > "$W/replacement.dart" <<DART
import 'package:dynamic_modules/target.dart';

@pragma('shorebird:direct-super')
Object? routeBSuper(Object receiver, String originLibrary, String originClass,
        String originMember, String originMemberKind, int siteOffset,
        String member) =>
    throw StateError('not lowered');

@pragma('dyn-module:entry-point')
String go(Leaf self) => routeBSuper(
      self, '$URI', 'Leaf', 'target', 'Method', $off, 'close') as String;
DART
  set +e
  ( cd "$W" && "$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" \
      --import-dill patched_noaot.dill -o replacement.bytecode replacement.dart ) \
    > "$W/compile.log" 2>&1
  local crc=$?
  ( cd "$W" && "$AOT_RUNTIME" target.aot replacement.bytecode "$URI" ) \
    > "$W/run.log" 2>&1
  set -e
  local got abort
  got=$(grep -E '^patched' "$W/run.log" | sed 's/.*: //' || true)
  abort=$(grep -c 'Attempt to compile function' "$W/run.log" || true)
  printf '    release AOT size            %s bytes\n' "$size"
  printf '    compiler                    %s\n' \
    "$([ $crc -eq 0 ] && echo emitted || echo "refused (exit $crc)")"
  if [ "$abort" != "0" ]; then
    printf '    runtime                     ABORT — Attempt to compile function\n'
    grep -oE 'Attempt to compile function .*' "$W/run.log" | head -1 | sed 's/^/      /'
  fi
  printf '    execution                   %s\n' "${got:-<none>}"
  if [ "$got" = "TICKER:APP-STATE" ]; then
    printf '    VERDICT                     PASS — exact target had compiled code\n'
  else
    printf '    VERDICT                     FAIL\n'; fail=$((fail+1))
  fi
  echo "$size" > "$W/size"
}

variant control  "$HERE/../s2b1d/armC_release.dart"
variant e1_mixin_entry_point "$HERE/e1_release.dart"
variant e2_mark_clone        "$HERE/../s2b1d/armC_release.dart" '&Base&Ticker' close
variant e3_synthetic_root    "$HERE/e3_release.dart"

echo
note "size cost, against the control release"
c=$(cat "$WORK/control/size"); for v in e1_mixin_entry_point e2_mark_clone e3_synthetic_root; do
  s=$(cat "$WORK/$v/size" 2>/dev/null || echo 0)
  if [ "$s" = "0" ]; then
    printf '    %-24s %10s\n' "$v" "not established"
  else
    printf '    %-24s %10s bytes  (%+d)\n' "$v" "$s" "$((s - c))"
  fi
done
echo
echo "control is EXPECTED to fail; it is the negative control."
echo "work dir kept: $WORK"
