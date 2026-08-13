#!/usr/bin/env bash
# cspell:words dartaotruntime
#
# g41_define_semantics.sh -- G4.1: what do duplicate and reordered defines MEAN?
#
# WHY THIS RUNS BEFORE ANY FINGERPRINT CODE EXISTS. A release→patch compatibility
# check needs a canonical form for "the effective define set", and the tempting move
# is to invent one: sort the keys, drop duplicates, compare the text. Each of those
# is a guess about compiler behaviour, and a wrong guess produces the worst possible
# outcome in this project -- a check that PASSES two configurations which compile
# differently, or refuses two that compile identically.
#
# So the canonical form is derived from measurement. Three questions, each answered
# by the toolchain rather than by reading docs:
#
#   1 DUPLICATE KEY   -Dk=1 -Dk=2 : which value reaches the program?
#   2 ORDER           -Da=1 -Db=2 vs -Db=2 -Da=1 : same kernel bytes?
#   3 EMPTY VALUE     -Dk= : is that a defined empty string or undefined?
#
# Each answer becomes a rule in the fingerprint, and the rule cites this probe.
#
# Compiled through gen_kernel/gen_snapshot -- the same path a release takes -- not
# through `dart run`, because the question is about what the RELEASE compiler does
# with these flags.
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
DART_TREE=$SRC/flutter/third_party/dart
DART=$OUT/dart-sdk/bin/dart
GEN_KERNEL=$DART_TREE/pkg/vm/bin/gen_kernel.dart
GEN_SNAPSHOT=$OUT/gen_snapshot
AOT_RUNTIME=$OUT/dartaotruntime
WORK=${WORK:-$(mktemp -d)}

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }
pass=0; fail=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "  PASS  $1 -> $2"; pass=$((pass+1));
  else echo "  FAIL  $1: got '$2', want '$3'"; fail=$((fail+1)); fi
}

[ -x "$DART" ] || die "no host dart at $DART"
[ -x "$GEN_SNAPSHOT" ] || die "no gen_snapshot at $GEN_SNAPSHOT"

cat > "$WORK/main.dart" <<'DART'
// `const String.fromEnvironment` is the only reader that matters here: it is what
// -D feeds, and it is resolved at COMPILE time, which is exactly why a patch
// compiled with a different set than its release is a silent behaviour change
// rather than a runtime error.
const a = String.fromEnvironment('a', defaultValue: '<unset>');
const b = String.fromEnvironment('b', defaultValue: '<unset>');
const k = String.fromEnvironment('k', defaultValue: '<unset>');
void main() {
  print('a=$a b=$b k=$k');
}
DART

# run <label> <flags...> -> prints the program's line
run_with() {
  local label="$1"; shift
  local d="$WORK/$label"; mkdir -p "$d"
  "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
    "$@" -o "$d/app.dill" "$WORK/main.dart" >/dev/null 2>"$d/kernel.err" \
    || { echo "<gen_kernel failed: $(tail -1 "$d/kernel.err")>"; return 0; }
  "$GEN_SNAPSHOT" --snapshot_kind=app-aot-elf --elf="$d/app.aot" "$d/app.dill" \
    >/dev/null 2>&1 || { echo "<gen_snapshot failed>"; return 0; }
  "$AOT_RUNTIME" "$d/app.aot" 2>/dev/null | tail -1
}

# kernel_sha <label> <flags...> -> sha256 of the produced NON-aot kernel
kernel_sha() {
  local label="$1"; shift
  local d="$WORK/$label"; mkdir -p "$d"
  "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot \
    --no-link-platform "$@" -o "$d/k.dill" "$WORK/main.dart" >/dev/null 2>&1 \
    || { echo "<failed>"; return 0; }
  shasum -a 256 "$d/k.dill" | cut -d' ' -f1
}

echo "G4.1: define semantics, measured through the release compiler path"
echo

note "1. duplicate key: -Dk=first -Dk=second"
dup=$(run_with dup -Dk=first -Dk=second)
echo "    $dup"
case "$dup" in
  *"k=second"*) rule=last-wins ;;
  *"k=first"*)  rule=first-wins ;;
  *)            rule=unknown ;;
esac
check "a duplicated key resolves to ONE value, and which" "$rule" last-wins

note "2. order: -Da=1 -Db=2 versus -Db=2 -Da=1"
s1=$(kernel_sha order_ab -Da=1 -Db=2)
s2=$(kernel_sha order_ba -Db=2 -Da=1)
echo "    a,b -> ${s1:0:16}"
echo "    b,a -> ${s2:0:16}"
if [ "$s1" = "$s2" ]; then order=identical; else order=different; fi
check "reordering distinct keys produces identical kernel bytes" "$order" identical

note "3. empty value: -Dk="
empty=$(run_with empty -Dk=)
echo "    $empty"
case "$empty" in
  *"k=<unset>"*) e=undefined ;;
  *"k= "*|*"k=")  e=defined-empty ;;
  *) e=other ;;
esac
check "an empty value is a DEFINED empty string, not undefined" "$e" defined-empty

note "4. control: no defines at all"
none=$(run_with none)
echo "    $none"
case "$none" in *"a=<unset> b=<unset> k=<unset>"*) c=all-unset ;; *) c=unexpected ;; esac
check "with no defines every key is unset" "$c" all-unset

echo
echo "--------------------------------------------------"
echo "define semantics: $pass passed, $fail failed"
echo "work dir kept: $WORK"
echo
echo "THE CANONICAL FORM THIS LICENSES:"
echo "  * duplicates collapse by $rule, so the effective set is a MAP not a list"
echo "  * key order is $order in the kernel, so the map may be sorted for comparison"
echo "  * an empty value is a real value ($e), so absent != empty"
[ "$fail" -eq 0 ] || exit 1
