#!/usr/bin/env bash
# cspell:words dartaotruntime obfuscate deobfuscate
#
# g43_obfuscation_semantics.sh -- G4.3: which obfuscation flags are SEMANTIC?
#
# The mistake this probe exists to prevent is deciding from what a flag sounds
# like. G4.1 established the shape: a release→patch compatibility check must be
# decided on the EFFECTIVE COMPILER INPUTS, and anything that only describes where
# output goes belongs in raw provenance with no refusal attached. Obfuscation is
# where that distinction bites hardest, because `--split-debug-info=<dir>` carries
# an ABSOLUTE PATH. Fingerprinting it would make two machines that produce the
# identical program incompatible purely because their filesystem layouts differ.
#
# So each flag is classified by measurement:
#
#   1 plain vs --obfuscate                      does the emitted program change?
#   2 plain vs --save-debugging-info            does the program change, or only
#                                               the symbol artifact?
#   3 --obfuscate, path A vs path B             is the path semantic, or only a
#                                               destination?
#   4 the symbols file                           actually written where asked?
#   5 ROUTE B: are the identifiers the dynamic interface and capability manifest
#     name captured BEFORE or AFTER obfuscation, and does name-based target
#     resolution still work on an obfuscated release?
#
# Row 5 is the one that matters most and it is not about flags at all. The
# dangerous failure is not "the patch compiler used different flags"; it is release
# provenance naming one symbol while the runtime looks up another transformed
# identity. Route B resolves its target by LIBRARY URI AND NAME at attach time
# (`Dart_RouteBActivatePatch(payload, len, library_uri, target_name)`), so if
# obfuscation renames what the snapshot can be searched for, a perfectly correct
# patch refuses on device with "function not found" -- and every flag check in the
# world would have passed first.
#
# ALREADY ESTABLISHED BEFORE THE FIRST ARM RUNS, by reading the tools: gen_kernel
# accepts NEITHER flag (`gen_kernel --help` matches zero of them), while
# gen_snapshot accepts both. Obfuscation is therefore a snapshot-stage transform,
# and the import kernel a patch binds against cannot carry obfuscated names. That
# is why row 5 asks about the RUNTIME lookup rather than about the kernel.
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
ENGINE=${ENGINE:-g43localhost}
CELL_ZIP=${CELL_ZIP:-$WORK/cell.zip}

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }
pass=0; fail=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "  PASS  $1 -> $2"; pass=$((pass+1));
  else echo "  FAIL  $1: got '$2', want '$3'"; fail=$((fail+1)); fi
}

[ -x "$DART" ] || die "no host dart at $DART"
[ -x "$GEN_SNAPSHOT" ] || die "no gen_snapshot at $GEN_SNAPSHOT"

echo "G4.3: obfuscation flag semantics, measured through the release compiler path"
echo

# ---- part 1: flag classification, one kernel, five snapshots ----------------
#
# ONE kernel for every arm, which is itself the first finding: gen_kernel has no
# obfuscation flag, so the kernel cannot vary. Any difference below is produced
# entirely by gen_snapshot.
mkdir -p "$WORK/p1" "$WORK/p1/symA" "$WORK/p1/symB"
cat > "$WORK/p1/main.dart" <<'DART'
class Widget {
  @pragma('vm:never-inline')
  String describe() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'described' : 'X';
}

void main() => print(Widget().describe());
DART

"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  -o "$WORK/p1/app.dill" "$WORK/p1/main.dart" >/dev/null
KERNEL_SHA=$(shasum -a 256 "$WORK/p1/app.dill" | cut -d' ' -f1)
note "one kernel feeds every arm: ${KERNEL_SHA:0:16}"

