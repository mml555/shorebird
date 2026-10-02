#!/usr/bin/env bash
#
# g41c_injected_defines.sh -- G4.1: does Route B's prepass analyze the same Dart
# program the release actually ships?
#
# WHAT THIS MEASURES. `flutter build` does not compile the program the user
# described on the command line. After parsing it, Flutter appends defines of its
# own -- `flutter_command.dart` `_addFlutterVersionToDartDefines` (six) and
# `_addFeatureFlagsToDartDefines` (one, when non-empty) -- and every one is
# readable with `String.fromEnvironment`. Until G4.1c, Route B's
# `forwardedArgs` carried only `--dart-define=` and `--enable-experiment=`, so
# the prepass and both import kernels were compiled WITHOUT them.
#
# THE SCOPE CORRECTION THIS PROBE MAKES. This was recorded as a flavored-app
# concern. It is not: arm A runs on a CLEAN `flutter create` app with no flavor
# and no `--dart-define` at all, and the release still receives SIX defines the
# prepass never saw.
#
# WHY THE OBSERVABLE IS THE ANALYZER AND NOT THE INTERFACE. The first version of
# this probe diffed the generated dynamic interface and reported the two arms as
# DIFFERENT -- which was a FALSE PASS, and its own instrument control caught it.
# Route B's interface is whole-library for app libraries, so it names no
# individual function and the only line that differed was the `# Source dill:`
# comment. Symbol NAMES are no better: they survive in the kernel's string table
# whether or not the body is reachable, so `strings | grep` reports all four
# markers present in every arm. The observable that actually answers the question
# is `route_b_analyze.aot` -- Route B's OWN coverage analyzer, the thing that
# classifies one kernel against another -- and it reports `main` as CHANGED.
#
# THE ARMS THAT DECIDE WHETHER THE REST MEAN ANYTHING:
#   arm 0  instrument control -- the analyzer compared against an IDENTICAL
#          kernel must report `changed = []`. Without it, an analyzer that
#          reported every comparison as changed would "prove" this finding.
#   arm 3  determinism control -- recompiling the same arm twice and comparing
#          must also report `changed = []`, or the finding is compiler
#          nondeterminism rather than a define.
#   arm 2  positive control -- an ORDINARY user define, which Route B has always
#          forwarded, must produce the SAME divergence. This is what shows the
#          instrument can see define-driven change at all, and it is why the
#          finding in arm 1 is the same class of defect rather than a curiosity.
set -euo pipefail

REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}
FLUTTER_REV=${FLUTTER_REV:-c15ef6379403a0a55531a058bdb2c8e55bc05c98}
FLUTTER=${FLUTTER:-$HOME/.shorebird/bin/cache/flutter/$FLUTTER_REV/bin/flutter}
ENGINE_REV=${ENGINE_REV:-40eaa0ef6cb6485833bf2e10ac97224ca82cbf25}
CELL=${CELL:-$HOME/.shorebird/bin/cache/artifacts/route-b-compiler/$ENGINE_REV}
WORK=${WORK:-$(mktemp -d)}

# The pinned Flutter is stamped with an EXPERIMENTAL engine revision only our own
# mirror serves. Without this, `flutter build` asks download.shorebird.dev for
# `engine_stamp.json` and takes a 404. Read-only use of `R11`.
export FLUTTER_STORAGE_BASE_URL=${FLUTTER_STORAGE_BASE_URL:-http://localhost:8085}

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }
pass=0; fail=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then
    echo "  PASS  $1 -> $2"; pass=$((pass+1))
  else
    echo "  FAIL  $1 -> got [$2] want [$3]"; fail=$((fail+1))
  fi
}

[ -x "$FLUTTER" ] || die "pinned flutter not found: $FLUTTER"
[ -d "$CELL" ]    || die "no Route B cell at $CELL"
RUNTIME=$CELL/dartaotruntime
GENKERNEL=$CELL/route_b_gen_kernel.aot
ANALYZE=$CELL/route_b_analyze.aot
PLATFORM=$CELL/flutter_platform_strong.dill

mkdir -p "$WORK"; cd "$WORK"
APP=$WORK/probeapp

note "creating a CLEAN app -- no flavor, no --dart-define"
"$FLUTTER" create --platforms=ios --project-name probeapp probeapp >/dev/null
cd "$APP"

# A program whose REACHABLE SURFACE depends on a compile-time environment read.
# Each branch calls a DIFFERENT function, so the two programs cannot be confused
# for one another -- a probe whose branches retained the same symbols would
# report agreement no matter what the defines were.
cat > lib/main.dart <<'DART'
const flutterVersion = String.fromEnvironment('FLUTTER_VERSION');
const userKey = String.fromEnvironment('PROBE_USER_KEY');

