#!/usr/bin/env bash
# cspell:words dynmod killgate dartaotruntime sbrb bytearray SBRBPTCH
#
# verify_container.sh -- Route B step 4 end to end, including the refusals.
#
# Positive path: build a release, read its build ID, compile two replacement
# bodies, pack them into ONE container, apply it, see BOTH functions change,
# then revert and see both come back.
#
# The negative paths are the point, though. A patch format earns its keep by
# what it refuses:
#
#   wrong release   -- bytecode compiled against another build's kernel
#   corrupt payload -- a flipped byte in a bytecode blob
#   partial apply   -- one good target, one unresolvable; nothing may stick
#
# The third is the one a one-target harness cannot test at all, which is why
# the target program has two functions.
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
RB="$(cd "$HERE/.." >/dev/null 2>&1 && pwd)"
WORK="${WORK:-$(mktemp -d)}"

DART_TREE="$SRC/flutter/third_party/dart"
DART="$OUT/dart-sdk/bin/dart"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
DART2BC="$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart"
GEN_SNAPSHOT="$OUT/gen_snapshot"
AOT_RUNTIME="$OUT/dartaotruntime"
URI="package:dynamic_modules/container_target.dart"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }
pass=0; fail=0
check() { # check <label> <expected-substring> <file>
  if grep -qF "$2" "$3"; then echo "  PASS  $1"; pass=$((pass+1));
  else echo "  FAIL  $1 (expected: $2)"; sed 's/^/        /' "$3"; fail=$((fail+1)); fi
}

[ -d "$OUT" ] || die "no build at $OUT"

mkdir -p "$WORK/lib" "$WORK/.dart_tool"
cp "$HERE/container_target.dart" "$WORK/lib/container_target.dart"
# The release imports package:crypto to verify payload hashes, so the harness
# package config has to resolve it (and its dependency) out of the Dart tree.
PKGS="$DART_TREE/third_party/pkg/core/pkgs"
cat > "$WORK/.dart_tool/package_config.json" <<JSON
{
  "configVersion": 2,
  "packages": [
    { "name": "dynamic_modules", "rootUri": "file://$WORK/",
      "packageUri": "lib/", "languageVersion": "3.9" },
    { "name": "crypto", "rootUri": "file://$PKGS/crypto",
      "packageUri": "lib/", "languageVersion": "3.4" },
    { "name": "typed_data", "rootUri": "file://$PKGS/typed_data",
      "packageUri": "lib/", "languageVersion": "3.4" }
  ]
}
JSON
cd "$WORK"

note "release: kernel -> dynamic interface -> snapshot"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o discover.dill "$URI" >/dev/null
"$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
  "$RB/gen_dynamic_interface.dart" --dill discover.dill --out di.yaml 2>/dev/null
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json \
  --dynamic-interface di.yaml -o app.dill "$URI" >/dev/null
"$GEN_SNAPSHOT" --patchable_static_calls \
  --snapshot_kind=app-aot-elf --elf=app.aot app.dill
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
  --no-aot --no-link-platform \
  --packages .dart_tool/package_config.json -o import.dill "$URI" >/dev/null

BUILD_ID=$("$AOT_RUNTIME" app.aot | sed -n 's/^BUILD_ID //p')
[ -n "$BUILD_ID" ] && [ "$BUILD_ID" != "<none>" ] \
  || die "release reports no build id -- the release identity is unusable"
note "release build id: $BUILD_ID"

emit() { # emit <name> <fn> <value>
  cat > "$WORK/$1.dart" <<DART
@pragma('dyn-module:entry-point')
String $2() => 'NEW-$3';
DART
  "$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" \
    --import-dill import.dill -o "$WORK/$1.bytecode" "$WORK/$1.dart" \
    >/dev/null 2>&1 || die "dart2bytecode failed for $1"
}
emit alpha alpha a
emit beta  beta  b

pack() { "$DART" "$HERE/pack_patch.dart" "$@" 2>/dev/null; }

note "1. two targets, one container, applied atomically"
pack --release-build-id "$BUILD_ID" --out good.sbrb \
  --target "$URI#alpha=$WORK/alpha.bytecode" \
  --target "$URI#beta=$WORK/beta.bytecode"
"$AOT_RUNTIME" app.aot good.sbrb --revert > r1.log 2>&1 || true
check "applies"            "APPLY ok: 2 target(s)"          r1.log
check "both changed"       "after  alpha=NEW-a beta=NEW-b"  r1.log
check "reverts both"       "REVERT detached=2"              r1.log
check "original restored"  "revert alpha=OLD-a beta=OLD-b"  r1.log

# A build ID that is well-formed but cannot be this release's.
WRONG_ID="00000000000000000000000000000000"
note "2. refuses a container built for another release"
pack --release-build-id "$WRONG_ID" --out wrong.sbrb \
  --target "$URI#alpha=$WORK/alpha.bytecode"
"$AOT_RUNTIME" app.aot wrong.sbrb > r2.log 2>&1 || true
check "refused"            "APPLY refused: built for $WRONG_ID" r2.log
check "nothing applied"    "after  alpha=OLD-a beta=OLD-b"     r2.log

note "3. refuses a corrupt payload"
python3 - "$WORK/good.sbrb" "$WORK/corrupt.sbrb" <<'PY'
import sys
b = bytearray(open(sys.argv[1], 'rb').read())
b[-1] ^= 0xFF          # flip a byte in the last payload
open(sys.argv[2], 'wb').write(bytes(b))
PY
"$AOT_RUNTIME" app.aot corrupt.sbrb > r3.log 2>&1 || true
check "refused"            "malformed container"           r3.log
check "nothing applied"    "after  alpha=OLD-a beta=OLD-b" r3.log

note "4. a partial apply leaves nothing attached"
pack --release-build-id "$BUILD_ID" --out partial.sbrb \
  --target "$URI#alpha=$WORK/alpha.bytecode" \
  --target "$URI#noSuchFunction=$WORK/beta.bytecode"
"$AOT_RUNTIME" app.aot partial.sbrb > r4.log 2>&1 || true
check "refused"            "did not attach; rolled back 1"  r4.log
check "alpha rolled back"  "after  alpha=OLD-a beta=OLD-b"  r4.log

echo
echo "--------------------------------------------------"
echo "step 4: $pass passed, $fail failed"
echo "work dir kept: $WORK"
[ "$fail" -eq 0 ] || exit 1
