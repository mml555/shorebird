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
# COMPILED THE WAY A RELEASE IS, with a dynamic interface. That is not a detail:
# without one, `--aot` eliminates a parameter whose argument is always the same
# constant, and `withArgs('x')` reads as a zero-argument call to a method taking
# none. With the interface the library is retained and both survive. A probe
# that skips it reaches conclusions about a compilation no release performs.
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
RB="$(cd "$HERE/.." >/dev/null 2>&1 && pwd)"
KERNEL_PKGS="--packages=$DART_TREE/.dart_tool/package_config.json"
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
  String inherited = 'base-field';
}

class RouteBThing extends Base {
  String label = 'field';
  String _secret = 'private';
  final Other other = Other();

  @override
  String helper() => 'receiver';
  String _hidden() => 'private method';
  String withArgs(String a) => a;
  String twoArgs(String a, {String b = 'b'}) => a + b;
  String? maybe;
  int count = 0;

$2
}

void main() {
  final t = RouteBThing();
  print([
    t.bareCall(), t.thisCall(), t.bareGet(), t.localShadow(),
    t.topLevelCall(), t.staticCall(), t.otherObject(), t.withArguments(),
    t.cascade(), t.superCall(), t.privateCall(), t.privateGet(),
    t.setterUse(), t.\$secretLen, t.constArg(), t.exprArg(), t.thisArg(),
    t.namedArg(), t.simpleSet(), t.thisSet(), t.setFromRead(), t.compoundSet(),
    t.incrementSet(), t.ifNullSet(), t.privateSet(), t.superSet(),
    t.cascadeSet(),
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
  String constArg() => 'b13';
  String exprArg() => 'b14';
  String thisArg() => 'b15';
  String namedArg() => 'b16';
  String simpleSet() => 'b17';
  String thisSet() => 'b18';
  String setFromRead() => 'b19';
  String compoundSet() => 'b20';
  int incrementSet() => 0;
  String ifNullSet() => 'b21';
  String privateSet() => 'b22';
  String superSet() => 'b23';
  String cascadeSet() => 'b24';
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
  String constArg() => withArgs('ARG');
  String exprArg() => withArgs(label);
  String thisArg() => this.withArgs('ARG');
  String namedArg() => twoArgs('a', b: 'B');
  String simpleSet() => label = 'NEW-SET';
  String thisSet() => this.label = 'NEW-SET';
  String setFromRead() => label = label + 'Y';
  String compoundSet() => label += 'X';
  int incrementSet() { count++; return count; }
  String ifNullSet() => maybe ??= 'Z';
  String privateSet() => _secret = 'p';
  String superSet() { super.inherited = 'S'; return 'x'; }
  String cascadeSet() { this..label = 'c'; return label; }
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
# Prepass, then the interface, then the real kernel -- the release's own order.
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages "$WORK/.dart_tool/package_config.json" -o "$WORK/prepass.dill" "$URI" \
  > "$WORK/base.log" 2>&1 || { sed 's/^/    /' "$WORK/base.log"; die "prepass did not compile"; }
"$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill "$WORK/prepass.dill" \
  --out "$WORK/di.yaml" --sdk-members 'dart:core#print' 2>/dev/null
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --dynamic-interface "$WORK/di.yaml" \
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
  --dynamic-interface "$WORK/di.yaml" \
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
check withArguments  lowered:1
check cascade        refused
check superCall      refused
check privateCall    refused
check privateGet     refused
# Was refused before writes were supported; now a statement-bodied write plus a
# read, at two distinct offsets.
check setterUse      lowered:2

# ARGUMENTS. The edit is `withArgs` -> `self.withArgs`; everything after the
# identifier is the source's own text, so there is nothing here for the lowering
# to understand. These cases exist to prove that, not to exercise a mechanism.
check constArg       lowered:1
# Two accesses, and the inner one is the point: `withArgs(label)` becomes
# `self.withArgs(self.label)` because BOTH offsets are reported.
check exprArg        lowered:2
check thisArg        lowered:1
check namedArg       lowered:1

# WRITES. Same lexical shape as a read -- the offset is on the identifier and
# `= <rhs>` is the source's own text.
check simpleSet      lowered:1
check thisSet        lowered:1
# Genuinely two tokens at two offsets: `self.label = self.label + 'Y'`.
check setFromRead    lowered:2
# ONE TOKEN DOING TWO JOBS. Each of these reports a read and a write at the SAME
# offset, so a single insertion point would have to carry two edits. Refused by
# the collision, not by an operator list -- which is why `??=` and `++` need no
# special case of their own.
check compoundSet    refused
check incrementSet   refused
check ifNullSet      refused
check privateSet     refused
check superSet       refused
check cascadeSet     refused

echo
echo "--------------------------------------------------"
echo "lowering matrix: $pass passed, $fail failed"
echo "work dir kept: $WORK"
[ "$fail" -eq 0 ] || exit 1
