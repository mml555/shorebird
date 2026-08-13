#!/usr/bin/env bash
# cspell:words dartaotruntime pubspec
#
# g42_flavor_flow.sh -- G4.2: what does `--flavor` actually DO to the compiler, and
# does Route B's prepass see it?
#
# PARITY §4 predicted a false green here and named it precisely: "a minimal flavored
# fixture that never READS appFlavor turns both device rows green with the gap fully
# intact -- buying an accidental contract instead of a capability." So this probe
# runs before any plumbing, and it checks the flow rather than the outcome.
#
# FOUR SOURCE FACTS, each grep-verified against the PINNED Flutter tool so that an
# upstream change breaks this probe instead of silently invalidating the design, and
# ONE measurement.
#
# The pass condition that matters most, stated as PARITY frames it: the release
# prepass must see the same effective FLUTTER_APP_FLAVOR as the shipped release and
# as the patch compiler. Today it does NOT, and rows 3 and 4 are why.
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
RB="$(cd "$HERE/.." >/dev/null 2>&1 && pwd)"
REPO="$(cd "$RB/../../.." >/dev/null 2>&1 && pwd)"
WORK=${WORK:-$(mktemp -d)}
FLUTTER=${FLUTTER:-$HOME/.shorebird/bin/cache/flutter/c15ef6379403a0a55531a058bdb2c8e55bc05c98}

DART_TREE=$SRC/flutter/third_party/dart
DART=$OUT/dart-sdk/bin/dart
GEN_KERNEL=$DART_TREE/pkg/vm/bin/gen_kernel.dart
GEN_SNAPSHOT=$OUT/gen_snapshot
AOT_RUNTIME=$OUT/dartaotruntime

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }
pass=0; fail=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "  PASS  $1 -> $2"; pass=$((pass+1));
  else echo "  FAIL  $1: got '$2', want '$3'"; fail=$((fail+1)); fi
}
# Asserts a fact about upstream source AND pins where it lives, so the citation
# cannot rot into folklore.
cite() { # <label> <file> <pattern>
  local label="$1" file="$2" pattern="$3"
  local line
  line=$(grep -nE "$pattern" "$file" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -n "$line" ]; then
    echo "  PASS  $label"
    echo "        $(basename "$file"):$line"
    pass=$((pass+1))
  else
    echo "  FAIL  $label — pattern not found in $file"
    echo "        $pattern"
    fail=$((fail+1))
  fi
}

[ -d "$FLUTTER" ] || die "no pinned flutter at $FLUTTER"
[ -x "$DART" ] || die "no host dart at $DART"

CMD=$FLUTTER/packages/flutter_tools/lib/src/runner/flutter_command.dart
MANIFEST=$FLUTTER/packages/flutter_tools/lib/src/flutter_manifest.dart
RELEASER=$REPO/packages/shorebird_cli/lib/src/commands/release/ios_releaser.dart
KERNELS=$REPO/packages/shorebird_cli/lib/src/route_b_release_kernels.dart

echo "G4.2: how a flavor reaches the compiler, and who does not receive it"
echo

note "1. a flavor becomes EXACTLY one dart-define"
cite "flutter adds FLUTTER_APP_FLAVOR=<flavor> to dartDefines" \
  "$CMD" "dartDefines\.add\('\\\$kAppFlavor=\\\$flavor'\)"
cite "and re-adds it at xcodebuild time, last write winning" \
  "$FLUTTER/packages/flutter_tools/lib/src/build_system/targets/common.dart" \
  "dartDefines\.add\('\\\$kAppFlavor=\\\$flavor'\)"
echo "        Two injection points, and the second one takes precedence on purpose"
echo "        (flutter/issues/169598). So the value the RELEASE compiled with is the"
echo "        xcodebuild-stage one, which is what a fingerprint must agree with."
echo "        So the Dart-semantic effect of --flavor is fully represented by"
echo "        effectiveDefines['FLUTTER_APP_FLAVOR']. It does NOT need a second"
echo "        fingerprint field, which would be two inputs describing one fact."

note "2. but a user CANNOT supply that define themselves"
cite "the tool REFUSES FLUTTER_APP_FLAVOR via --dart-define(-from-file)" \
  "$CMD" "cannot be '$"
cite "the tool REFUSES FLUTTER_APP_FLAVOR from the environment" \
  "$CMD" "used by the framework and cannot be set in the environment"
