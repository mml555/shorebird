#!/usr/bin/env bash
#
# g41d_injected_define_patch.sh -- G4.1c's DISCRIMINATING arm.
#
# THE ONE QUESTION: can a real, reachable Dart program whose behaviour depends on
# a Flutter-injected define be analysed and patched correctly, end to end, by the
# G4.1c path?
#
# WHY A NEW PROBE. g41c proved the DEFECT and the fix at the kernel layer, on a
# throwaway app. Release 40 of airgap_app proved the CLI still traverses the real
# release -> patch path and could prove nothing else, because that fixture reads
# none of the six. Neither answers the question above, which spans two DIFFERENT
# links:
#
#   link 1  ANALYSIS   -- do Route B's prepass/import kernels describe the same
#                         program Flutter compiles? (arms 1-2)
#   link 2  REPLACEMENT-- is a PATCH BODY compiled with the same defines the
#                         release around it holds? (arms 3-4)
#
# Link 2 is a different mechanism from link 1 and is NOT fixed by threading the
# release kernels. `route_b_producer.dart:169` feeds the replacement compiler
# `buildConfig.compilerArgs`, and `route_b_build_config.dart:345` builds those
# from `effectiveDefines` ALONE -- which G4.1c deliberately leaves the injected
# six out of, on the argument that a release and a patch on one pinned cell
# always agree on them. That argument is sound for COMPARISON and wrong for
# PROPAGATION, and arm 3 is what makes the difference observable.
#
# ARMS THAT DECIDE WHETHER THE REST MEAN ANYTHING:
#   arm 0  INSTRUMENT CONTROL   -- identical kernels must report no change.
#   arm 4  MECHANISM CONTROL    -- a USER define must reach the replacement.
#                                  If it does not, the arm-3 reading is a
#                                  misattribution: the propagation mechanism
#                                  would be broken generally rather than missing
#                                  the injected family specifically.
#   STAMP GUARD                 -- engine.version is recorded before and after
#                                  and must not move. A concurrent lane
#                                  restamping mid-probe would silently change
#                                  which cell every arm consumed.
set -uo pipefail

REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}
FLUTTER_REV=${FLUTTER_REV:-c15ef6379403a0a55531a058bdb2c8e55bc05c98}
FLUTTER_DIR=$HOME/.shorebird/bin/cache/flutter/$FLUTTER_REV
FLUTTER=${FLUTTER:-$FLUTTER_DIR/bin/flutter}
ENGINE_REV=${ENGINE_REV:-40eaa0ef6cb6485833bf2e10ac97224ca82cbf25}
CELL=${CELL:-$HOME/.shorebird/bin/cache/artifacts/route-b-compiler/$ENGINE_REV}
FIXTURE=${FIXTURE:-$REPO/selfhost/fixtures/injected_define_app}
WORK=${WORK:-$(mktemp -d)}

export FLUTTER_STORAGE_BASE_URL=${FLUTTER_STORAGE_BASE_URL:-http://localhost:8085}

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }
pass=0; fail=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "  PASS  $1 -> $2"; pass=$((pass+1))
  else echo "  FAIL  $1 -> got [$2] want [$3]"; fail=$((fail+1)); fi
}

[ -x "$FLUTTER" ] || die "pinned flutter not found: $FLUTTER"
[ -d "$CELL" ]    || die "no Route B cell at $CELL"
[ -d "$FIXTURE" ] || die "fixture not found: $FIXTURE"

RUNTIME=$CELL/dartaotruntime
GENKERNEL=$CELL/route_b_gen_kernel.aot
D2B=$CELL/dart2bytecode.aot
ANALYZE=$CELL/route_b_analyze.aot
PLATFORM=$CELL/flutter_platform_strong.dill

# STAMP GUARD, opening half. A lane restamping engine.version mid-probe would
# change the cell underneath these arms with no error and no git conflict.
STAMP_FILE=$FLUTTER_DIR/bin/internal/engine.version
STAMP_BEFORE=$(cat "$STAMP_FILE")
note "engine.version at start: $STAMP_BEFORE"
[ "$STAMP_BEFORE" = "$ENGINE_REV" ] ||
  die "engine.version is $STAMP_BEFORE but this probe consumes cell $ENGINE_REV -- another lane holds the rig"

mkdir -p "$WORK"

# A COPY. The committed fixture is claimed and this probe runs `flutter create`
# and `pub get` into the tree -- neither may touch the committed one.
APP=$WORK/app
note "copying fixture to $APP"
mkdir -p "$APP"
tar -C "$FIXTURE" -cf - --exclude .dart_tool --exclude build --exclude ios . | tar -C "$APP" -xf -
cd "$APP"

note "generating the ios/ tree and resolving packages"
"$FLUTTER" create --platforms=ios --project-name injected_define_probe . >/dev/null 2>&1 ||
  die "flutter create failed"
