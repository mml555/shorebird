#!/usr/bin/env bash
# cspell:words dartaotruntime dynmod
#
# run_1a.sh -- D-SUPER-1A. Can a dynamic module reference a Procedure that
# belongs to the already-AOT-compiled app?
#
# Modelled on ../../verify_binding.sh, which is the harness that settled the
# equivalent question for an SDK symbol. The difference is the target: this one
# calls an APP top-level function, which is the reference shape a receiver-taking
# DirectCall would have to extend.
#
# THE OBSERVABLE IS SHARED STATE. See target_1a.dart: APP:PROBE:3 means the
# release's own procedure ran; APP:PROBE:1 means a copy in the payload did. Both
# print "APP:PROBE".
set -euo pipefail

SRC="${SRC:-/Volumes/build/route-b/flutter/engine/src}"
OUT="${OUT:-$SRC/out/host_release_arm64}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
WORK="${WORK:-$(mktemp -d)}"
NEGATIVE="${NEGATIVE:-0}"

DART_TREE="$SRC/flutter/third_party/dart"
DART="$OUT/dart-sdk/bin/dart"
GEN_KERNEL="$DART_TREE/pkg/vm/bin/gen_kernel.dart"
DART2BC="$DART_TREE/pkg/dart2bytecode/bin/dart2bytecode.dart"
GEN_SNAPSHOT="$OUT/gen_snapshot"
AOT_RUNTIME="$OUT/dartaotruntime"
TARGET_URI="package:dynamic_modules/target_1a.dart"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }

grep -q 'dart_dynamic_modules = true' "$OUT/args.gn" 2>/dev/null \
  || die "dart_dynamic_modules is not true in $OUT/args.gn"

mkdir -p "$WORK/lib" "$WORK/.dart_tool"
cp "$HERE/target_1a.dart" "$WORK/lib/target_1a.dart"
cp "$HERE/replacement_1a.dart" "$WORK/replacement.dart"
cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$WORK/",
    "packageUri": "lib/", "languageVersion": "3.9" } ] }
JSON
cd "$WORK"

note "1/5 discovery kernel"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json -o discover.dill "$TARGET_URI" \
  >/dev/null

note "2/5 dynamic interface"
"$DART" --packages="$DART_TREE/.dart_tool/package_config.json" \
  "$HERE/../../gen_dynamic_interface.dart" --dill discover.dill --out di.yaml

if [ "$NEGATIVE" = "1" ]; then
  # THE NEGATIVE CONTROL. Withhold retention of the very function the
  # replacement calls, and nothing else. It must fail to bind rather than
  # silently resolve to something else by name.
  note "NEGATIVE CONTROL: removing releaseTopLevel from the dynamic interface"
  # Retention for app code is granted WHOLE-LIBRARY, so there is no per-symbol
  # line to delete -- the first attempt at this control tried, dropped nothing,
  # and its own assertion stopped it from reporting a vacuous PASS. The library
  # grant is therefore replaced by explicit member grants for every top-level
  # member EXCEPT the one the replacement calls.
  python3 - <<'PY'
import io
LIB = 'package:dynamic_modules/target_1a.dart'
WITHHELD = 'releaseTopLevel'
GRANTED = ['greet', 'main', '_releaseCounter']
text = io.open('di.yaml').read()
bare = "  - library: '%s'\n" % LIB
assert text.count(bare) >= 1, 'no whole-library grant found -- control would be vacuous'
replacement = ''.join(
    "  - library: '%s'\n    member: '%s'\n" % (LIB, m) for m in GRANTED)
text = text.replace(bare, replacement, 1)
io.open('di.yaml', 'w').write(text)
print('    whole-library grant replaced by %d member grants; %s WITHHELD'
      % (len(GRANTED), WITHHELD))
assert WITHHELD not in text, 'the withheld symbol is still named in the interface'
PY
fi
sed 's/^/    /' di.yaml | head -30

note "3/5 release kernel + AOT snapshot"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
  --packages .dart_tool/package_config.json \
  --dynamic-interface di.yaml -o target.dill "$TARGET_URI" >/dev/null
"$GEN_SNAPSHOT" --patchable_static_calls \
  --snapshot_kind=app-aot-elf --elf=target.aot target.dill

note "4/5 replacement bytecode, compiled against the release's kernel"
"$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
  --no-aot --no-link-platform \
  --packages .dart_tool/package_config.json -o host_import.dill "$TARGET_URI" \
  >/dev/null
set +e
"$DART" "$DART2BC" --platform "$OUT/vm_platform.dill" \
  --import-dill host_import.dill \
  -o replacement.bytecode replacement.dart 2>&1 | tee compile.log
bc_rc=${PIPESTATUS[0]}
set -e
if [ "$bc_rc" -ne 0 ]; then
  echo "RESULT: the compiler refused the replacement (exit $bc_rc)"; exit 1
fi
echo "    payload: $(wc -c < replacement.bytecode | tr -d ' ') bytes"

# OBSERVABLE 2, first half: the payload NAMES the app procedure. Necessary but
# not sufficient -- a copied body would also carry the name -- which is why the
# shared-state observable below is the one that decides.
if strings replacement.bytecode | grep -q releaseTopLevel; then
  echo "    payload references the symbol releaseTopLevel"
else
  echo "    payload does NOT name releaseTopLevel"
fi

note "5/5 run"
echo "--------------------------------------------------"
set +e
"$AOT_RUNTIME" target.aot replacement.bytecode "$TARGET_URI" 2>&1 | tee run.log
set -e
echo "--------------------------------------------------"

echo
got=$(grep -oE 'APP:PROBE:[0-9]+' run.log | head -1 || true)
attached=$(grep -c '^attach: true' run.log || true)
if [ "$NEGATIVE" = "1" ]; then
  if [ -n "$got" ]; then
    echo "CONTROL FAILED: bound anyway, and returned $got."
    echo "  Withholding retention did not prevent binding — the reference is"
    echo "  resolving by some route this probe did not intend."
    exit 1
  fi
  echo "CONTROL HELD: with retention withheld, no APP:PROBE result appeared."
  echo "  So the positive arm is measuring retention-backed binding, not a"
  echo "  reference that would have resolved regardless."
  exit 0
fi

if [ "$attached" -eq 0 ]; then
  echo "RESULT: FAIL — the module did not attach."; exit 1
fi
case "$got" in
  APP:PROBE:3)
    echo "RESULT: PASS — $got"
    echo "  The replacement called the RELEASE's own procedure: it continued the"
    echo "  release's private counter (warmed to 2 before the patch existed)."
    echo "  A copy carried in the payload would have printed APP:PROBE:1." ;;
  APP:PROBE:1)
    echo "RESULT: FAIL — $got"
    echo "  The symbol resolved, but to a COPY with its own state, not to the"
    echo "  app's Procedure. This is the outcome that makes bucket B false." ;;
  "")
    echo "RESULT: FAIL — no APP:PROBE result; the call never bound or never ran." ;;
  *)
    echo "RESULT: UNEXPECTED — $got" ;;
esac
echo
echo "work dir kept: $WORK"
