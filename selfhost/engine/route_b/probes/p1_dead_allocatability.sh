#!/usr/bin/env bash
# cspell:words dartaotruntime prepass ungranted redirecting
# cspell:words Cctl Cfix cctl cfix CFIX KCTOR callability sbrb
#
# p1_dead_allocatability.sh -- P1.1b: does RETAINING a private class grant
# CONSTRUCTION authority the capability interface never names?
#
# THE DIAGNOSIS THIS PROBE IS BUILT ON, established before touching anything.
# Four hypotheses were on the table; the answer is the fourth.
#
#   1 retaining a class implicitly retains all constructors        -- NO
#   2 constructor retention falls out of finalization/allocation   -- NO
#   3 the bytecode binder treats construction unlike member lookup -- NO
#   4 the dynamic interface DEFINES a `callable:` class item as
#     "this class AND ITS PUBLIC MEMBERS are callable"             -- YES
#
# `pkg/vm/lib/transformations/dynamic_interface_annotator.dart` is UPSTREAM DART,
# unmodified by this fork, and `_Annotator.visitClass` reads:
#
#     void visitClass(Class node) {
#       annotateClass(node);
#       if (annotateMembers) {
#         _visitPublicMembers(node.constructors);   <-- here
#         _visitPublicMembers(node.procedures);
#         _visitPublicMembers(node.fields);
#       }
#     }
#
# and the `callable:` section is parsed with `allowStaticDeclarations: true`, so
# `annotateStaticMembers` is on. A class's implicit unnamed constructor is PUBLIC
# (its name text is empty, so `Name.isPrivate` is false), therefore a bare
# `class:` item under `callable:` annotates it. Construction is granted through
# the ordinary member-annotation path -- not by a retention side effect, and not
# by the binder.
#
# So the authority is decided by WHICH SECTION we emit into, and
# `selfhost/engine/route_b/gen_dynamic_interface.dart` emits every private class
# into `callable:` because that is the only section it emits. `can-be-used-as-type:`
# is parsed with members OFF and annotates the class alone -- which is the
# primitive for "identity without callability", and is what C0 tests.
#
# PRECOMMIT -- fixed before running. Deviation is a finding, not a retune.
#
#   | arm  | interface grants for `_Dead`         | patch attempts     | expect  |
#   |------|-------------------------------------|--------------------|---------|
#   | Cctl | can-be-used-as-type only            | use as a TYPE only | PASS    |
#   | C0   | can-be-used-as-type only            | `_Dead()`          | REFUSE  |
#   | C1   | bare `class:` under callable, ADDED  | `_Dead()`          | PASS    |
#   |      | by this probe since 2026-08-25 -- the|                    |         |
#   |      | generator no longer emits one        |                    |         |
#   | C2   | bare `class:` under callable        | `_Dead._mk()`      | REFUSE  |
#   | C3   | class + `member: '_mk'`             | `_Dead._mk()`      | PASS    |
#   | C4   | bare `class:` under callable        | `_Dead.made()`     | CLASSIFY|
#   | C5   | bare `class:` under callable        | `_Dead.redirect()` | CLASSIFY|
#   | Cfix | `_Kept` identity only + `member:`    | patch a method of  | PASS    |
#   |      | grants for its privates             | `_Kept`, read      | REFUTED |
#   |      |                                     | `self._hidden`     |         |
#   | Cfix2| the SAME grant set as Cfix          | `_Kept()`          | REFUSE  |
#   | Cfix3| `_Kept` + `member: 'show'` + private | patch `_Kept.show` | PASS    |
#   |      | member grants, NO bare class item    |                    |         |
#   | Cfix4| the SAME grant set as Cfix3          | `_Kept()`          | REFUSE  |
#   | C6   | `class: '_Dead'` + `member: ''`, NO   | `_Dead()` and      | PASS    |
#   |      | bare class item                      | nothing else       |         |
#
#   CFIX WAS PRECOMMITTED `PASS` AND CAME BACK `ATTACH`. That is a REFUTED
#   HYPOTHESIS, not a bad arm, and it is the most useful single result here:
#   `can-be-used-as-type` is enough for a patch to use a private class as a TYPE
#   (Cctl) but NOT enough to attach to one of its methods. So "move private
#   classes out of `callable:`" is not the fix. Its `expect` is demoted to
#   CLASSIFY so the probe can still serve as a regression gate for the design
#   that DID hold -- the demotion records the refutation, it does not retune the
#   arm to make the probe green. Cfix3/Cfix4 are that design.
#
#   C4/C5 have NO precommitted verdict on purpose. The rule is precommitted
#   instead: construction is permitted only if every callable constructor/factory
#   edge the invocation needs is represented by an explicit capability grant;
#   otherwise refuse. Whatever the kernel actually exposes for a factory and for a
#   redirecting generative constructor gets CLASSIFIED against that rule rather
#   than having a policy invented to fit it.
#
#   `Cctl` IS LOAD-BEARING. Without it, C0's refusal could just mean the class
#   disappeared from the program -- which is the same trap B4 fell into in
#   `p1_bind_private_receiver.sh`, where a member turned out to be inlined away
#   rather than merely ungranted. Cctl proves `_Dead`'s identity is reachable
#   under exactly C0's grant set, so C0's refusal is attributable to the
#   CONSTRUCTOR grant and to nothing else.
#
#   THE RELEASE NEVER CONSTRUCTS `_Dead`. It only mentions it as a type. If the
#   release constructed it, the unnamed constructor would be live regardless of
#   any grant and C0 would be unfalsifiable.
#
#   STOP/INVALID rows, scored as "no result" rather than as a pass:
#     * Cctl does not PASS
#     * C1 does not PASS -- then the hole this arm exists to close is not
#       reproduced here, and C0 proves nothing by contrast
#     * any arm's grant set does not match what the yaml actually says
#
# Host only. No device, no mint, no cell.
#
#   probes/p1_dead_allocatability.sh
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
pass=0; fail=0; invalid=0; classified=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1));
  else echo "  FAIL  $1"; echo "        got : $2"; echo "        want: $3";
    fail=$((fail+1)); fi
}
invalidate() { echo "  INVALID  $1"; invalid=$((invalid+1)); }