# `flutter create` rewrites lib/main.dart; restore the fixture's own.
cp "$FIXTURE/lib/main.dart" lib/main.dart
cp "$FIXTURE/pubspec.yaml" pubspec.yaml
printf 'app_id: probe-only-never-registered\nbase_url: http://127.0.0.1:1\n' > shorebird.yaml
"$FLUTTER" pub get >/dev/null 2>&1 || die "pub get failed"
PKGCFG=$APP/.dart_tool/package_config.json
[ -f "$PKGCFG" ] || die "no package_config.json"

# THEIRS: the defines Flutter itself resolves for this build. Deleted first so a
# build that fails to write the file cannot be misread as "no defines".
XCCONFIG=$APP/ios/Flutter/Generated.xcconfig
note "asking Flutter for its own DART_DEFINES (--config-only)"
rm -f "$XCCONFIG"
"$FLUTTER" build ios --config-only --no-codesign >/dev/null 2>&1 || true
[ -f "$XCCONFIG" ] || die "Flutter wrote no $XCCONFIG"

decode() {
  grep '^DART_DEFINES=' "$XCCONFIG" | sed 's/^DART_DEFINES=//' | tr ',' '\n' |
    while read -r e; do [ -n "$e" ] && printf '%s\n' "$(printf '%s' "$e" | base64 -d)"; done
}
decode | sort > "$WORK/injected.txt"
echo "--- Flutter injected:"; sed 's/^/      /' "$WORK/injected.txt"

INJ=()
while IFS= read -r kv; do [ -n "$kv" ] && INJ+=("-D$kv"); done < "$WORK/injected.txt"
FLUTTER_VERSION_VALUE=$(grep '^FLUTTER_VERSION=' "$WORK/injected.txt" | cut -d= -f2-)
[ -n "$FLUTTER_VERSION_VALUE" ] || die "FLUTTER_VERSION absent from Flutter's own answer"

kernel() { # <out.dill> <mode> <extra...>
  local out=$1 mode=$2; shift 2
  "$RUNTIME" "$GENKERNEL" --platform "$PLATFORM" --target flutter "$mode" \
    --packages "$PKGCFG" "$@" -o "$out" "$APP/lib/main.dart" >/dev/null 2>&1
}

changed() { # <base> <patched>
  "$RUNTIME" "$ANALYZE" --base-dill "$1" --patched-dill "$2" \
    --include 'package:injected_define_probe/' 2>/dev/null |
    python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print("ANALYZER-ERROR"); raise SystemExit
print(",".join(sorted(d["changed"])) or "NONE")'
}

note "compiling the arms"
# What FLUTTER compiles -- constant across arms, because Flutter always injects.
kernel "$WORK/shipped.dill"    --aot "${INJ[@]}"
# What ROUTE B compiles, WITH the G4.1c threading (the fix).
kernel "$WORK/routeb_on.dill"  --aot "${INJ[@]}"
# What ROUTE B compiled BEFORE it -- the negative control.
kernel "$WORK/routeb_off.dill" --aot

echo
echo "arm 0  INSTRUMENT CONTROL -- identical kernels must report no change"
check "shipped vs shipped" "$(changed "$WORK/shipped.dill" "$WORK/shipped.dill")" "NONE"

echo
echo "arm 1  LINK 1, THE FIX -- Route B WITH threading produces the shipped program"
check "routeb_on is byte-identical to shipped" \
  "$(shasum -a 256 "$WORK/routeb_on.dill" | cut -d' ' -f1)" \
  "$(shasum -a 256 "$WORK/shipped.dill"   | cut -d' ' -f1)"

echo
echo "arm 2  LINK 1, NEGATIVE CONTROL -- threading removed, the kernels must diverge"
OFF_SHA=$(shasum -a 256 "$WORK/routeb_off.dill" | cut -d' ' -f1)
SHIP_SHA=$(shasum -a 256 "$WORK/shipped.dill"   | cut -d' ' -f1)
if [ "$OFF_SHA" = "$SHIP_SHA" ]; then
  check "routeb_off differs from shipped" "no" "yes"
else
  check "routeb_off differs from shipped" "yes" "yes"
fi
# And the divergence is THE DEFINE, not incidental: the injected value is present
# in exactly one of them. Without this, arm 2 would pass on any difference at all.
check "the injected value is IN shipped" \
  "$(LC_ALL=C strings -a "$WORK/shipped.dill" | grep -cF "$FLUTTER_VERSION_VALUE" | awk '{print ($1>0)?"yes":"no"}')" "yes"
check "the injected value is ABSENT from routeb_off" \
  "$(LC_ALL=C strings -a "$WORK/routeb_off.dill" | grep -cF "$FLUTTER_VERSION_VALUE" | awk '{print ($1>0)?"yes":"no"}')" "no"

echo
echo "arm 2b RECORDED INSTRUMENT LIMIT -- route_b_analyze does NOT see this difference."
echo "       Measured, and it is why arms 1-2 compare BYTES rather than the analyzer:"
echo "       a kernel built -DFLUTTER_VERSION=zzz and one built with the real value"
echo "       differ only in a constant inside injectedDefineProbe's body, and"
echo "       \`changed\` reports NONE for that pair. g41c's link-1 arms remain the"
echo "       analyzer-level proof; they put the branch in main, where it IS seen."
kernel "$WORK/zzz.dill" --aot -DFLUTTER_VERSION=zzz
check "analyzer reports NONE for a real constant difference (a LIMIT, not a pass)" \
  "$(changed "$WORK/zzz.dill" "$WORK/shipped.dill")" "NONE"

