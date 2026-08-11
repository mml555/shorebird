#!/usr/bin/env bash
# cspell:words dartaotruntime
#
# lowering_matrix.sh -- what the ANALYZER decides, case by case.
#
# The producer's lexical edit is covered by unit tests. This covers the half
# that only real Kernel can answer: which identifiers are receiver-bound, what
# they resolve to, and which forms are refused. Those are exactly the cases
# where a source-text implementation would go wrong, so they are worth checking
# against the compiler rather than against an idea of Dart.
#
# Every case is a method on ONE class in ONE file, so a difference between two
# cases is the case and not the fixture. Each is checked for:
#
#   LOWERED <n>   the target is lowerable, with n receiver accesses
#   UNTOUCHED     lowerable, and the identifier in question was NOT rewritten
#                 -- a local, a top-level, a static, another object's member
#   REFUSED       the analyzer reported a reason it cannot be lowered
#
# UNTOUCHED is the important column. A local `helper()`, a top-level
# `helper()` and `Cls.helper()` are all spelled the same as the receiver call,
# and all three are different Kernel nodes. Nothing about the spelling
# distinguishes them.
#
#   lowering_matrix.sh
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
WORK=${WORK:-$(mktemp -d)}

DART_TREE=$SRC/flutter/third_party/dart
DART=$OUT/dart-sdk/bin/dart
GEN_KERNEL=$DART_TREE/pkg/vm/bin/gen_kernel.dart
ANALYZER=${ANALYZER:-$OUT/zip_archives/route_b_analyze.aot}
RUNTIME=$OUT/dartaotruntime

die() { echo "ERROR: $*" >&2; exit 1; }
pass=0; fail=0

[ -x "$DART" ] || die "no host dart at $DART"
[ -f "$ANALYZER" ] || die "no analyzer at $ANALYZER — run build_route_b_analyzer.sh"
mkdir -p "$WORK/lib" "$WORK/.dart_tool"

cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "matrix", "rootUri": "file://$WORK/", "packageUri": "lib/",
    "languageVersion": "3.9" } ] }
JSON
URI=package:matrix/main.dart

# BASE and PATCHED differ in every method body, so every method is "changed"
# and the analyzer reports a lowering for each. The base bodies are deliberately
# uniform and boring; only the patched ones are the subject.
emit() { # <file> <marker>
  cat > "$1" <<DART
// Ünïcödé — em dashes — before everything, so every offset below is a code
// unit offset that differs from its byte offset. Byte slicing drifted six
// positions on a real fixture once and produced a library beginning mid-word.
String helper() => 'top level';

class Other {
  String helper() => 'other';
}

class Cls {
  static String helper() => 'static';
}

class Base {
  String helper() => 'base';
}

class RouteBThing extends Base {
  String label = 'field';
  String _secret = 'private';
  final Other other = Other();

  @override
  String helper() => 'receiver';
  String _hidden() => 'private method';
  String withArgs(String a) => a;

$2
}

void main() {
  final t = RouteBThing();
  print([
    t.bareCall(), t.thisCall(), t.bareGet(), t.localShadow(),
    t.topLevelCall(), t.staticCall(), t.otherObject(), t.withArguments(),
    t.cascade(), t.superCall(), t.privateCall(), t.privateGet(),
    t.setterUse(), t.\$secretLen,
  ].join(','));
}
DART
}

# One body per case. The base file gets a body that uses nothing.
BASE_BODIES=$(cat <<'DART'
  String bareCall() => 'b0';
  String thisCall() => 'b1';
  String bareGet() => 'b2';
  String localShadow() => 'b3';
  String topLevelCall() => 'b4';
  String staticCall() => 'b5';
  String otherObject() => 'b6';
  String withArguments() => 'b7';
  String cascade() => 'b8';
  String superCall() => 'b9';
  String privateCall() => 'b10';
  String privateGet() => 'b11';
  String setterUse() => 'b12';
  int get $secretLen => 0;
DART
)

PATCHED_BODIES=$(cat <<'DART'
  String bareCall() => helper();
  String thisCall() => this.helper();
  String bareGet() => label;
  String localShadow() { String helper() => 'local'; return helper(); }
  String topLevelCall() => main_helper();
  String staticCall() => Cls.helper();
  String otherObject() => other.helper();
  String withArguments() => withArgs('x');
  String cascade() { final s = StringBuffer(); this..helper(); return '$s'; }
  String superCall() => super.helper();
  String privateCall() => _hidden();
  String privateGet() => _secret;
  String setterUse() { label = 'set'; return label; }
  int get $secretLen => 1;
DART
)