[ -x "$DART" ] || die "no host dart at $DART"
echo "work: $WORK"
mkdir -p "$WORK/lib" "$WORK/.dart_tool"

cp "$RB/packaging/container_target.dart" "$WORK/lib/container_target.dart"
python3 - "$WORK/lib/container_target.dart" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace(
    "void _state(String when) =>",
    """// A PRIVATE class the release NEVER CONSTRUCTS. It is mentioned only as a
// type, so every constructor below is live or dead purely as a function of what
// the interface grants -- which is the whole point.
class _Dead {
  final String tag;

  // The implicit-shaped case: an unnamed, PUBLIC constructor of a private class.
  _Dead() : tag = 'CTOR';

  // A PRIVATE named constructor. `_visitPublicMembers` skips it, so a bare
  // `class:` item cannot annotate it.
  _Dead._mk() : tag = 'NAMED';

  // A factory, and a redirecting generative constructor. Their capability
  // identity is what C4/C5 exist to classify rather than assume.
  factory _Dead.made() => _Dead._mk();
  _Dead.redirect() : this._mk();

  @pragma('vm:never-inline')
  String reachable() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'R' : 'X';
}

// A private class the release DOES instantiate and use, with a private member.
// Cfix/Cfix2 need one: the question they answer is whether member reach SURVIVES
// when the class is granted identity only.
class _Kept {
  final String _hidden =
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'K' : 'X';

  @pragma('vm:never-inline')
  String show() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-k' : 'X';
}

final _kept = _Kept();

// TYPE-ONLY mention. Keeps `_Dead` in the program without allocating it.
_Dead? _slot;

@pragma('vm:never-inline')
String _slotState() => _slot == null ? 'empty' : 'full';

void _state(String when) =>""",
    1,
)
s = s.replace(
    "print('$when alpha=${alpha()} beta=${beta()}');",
    "print('$when alpha=${alpha()} beta=${beta()} slot=${_slotState()} "
    "kept=${_kept.show()}');",
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
SDK_MEMBERS='dart:core#print,dart:core#DateTime.now,dart:core#DateTime.get:millisecondsSinceEpoch'
cd "$WORK"

note "base interface under --policy p2 (every private member and class)"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o prepass.dill "$URI" >/dev/null
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot \
  --no-link-platform --packages .dart_tool/package_config.json \
  -o import.dill "$URI" >/dev/null
# shellcheck disable=SC2086
"$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill prepass.dill \
  --private-dill import.dill --policy p2 \
  --out di_base.yaml --manifest manifest.json --sdk-members "$SDK_MEMBERS" 2>&1 \
  | sed -n 's/^/    /p'
grep -c "class: '_Dead'" di_base.yaml | sed 's/^/    _Dead class items in the generated yaml: /'

# ---------------------------------------------------------------- grant sets
# Each writes di_<arm>.yaml from di_base.yaml, and prints what it did so the
# recorded run explains itself.
grants() { # <arm> <mode>
  python3 - "$1" "$2" <<'PY'
import pathlib, re, sys
arm, mode = sys.argv[1], sys.argv[2]
lines = pathlib.Path('di_base.yaml').read_text().splitlines()

out, i, dropped = [], 0, 0
while i < len(lines):
    # A _Dead item is `- library: X` then `class: '_Dead'`, optionally `member:`.
    if re.match(r"\s*class: '_Dead'\s*$", lines[i]):
        nxt = lines[i + 1] if i + 1 < len(lines) else ''
        has_member = bool(re.match(r'\s*member:', nxt))
        if not has_member:
            # the bare class item -- the one that grants public members
            if mode in ('type_only',):
                out.pop()            # drop its `- library:` line too
                dropped += 1
                i += 1
                continue
        i += 1
        out.append(lines[i - 1])
        continue
    out.append(lines[i]); i += 1

if mode == 'bare_class':
    # ADD the bare private class item back. `gen_dynamic_interface.dart` stopped
    # emitting one on 2026-08-25, which is the fix -- so this arm now constructs
    # the grant deliberately. What it pins is a fact about UPSTREAM's annotator
    # ("a class item grants the class and its public members"), not about our
    # generator's output; the generator's own emission is gated by
    # `probes/p1_generator_capability_gate.sh`.
    out.append("  - library: 'package:dynamic_modules/container_target.dart'")
    out.append("    class: '_Dead'")
elif mode in ('kept_type_only', 'kept_member_only'):
    # THE PROPOSED FIX, modelled: the class keeps IDENTITY only, its private
    # members keep their explicit grants. Re-filter for _Kept rather than _Dead.
    filtered, k = [], 0
    while k < len(out):
        if re.match(r"\s*class: '_Kept'\s*$", out[k]):
            nxt = out[k + 1] if k + 1 < len(out) else ''
            if not re.match(r'\s*member:', nxt):
                filtered.pop()          # drop its `- library:` line too
                k += 1
                continue
        filtered.append(out[k]); k += 1
    out = filtered
    if mode == 'kept_member_only':
        # THE SECOND CANDIDATE FIX: name the TARGET METHOD, not the class. If
        # attach needs the patched member to be callable rather than the class
        # to be callable, this is the whole fix and it lives in our generator.
        out.append("  - library: 'package:dynamic_modules/container_target.dart'")
        out.append("    class: '_Kept'")
        out.append("    member: 'show'")
    else:
        out.append("can-be-used-as-type:")
        out.append("  - library: 'package:dynamic_modules/container_target.dart'")
        out.append("    class: '_Kept'")
elif mode == 'type_only':
    out.append("can-be-used-as-type:")
    out.append("  - library: 'package:dynamic_modules/container_target.dart'")
    out.append("    class: '_Dead'")
elif mode == 'unnamed_ctor':
    # THE EXACT UNNAMED-CONSTRUCTOR GRANT. `member: ''` is how kernel's
    # LibraryIndex names an unnamed constructor, and the spec parser accepts it --
    # so construction can be granted precisely, with no invented
    # "constructible: true" capability. The bare class item is dropped first, so
    # a PASS here can only come from this entry.
    filtered, k = [], 0
    while k < len(out):
        if re.match(r"\s*class: '_Dead'\s*$", out[k]):
            nxt = out[k + 1] if k + 1 < len(out) else ''
            if not re.match(r'\s*member:', nxt):
                filtered.pop()
                k += 1
                continue
        filtered.append(out[k]); k += 1
    out = filtered
    out.append("  - library: 'package:dynamic_modules/container_target.dart'")
    out.append("    class: '_Dead'")
    out.append("    member: ''")
elif mode == 'named_ctor':
    out.append("  - library: 'package:dynamic_modules/container_target.dart'")
    out.append("    class: '_Dead'")
    out.append("    member: '_mk'")

pathlib.Path(f'di_{arm}.yaml').write_text('\n'.join(out) + '\n')
bare = sum(1 for j, l in enumerate(out)
           if re.match(r"\s*class: '_Dead'\s*$", l)
           and not re.match(r'\s*member:', out[j + 1] if j + 1 < len(out) else ''))
named = sum(1 for l in out if re.match(r"\s*member: '_mk'\s*$", l))
asType = 'can-be-used-as-type:' in out
cut = out.index('can-be-used-as-type:') if 'can-be-used-as-type:' in out else len(out)
keptBare = sum(1 for j, l in enumerate(out[:cut])
               if re.match(r"\s*class: '_Kept'\s*$", l)
               and not re.match(r'\s*member:', out[j + 1] if j + 1 < len(out) else ''))
keptHidden = sum(1 for l in out if re.match(r"\s*member: '_hidden'\s*$", l))
print(f"    grants: _Dead bare-class-item={bare} member:_mk={named} "
      f"can-be-used-as-type={asType} (dropped {dropped})")
print(f"            _Kept bare-class-item={keptBare} member:_hidden={keptHidden}")
PY
}

# release_for <arm> -> app_<arm>.aot + BUILD_ID_<arm>
release_for() {
  local arm=$1
  "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
    --packages .dart_tool/package_config.json --dynamic-interface "di_$arm.yaml" \
    -o "release_$arm.dill" "$URI" >/dev/null
  "$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
    --elf="app_$arm.aot" "release_$arm.dill"
  BUILD_ID=$("$AOT_RUNTIME" "app_$arm.aot" | sed -n 's/^BUILD_ID //p')
  [ -n "$BUILD_ID" ] || die "$arm: no release build id"
}

# arm <name> <expect PASS|REFUSE|CLASSIFY> <grant-mode> <body>
arm() {
  local name=$1 expect=$2 mode=$3 body=$4 target=${5:-alpha} probe=${6:-alpha}
  note "$name -- expect $expect"
  grants "$name" "$mode"
  release_for "$name"
  cat > "repl_$name.dart" <<EOF
import '$URI';

@pragma('dyn-module:entry-point')
$body
EOF
  echo "    | $(grep -m1 -E 'String (alpha|show)' "repl_$name.dart")"
  set +e
  "$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" \
    --import-dill import.dill --resolve-private-names-in-library "$URI" \
    --packages .dart_tool/package_config.json \
    -o "repl_$name.bytecode" "repl_$name.dart" > "compile_$name.log" 2>&1
  local crc=$?
  set -e

  local outcome
  if [ "$crc" -ne 0 ]; then
    outcome=COMPILE
    grep -m1 -iE "error" "compile_$name.log" | sed 's/^/      /' || true
  else
    "$DART" "$RB/packaging/pack_patch.dart" --release-build-id "$BUILD_ID" \
      --out "patch_$name.sbrb" \
      --target "$URI#$target=$WORK/repl_$name.bytecode" >/dev/null 2>&1
    set +e
    "$AOT_RUNTIME" "app_$name.aot" "patch_$name.sbrb" > "run_$name.log" 2>&1
    set -e
    local applyLine got
    applyLine=$(grep -m1 '^APPLY' "run_$name.log" || echo 'APPLY <none>')
    # `_state('after ')` prints a TRAILING SPACE in its label, so the line reads
    # `after  alpha=...` with TWO spaces. Matching one read every arm as
    # `<no value>` and turned two passes into STOP rows -- a false negative from
    # the harness, not a result.
    got=$(sed -n "s/^after  *.*$probe=\\([^ ]*\\).*/\\1/p" "run_$name.log" | tail -1)
    got=${got:-'<no value>'}
    echo "      $applyLine"
    echo "      alpha = $got"
    # Only what follows APPLY is this arm's own result: the harness smoke-invokes
    # the attached function from C++ first, and that call can fail on its own.
    sed -n '/^APPLY/,$p' "run_$name.log" > "real_$name.log"
    if echo "$applyLine" | grep -q 'refused'; then
      outcome=ATTACH
    elif [ "$got" = 'OLD-a' ] || [ "$got" = 'OLD-k' ]; then
      outcome=SILENT-OLD
    elif [ "$got" = '<no value>' ]; then
      outcome=BIND
      grep -m1 -iE "unable to find|no such|noSuchMethod|error|exception" \
        "real_$name.log" | sed 's/^/      /' || true
    else
      outcome=PASS
    fi
    local slot
    slot=$(sed -n 's/^after .*slot=\([^ ]*\).*/\1/p' "run_$name.log" | tail -1)
    [ -n "$slot" ] && [ "$slot" != 'empty' ] && \
      invalidate "$name: the release's _Dead slot is no longer empty (slot=$slot)"
  fi
  echo "    OUTCOME: $outcome"
  case "$expect" in
    PASS)   check "$name constructs and runs" "$outcome" "PASS" ;;
    REFUSE) check "$name is refused" "$([ "$outcome" = PASS ] && echo PASS || echo refused)" "refused"
            echo "      refused at: $outcome" ;;
    CLASSIFY) classified=$((classified+1))
            echo "  CLASSIFIED  $name -> $outcome" ;;
  esac
  ARM_OUTCOME=$outcome
}