echo "        This answers the 'are they equivalent?' row, and the answer is two"
echo "        different things at once: the resulting COMPILER STATE is the same"
echo "        define, but the INPUTS are not substitutable -- only --flavor (or a"
echo "        manifest default) can produce it, and an explicit -D is a tool error."
echo "        So the config layer must SYNTHESISE the define from the flavor rather"
echo "        than expect to find it among the dart-defines."

note "3. a flavor need not come from a flag at all"
cite "pubspec's default-flavor supplies one with no --flavor present" \
  "$MANIFEST" "defaultFlavor => _flutterDescriptor\['default-flavor'\]"
cite "the tool prefers the CLI flavor, else the manifest default" \
  "$CMD" "cliFlavor \?\? defaultFlavor"
echo "        So deriving the define from the COMMAND LINE alone is insufficient:"
echo "        a release can be flavored with nothing on the command line to see."

note "4. and Route B's own kernels are not given it -- the predicted false green"
cite "the CLI passes flavor OUTSIDE buildArgs (a separate buildIpa parameter)" \
  "$RELEASER" "flavor: flavor,"
cite "forwardedArgs carries only --dart-define= and --enable-experiment=" \
  "$KERNELS" "arg\.startsWith\('--dart-define='\)"
if grep -qE "flavor" "$KERNELS"; then k=mentions-flavor; else k=no-flavor; fi
check "the kernel forwarder does not mention flavor at all" "$k" no-flavor
echo "        So the prepass that generates the retention interface, and the import"
echo "        kernel a patch binds against, are both compiled with NO"
echo "        FLUTTER_APP_FLAVOR while the shipped release has a real value."

note "5. does that define change the compiler-visible program? (measured)"
mkdir -p "$WORK/m"
cat > "$WORK/m/main.dart" <<'DART'
// Exactly what `appFlavor` reads: a compile-time constant, so a kernel built
// without the define is a DIFFERENT program, not a program that looks it up later.
const flavor = String.fromEnvironment('FLUTTER_APP_FLAVOR', defaultValue: '<none>');
void main() => print('flavor=$flavor');
DART

prog() { # <name> <args...> -> stripped program sha + observed value
  local name="$1"; shift
  "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
    "$@" -o "$WORK/m/$name.dill" "$WORK/m/main.dart" >/dev/null 2>&1 || {
    echo "<gen_kernel failed>"; return 0; }
  "$GEN_SNAPSHOT" --snapshot_kind=app-aot-elf --strip \
    --elf="$WORK/m/$name.aot" "$WORK/m/$name.dill" >/dev/null 2>&1 || {
    echo "<gen_snapshot failed>"; return 0; }
  printf '%s %s' \
    "$(shasum -a 256 "$WORK/m/$name.aot" | cut -c1-16)" \
    "$("$AOT_RUNTIME" "$WORK/m/$name.aot" 2>/dev/null | tail -1)"
}

read -r none_sha none_val <<<"$(prog none)"
read -r foo_sha foo_val <<<"$(prog foo -DFLUTTER_APP_FLAVOR=foo)"
read -r bar_sha bar_val <<<"$(prog bar -DFLUTTER_APP_FLAVOR=bar)"
echo "    no define    $none_sha  $none_val"
echo "    =foo         $foo_sha  $foo_val"
echo "    =bar         $bar_sha  $bar_val"

if [ "$none_sha" != "$foo_sha" ]; then r=changes; else r=identical; fi
check "the flavor define changes the emitted program" "$r" changes
if [ "$foo_sha" != "$bar_sha" ]; then r=changes; else r=identical; fi
check "two different flavors are two different programs" "$r" changes
check "and the value is baked in, not looked up" "$foo_val" "flavor=foo"

echo
echo "--------------------------------------------------"
echo "flavor flow: $pass passed, $fail failed"
echo "work dir kept: $WORK"
echo
echo "WHAT THIS LICENSES, and what it forbids:"
echo "  * flavor belongs in the EFFECTIVE config as"
echo "    effectiveDefines['FLUTTER_APP_FLAVOR'] and NOT as a second field."
echo "  * the config layer must SYNTHESISE it (from --flavor or the manifest"
echo "    default), because a legal invocation never carries it as a --dart-define."
echo "  * --flavor itself belongs in raw provenance, like splitDebugInfoPath."
echo "  * THE GAP: Route B's prepass and import kernel are compiled without it"
echo "    today, so retention/coverage describe a different program than shipped."
echo "    Threading it is the G4.2 fix; this probe is the reason it is a fix and"
echo "    not a validation errand."
[ "$fail" -eq 0 ] || exit 1