# TWO HASHES PER ARM, and the difference between them is the whole point.
#
# The UNSTRIPPED ELF carries DWARF. Measured: `--save-debugging-info=A` and
# `=B` produce ELFs with DIFFERENT bytes, and so does adding the flag at all --
# but that difference lives entirely in debug sections. Hashing the whole file
# would therefore classify a symbol-output path as a semantic compiler input, and
# fingerprinting it would make two machines that emit the identical program
# incompatible because their filesystem layouts differ.
#
# So the PROGRAM is measured with --strip, which excludes DWARF. Both numbers are
# printed, because "the file differs" is a true and useful fact about
# reproducibility even when "the program differs" is false.
snap() { # <name> <extra gen_snapshot args...>
  local name="$1"; shift
  "$GEN_SNAPSHOT" --snapshot_kind=app-aot-elf \
    --elf="$WORK/p1/$name.aot" "$@" "$WORK/p1/app.dill" >/dev/null 2>&1 \
    || { echo "<gen_snapshot failed for $name>"; return 0; }
  shasum -a 256 "$WORK/p1/$name.aot" | cut -d' ' -f1
}

prog() { # <name> <extra gen_snapshot args...> -> sha of the PROGRAM (DWARF excluded)
  local name="$1"; shift
  "$GEN_SNAPSHOT" --snapshot_kind=app-aot-elf --strip \
    --elf="$WORK/p1/$name.stripped.aot" "$@" "$WORK/p1/app.dill" \
    >/dev/null 2>&1 \
    || { echo "<gen_snapshot failed for $name>"; return 0; }
  shasum -a 256 "$WORK/p1/$name.stripped.aot" | cut -d' ' -f1
}

A=$(snap plain);  a=$(prog plain)
B=$(snap obf --obfuscate); b=$(prog obf --obfuscate)
C=$(snap obf_symA --obfuscate --save-debugging-info="$WORK/p1/symA/app.symbols")
c=$(prog obf_symA --obfuscate --save-debugging-info="$WORK/p1/symA/app.symbols")
D=$(snap obf_symB --obfuscate --save-debugging-info="$WORK/p1/symB/app.symbols")
d=$(prog obf_symB --obfuscate --save-debugging-info="$WORK/p1/symB/app.symbols")
E=$(snap sym_only --save-debugging-info="$WORK/p1/symA/plain.symbols")
e=$(prog sym_only --save-debugging-info="$WORK/p1/symA/plain.symbols")

printf '    %-26s file %s  program %s\n' "plain"                   "${A:0:16}" "${a:0:16}"
printf '    %-26s file %s  program %s\n' "--obfuscate"             "${B:0:16}" "${b:0:16}"
printf '    %-26s file %s  program %s\n' "--obfuscate + symbols A" "${C:0:16}" "${c:0:16}"
printf '    %-26s file %s  program %s\n' "--obfuscate + symbols B" "${D:0:16}" "${d:0:16}"
printf '    %-26s file %s  program %s\n' "symbols only"            "${E:0:16}" "${e:0:16}"
echo

note "1. does --obfuscate change the emitted PROGRAM?"
if [ "$a" != "$b" ]; then r=changes; else r=identical; fi
check "obfuscation is a SEMANTIC compiler input" "$r" changes

note "2. does --save-debugging-info alone change the PROGRAM?"
if [ "$a" = "$e" ]; then r=identical; else r=changes; fi
check "symbol emission leaves the program byte-identical" "$r" identical
if [ "$A" = "$E" ]; then f=identical; else f=differs; fi
echo "      (the unstripped FILE $f — DWARF only, which is why the program is"
echo "       measured with --strip and the path never enters a fingerprint)"

note "3. is the --save-debugging-info PATH semantic?"
if [ "$c" = "$d" ]; then r=identical; else r=changes; fi
check "two different symbol paths produce the SAME program" "$r" identical
if [ "$C" = "$D" ]; then f=identical; else f=differs; fi
echo "      (unstripped files $f: the path reaches DWARF, not the program)"

note "4. is the symbols file written where asked?"
[ -s "$WORK/p1/symA/app.symbols" ] && a=yes || a=no
[ -s "$WORK/p1/symB/app.symbols" ] && b=yes || b=no
check "symbols land at path A" "$a" yes
check "symbols land at path B" "$b" yes