arm Cctl PASS type_only \
  "String alpha() { final _Dead? x = null; return 'NEW-TYP\${x == null}'; }"
cctl=$ARM_OUTCOME
[ "$cctl" != PASS ] && invalidate "Cctl is a STOP row: _Dead's identity is not reachable under C0's grant set"

arm C0 REFUSE type_only "String alpha() => 'NEW-C0\${_Dead().tag}';"
arm C1 PASS   bare_class "String alpha() => 'NEW-C1\${_Dead().tag}';"
c1=$ARM_OUTCOME
[ "$c1" != PASS ] && invalidate "C1 is a STOP row: the reported hole is not reproduced here"
arm C2 REFUSE bare_class "String alpha() => 'NEW-C2\${_Dead._mk().tag}';"
arm C3 PASS   named_ctor "String alpha() => 'NEW-C3\${_Dead._mk().tag}';"
# THE FIX, MODELLED AND MEASURED. Cfix asks whether member reach survives when a
# private class is granted IDENTITY ONLY; Cfix2 asks whether construction is
# actually withheld under that same grant set. Both must hold, or the fix trades
# one capability for another instead of separating two authorities.
arm Cfix  CLASSIFY kept_type_only \
  "String show(dynamic self) => 'NEW-KEPT\${self._hidden}';" "_Kept.show" "kept"