String reachedWhenVersionKnown() => 'KNOWN';
String reachedWhenVersionMissing() => 'MISSING';
String reachedWhenUserKeySet() => 'USER-SET';
String reachedWhenUserKeyUnset() => 'USER-UNSET';

void main() {
  print(flutterVersion == '3.44.8'
      ? reachedWhenVersionKnown()
      : reachedWhenVersionMissing());
  print(userKey == 'probe-user-value'
      ? reachedWhenUserKeySet()
      : reachedWhenUserKeyUnset());
}
DART

"$FLUTTER" pub get >/dev/null 2>&1
PKGCFG=$APP/.dart_tool/package_config.json
[ -f "$PKGCFG" ] || die "no package_config.json"

XCCONFIG=$APP/ios/Flutter/Generated.xcconfig

# THEIRS: what Flutter itself resolves for this build. Deleted first so a build
# that fails to write it cannot be misread as "no defines".
note "asking Flutter for its own DART_DEFINES (--config-only)"
rm -f "$XCCONFIG"
"$FLUTTER" build ios --config-only --no-codesign >/dev/null 2>&1 || true
[ -f "$XCCONFIG" ] || die "Flutter wrote no $XCCONFIG"

decode() {
  grep '^DART_DEFINES=' "$XCCONFIG" | sed 's/^DART_DEFINES=//' | tr ',' '\n' |
    while read -r e; do [ -n "$e" ] && printf '%s\n' "$(printf '%s' "$e" | base64 -d)"; done
}
decode | sort > "$WORK/injected.txt"
echo "--- Flutter injected into a define-free, flavor-free build:"
sed 's/^/      /' "$WORK/injected.txt"

INJECTED_COUNT=$(wc -l < "$WORK/injected.txt" | tr -d ' ')
check "a clean app receives injected defines" "$([ "$INJECTED_COUNT" -gt 0 ] && echo yes || echo no)" "yes"

# gen_kernel spells them -D; build the argument list from FLUTTER'S OWN ANSWER
# rather than from a list written here, which is the whole point of the seam.
INJECTED_ARGS=()
while IFS= read -r kv; do
  [ -n "$kv" ] && INJECTED_ARGS+=("-D$kv")
done < "$WORK/injected.txt"

prepass() { # <out.dill> <extra args...>
  local out=$1; shift
  "$RUNTIME" "$GENKERNEL" \
    --platform "$PLATFORM" --target flutter --aot \
    --packages "$PKGCFG" "$@" -o "$out" "$APP/lib/main.dart" >/dev/null 2>&1
}

# Route B's own analyzer, asked the only question that matters: are these two
# kernels the same program?
changed() { # <base.dill> <patched.dill>
  "$RUNTIME" "$ANALYZE" --base-dill "$1" --patched-dill "$2" \
    --include 'package:probeapp/' 2>/dev/null |
    python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["changed"]) or "NONE")'
}

note "compiling the arms"
prepass "$WORK/routeb.dill"                              # what Route B analyzed
prepass "$WORK/shipped.dill"  "${INJECTED_ARGS[@]}"      # what the release ships
prepass "$WORK/user.dill"     -DPROBE_USER_KEY=probe-user-value
prepass "$WORK/shipped2.dill" "${INJECTED_ARGS[@]}"      # determinism control

echo
echo "arm 0  INSTRUMENT CONTROL -- identical kernels must report no change"
check "routeb vs routeb" "$(changed "$WORK/routeb.dill" "$WORK/routeb.dill")" "NONE"

echo
echo "arm 3  DETERMINISM CONTROL -- same inputs twice must report no change"
check "shipped vs shipped2" "$(changed "$WORK/shipped.dill" "$WORK/shipped2.dill")" "NONE"

echo
echo "arm 2  POSITIVE CONTROL -- an ordinary user define, which Route B DOES forward"
check "routeb vs user" "$(changed "$WORK/routeb.dill" "$WORK/user.dill")" \
  "package:probeapp/main.dart#main"

echo
echo "arm 1  THE FINDING -- Route B's prepass vs the program Flutter compiles"
check "routeb vs shipped" "$(changed "$WORK/routeb.dill" "$WORK/shipped.dill")" \
  "package:probeapp/main.dart#main"

echo
echo "PASS=$pass FAIL=$fail"
echo "WORK=$WORK"
[ "$fail" -eq 0 ]