# ---- part 2: Route B identity under obfuscation ----------------------------
#
# Does a release built WITH --obfuscate still resolve a Route B target by name?
# Everything up to gen_snapshot is unobfuscated by construction, so the interface
# and the manifest necessarily name pre-obfuscation identifiers; the question is
# whether the thing they name is still findable in the shipped snapshot.
note "5. Route B: identifiers, and whether an obfuscated release resolves them"

FLUTTER_PLATFORM=${FLUTTER_PLATFORM:-/Volumes/build/route-b/published_sdk/flutter_patched_sdk_product/platform_strong.dill}
stage=$WORK/cell; mkdir -p "$stage"
cp "$OUT/zip_archives/dart2bytecode_aot.snapshot" "$stage/dart2bytecode.aot"
cp "$OUT/dartaotruntime" "$stage/dartaotruntime"
cp "$OUT/vm_platform.dill" "$stage/vm_platform.dill"
cp "$OUT/zip_archives/route_b_analyze.aot" "$stage/route_b_analyze.aot"
cp "$OUT/zip_archives/route_b_gen_kernel.aot" "$stage/route_b_gen_kernel.aot"
cp "$OUT/zip_archives/route_b_gen_dynamic_interface.aot" \
  "$stage/route_b_gen_dynamic_interface.aot"
cp "$FLUTTER_PLATFORM" "$stage/flutter_platform_strong.dill"
{
  echo "Route B compiler cell (UNPUBLISHED, staged by g43_obfuscation_semantics.sh)"
  echo "engine revision : $ENGINE"
  for f in dartaotruntime dart2bytecode.aot vm_platform.dill \
    route_b_analyze.aot route_b_gen_kernel.aot \
    route_b_gen_dynamic_interface.aot flutter_platform_strong.dill; do
    echo "$f : $(shasum -a 256 "$stage/$f" | cut -d' ' -f1)"
  done
} > "$stage/PROVENANCE.txt"
(cd "$stage" && zip -q -r "$CELL_ZIP" .)

URI=package:dynamic_modules/container_target.dart
SDK_MEMBERS='dart:core#print,dart:core#DateTime.now,dart:core#DateTime.get:millisecondsSinceEpoch'
dir=$WORK/rb; mkdir -p "$dir/lib" "$dir/.dart_tool"
cat > "$dir/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$dir/", "packageUri": "lib/",
    "languageVersion": "3.9" },
  { "name": "crypto", "rootUri": "file://$PKGS_DIR/crypto", "packageUri": "lib/",
    "languageVersion": "3.4" },
  { "name": "typed_data", "rootUri": "file://$PKGS_DIR/typed_data",
    "packageUri": "lib/", "languageVersion": "3.4" } ] }
JSON

stage_app() { # <body>
  cp "$RB/packaging/container_target.dart" "$dir/lib/container_target.dart"
  BODY="$1" python3 - "$dir/lib/container_target.dart" <<'PY'
import os, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace("void _state(String when) =>", """class Obf {
  @pragma('vm:never-inline')
  %s
}

void _state(String when) =>""" % os.environ['BODY'], 1)
s = s.replace("print('$when alpha=${alpha()} beta=${beta()}');",
              "print('$when alpha=${alpha()} obf=${Obf().value()}');", 1)
p.write_text(s)
PY
}

( cd "$dir"
  stage_app "String value() => DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-obf' : 'X';"
  "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
    --packages .dart_tool/package_config.json -o prepass.dill "$URI" >/dev/null
  "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot \
    --no-link-platform --packages .dart_tool/package_config.json \
    -o import.dill "$URI" >/dev/null
  # shellcheck disable=SC2086
  "$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill prepass.dill \
    --private-dill import.dill --policy p2 --out di.yaml \
    --manifest manifest.json --sdk-members "$SDK_MEMBERS" >/dev/null 2>&1
  "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
    --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
    -o base.dill "$URI" >/dev/null
  # THE RELEASE IS OBFUSCATED. Everything above it is not, and cannot be.
  "$GEN_SNAPSHOT" --patchable_static_calls --obfuscate \
    --save-debugging-info="$dir/app.symbols" \
    --snapshot_kind=app-aot-elf --elf=app.aot base.dill
  stage_app "String value() => 'NEW-obf';"
  "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
    --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
    -o patched.dill "$URI" >/dev/null )