cfix=$ARM_OUTCOME
[ "$cfix" = PASS ] && echo "  NOTE: Cfix now PASSES -- the refutation recorded in this header no longer holds; re-read it"
arm Cfix2 REFUSE kept_type_only \
  "String alpha() => 'NEW-KCTOR\${_Kept().show()}';"

# CANDIDATE FIX 2: grant the TARGET METHOD explicitly, no bare class item.
arm Cfix3 PASS   kept_member_only \
  "String show(dynamic self) => 'NEW-KEPT3\${self._hidden}';" "_Kept.show" "kept"
arm Cfix4 REFUSE kept_member_only \
  "String alpha() => 'NEW-KCTOR3\${_Kept().show()}';"

# THE CONSTRUCTOR OPT-IN REPRESENTATION: an exact grant, no bare class item.
arm C6 PASS   unnamed_ctor \
  "String alpha() { _Dead(); return 'NEW-C6ok'; }"

arm C4 CLASSIFY bare_class "String alpha() => 'NEW-C4\${_Dead.made().tag}';"
arm C5 CLASSIFY bare_class "String alpha() => 'NEW-C5\${_Dead.redirect().tag}';"

note "RESULT"
echo "  pass=$pass fail=$fail invalid=$invalid classified=$classified"
echo "  work dir kept: $WORK"
[ "$invalid" -gt 0 ] && { echo "  VERDICT: INVALID -- at least one arm proves nothing"; exit 3; }
[ "$fail" -gt 0 ] && { echo "  VERDICT: RED"; exit 1; }
echo "  VERDICT: GREEN (against the precommitted table; C4/C5 are classifications)"