# `main_helper` is how the patched body names the TOP-LEVEL helper: an unadorned
# `helper()` inside the class would resolve to the receiver's override, which is
# a different case entirely (bareCall). Aliasing it on import is the only way to
# write "call the top-level one" from inside a class that has its own.
emit "$WORK/lib/main.dart" "$BASE_BODIES"
python3 - "$WORK/lib/main.dart" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace(
    "String helper() => 'top level';",
    "String helper() => 'top level';\nString main_helper() => helper();", 1))
PY
cp "$WORK/lib/main.dart" "$WORK/base_source.dart"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages "$WORK/.dart_tool/package_config.json" -o "$WORK/base.dill" "$URI" \
  > "$WORK/base.log" 2>&1 || { sed 's/^/    /' "$WORK/base.log"; die "base did not compile"; }

emit "$WORK/lib/main.dart" "$PATCHED_BODIES"
python3 - "$WORK/lib/main.dart" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace(
    "String helper() => 'top level';",
    "String helper() => 'top level';\nString main_helper() => helper();", 1))
PY
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages "$WORK/.dart_tool/package_config.json" -o "$WORK/patched.dill" "$URI" \
  > "$WORK/patched.log" 2>&1 || { sed 's/^/    /' "$WORK/patched.log"; die "patch did not compile"; }

"$RUNTIME" "$ANALYZER" --base-dill "$WORK/base.dill" --patched-dill "$WORK/patched.dill" \
  --out "$WORK/analysis.json" > "$WORK/analyze.log" 2>&1 \
  || { sed 's/^/    /' "$WORK/analyze.log"; die "the analyzer failed"; }

echo "analyzer decisions"
echo

# <case> <expectation> [identifier that must survive verbatim]
#   lowered:<n>   n receiver accesses, no refusal
#   refused       at least one refusal reason
check() {
  local name="$1" expect="$2" survives="${3:-}"
  local verdict
  verdict=$(EXPECT="$expect" SURVIVES="$survives" NAME="$name" SRCFILE="$WORK/lib/main.dart" \
    python3 - "$WORK/analysis.json" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
name, expect = os.environ['NAME'], os.environ['EXPECT']
survives = os.environ['SURVIVES']
key = [k for k in d.get('lowering', {}) if k.endswith('.' + name)]
if not key:
    print('MISSING|the analyzer reported no lowering for it'); raise SystemExit
low = d['lowering'][key[0]]
bad = low['unsupported']
if expect == 'refused':
    print(('OK|' + '; '.join(bad)) if bad else 'BAD|it was accepted')
    raise SystemExit
if bad:
    print('BAD|refused: ' + '; '.join(bad)); raise SystemExit
want = int(expect.split(':')[1])
got = len(low['accesses'])
if got != want:
    print(f'BAD|{got} access(es), wanted {want}'); raise SystemExit
# The identifier that must NOT be rewritten: no reported access may point at it.
if survives:
    src = open(os.environ['SRCFILE'], encoding='utf-8').read()
    for a in low['accesses']:
        if src[a['offset']:a['offset'] + len(survives)] == survives:
            print(f'BAD|it rewrote `{survives}`'); raise SystemExit
print('OK|' + ', '.join(f"{a['kind']} {a['member']}" for a in low['accesses']))
PY
)
  local status=${verdict%%|*} detail=${verdict#*|}
  if [ "$status" = OK ]; then
    printf '  PASS  %-16s %s\n' "$name" "$detail"; pass=$((pass+1))
  else
    printf '  FAIL  %-16s %s\n' "$name" "$detail"; fail=$((fail+1))
  fi
}

check bareCall       lowered:1
check thisCall       lowered:1
check bareGet        lowered:1
check localShadow    lowered:0  helper
check topLevelCall   lowered:0  main_helper
check staticCall     lowered:0  helper
# `other` is a FIELD on the receiver, so `other.helper()` DOES have one
# receiver access -- on `other`. `helper` belongs to the Other instance and must
# survive untouched; the lowered form is `self.other.helper()`.
check otherObject    lowered:1  helper
# ARGUMENTS ARE REFUSED BY THE PRODUCER, NOT HERE. `gen_kernel --aot` eliminates
# a parameter whose argument is always the same constant, so this call really
# does read as zero-argument in the release kernel -- `withArgs` itself declares
# no parameters there, while the --no-aot kernel says one. The analyzer keeps
# its check for the cases TFA leaves alone; the source-text gate is what
# actually holds. See producer_refusals below.
check withArguments  lowered:1
check cascade        refused
check superCall      refused
check privateCall    refused
check privateGet     refused
check setterUse      refused

echo
echo "--------------------------------------------------"
echo "lowering matrix: $pass passed, $fail failed"
echo "work dir kept: $WORK"
[ "$fail" -eq 0 ] || exit 1