# 5a. What the interface and manifest NAME. Pre-obfuscation by construction, and
# asserted rather than assumed -- if these ever carried transformed identities the
# whole model would change.
# Retention is LIBRARY-scoped for app libraries, so the interface names the
# library URI rather than the class -- asserting on the class name would have
# been asserting on a design this file does not have.
if grep -q "library: '$URI'" "$dir/di.yaml" 2>/dev/null; then i=source; else i=absent; fi
check "the interface names the SOURCE library URI" "$i" source
# The manifest keys private members as library#Class#member, in source spelling.
if grep -qE "#_[A-Za-z]" "$dir/manifest.json" 2>/dev/null; then m=source; else m=absent; fi
check "the manifest keys members in SOURCE spelling" "$m" source
echo "      Both are generated from the PREPASS kernel, which gen_kernel produces"
echo "      with no obfuscation flag available to it — so they cannot carry"
echo "      transformed identities, by construction rather than by luck."

# 5b. Is that identifier still findable in the OBFUSCATED snapshot?
if strings -a "$dir/app.aot" | grep -q "Obf"; then s=present; else s=stripped; fi
note "    the source identifier in the obfuscated snapshot: $s"

# 5c. The decisive one: does the container APPLY against the obfuscated release?
buildId=$("$AOT_RUNTIME" "$dir/app.aot" | sed -n 's/^BUILD_ID //p')
[ -n "$buildId" ] || die "no build id from the obfuscated release"
armDir=$dir/arm; mkdir -p "$armDir"
set +e
"$DART" --packages="$CLI_PKGS" "$HERE/cli_lower.dart" \
  "$CELL_ZIP" "$dir/base.dill" "$dir/patched.dill" "$dir/import.dill" \
  "$buildId" "$armDir/cli" "$dir" "$OUT/vm_platform.dill" "$ENGINE" \
  "$dir/manifest.json" > "$armDir/cli.log" 2>&1
set -e
container=$(sed -n 's/^ *OUT=//p' "$armDir/cli.log")
if [ ! -f "$container" ]; then
  echo "  FAIL  the CLI produced no container for the obfuscated release"
  sed -n 's/^/        /p' "$armDir/cli.log" | tail -6
  fail=$((fail+1))
else
  set +e
  "$AOT_RUNTIME" "$dir/app.aot" "$container" > "$armDir/run.log" 2>&1
  set -e
  applied=$(sed -n 's/^APPLY //p' "$armDir/run.log" | head -1)
  value=$(sed -n 's/^after .*obf=\([^ ]*\).*/\1/p' "$armDir/run.log" | tail -1)
  echo "    APPLY: ${applied:-<none>}    value after: ${value:-<none>}"
  if [ "$value" = "NEW-obf" ]; then rb=applies; else rb=refused-or-unchanged; fi
  check "an obfuscated release resolves and patches a named target" "$rb" applies
  [ "$rb" = applies ] || sed -n 's/^/        /p' "$armDir/run.log" | head -8
fi

echo
echo "--------------------------------------------------"
echo "obfuscation semantics: $pass passed, $fail failed"
echo "work dir kept: $WORK"
echo
echo "THE CONFIGURATION MODEL THIS LICENSES:"
echo "  * --obfuscate            SEMANTIC -> effectiveDefines-equivalent field,"
echo "                           fingerprinted, mismatch refuses"
echo "  * --save-debugging-info  OUTPUT-ONLY -> raw provenance, no refusal, and"
echo "                           its PATH must never enter the fingerprint"
[ "$fail" -eq 0 ] || exit 1