# ---------------------------------------------------------------------------
# LINK 2: what a REPLACEMENT BODY is compiled against.
#
# This mirrors route_b_producer.dart: a synthetic library importing the target's
# library, holding one replacement declaration, compiled by dart2bytecode
# against the release's IMPORT kernel with the release's recorded defines as -D
# flags. The variable is exactly which -D flags those are.
# ---------------------------------------------------------------------------
note "building the import kernel a patch binds against (--no-aot, with threading)"
kernel "$WORK/import.dill" --no-aot "${INJ[@]}" --no-link-platform

REPL=$WORK/replacement.dart
cat > "$REPL" <<'DART'
import 'package:injected_define_probe/main.dart';

@pragma('vm:entry-point')
String replacementReadsDefine() =>
    'NEW-${const String.fromEnvironment('FLUTTER_VERSION')}';
DART

REPL_USER=$WORK/replacement_user.dart
cat > "$REPL_USER" <<'DART'
import 'package:injected_define_probe/main.dart';

@pragma('vm:entry-point')
String replacementReadsUserDefine() =>
    'NEW-${const String.fromEnvironment('PROBE_USER_KEY')}';
DART

# Compile a replacement and answer ONE question: did the compiler bake the
# expected literal into it?
#
# `const String.fromEnvironment` resolves at compile time, so the value is a
# literal in the bytecode's constant pool before anything could check it at
# runtime. The pool concatenates entries, so an earlier draft of this probe used
# `grep -o "NEW-[^\"]*"` and returned the expected value with the NEXT pool entry
# glued to it -- which failed all three arms for a reason that had nothing to do
# with defines. Substring presence of the FULL expected literal is unambiguous in
# both directions: `NEW-3.44.8` cannot appear when the value baked was empty,
# because that produces `NEW-` followed immediately by a symbol name.
baked_has() { # <replacement.dart> <expected-literal> <extra -D...>
  local src=$1 expect=$2; shift 2
  local out="$WORK/$(basename "$src" .dart).bytecode"
  rm -f "$out"
  "$RUNTIME" "$D2B" --platform "$PLATFORM" --target flutter \
    --import-dill "$WORK/import.dill" "$@" \
    --packages "$PKGCFG" -o "$out" "$src" >/dev/null 2>&1
  if [ ! -f "$out" ]; then echo "COMPILE-FAILED"; return; fi
  # Guard against a "no" that comes from an empty/garbage container rather than
  # from the define: the marker prefix must be there either way.
  if ! LC_ALL=C strings -a "$out" | grep -qF 'NEW-'; then echo "NO-MARKER"; return; fi
  if LC_ALL=C strings -a "$out" | grep -qF "$expect"; then echo yes; else echo no; fi
}

echo
echo "arm 3  LINK 2, THE PATCH-REPLACEMENT ARM -- and it is where the defect still lives."
echo "       route_b_producer.dart:169 feeds the replacement compiler"
echo "       buildConfig.compilerArgs, and route_b_build_config.dart:345 builds those"
echo "       from effectiveDefines ALONE -- which the injected six are deliberately"
echo "       NOT in. So this arm passes ONLY the fingerprint's defines: none."
GOT_TODAY=$(baked_has "$REPL" "NEW-$FLUTTER_VERSION_VALUE")
check "DEFECT: a replacement reading FLUTTER_VERSION does NOT get the real value" \
  "$GOT_TODAY" "no"

echo
echo "arm 4  MECHANISM CONTROL -- a USER define must reach the same replacement path."
echo "       If this were also 'no', arm 3 would be a misattribution: the propagation"
echo "       mechanism would be broken generally rather than missing the injected family."
GOT_USER=$(baked_has "$REPL_USER" "NEW-probe-user-value" -DPROBE_USER_KEY=probe-user-value)
check "a replacement reading a USER define DOES get its value" "$GOT_USER" "yes"

echo
echo "arm 5  LINK 2, THE REMEDY IS REACHABLE -- same replacement, injected -D flags passed"
GOT_FIXED=$(baked_has "$REPL" "NEW-$FLUTTER_VERSION_VALUE" "${INJ[@]}")
check "the same replacement DOES get it when the injected defines are passed" \
  "$GOT_FIXED" "yes"

# STAMP GUARD, closing half.
STAMP_AFTER=$(cat "$STAMP_FILE")
echo
echo "arm 6  STAMP GUARD -- engine.version must not have moved under this probe"
check "engine.version unmoved" "$STAMP_AFTER" "$STAMP_BEFORE"

echo
echo "PASS=$pass FAIL=$fail"
echo "WORK=$WORK"
[ "$fail" -eq 0 ]
