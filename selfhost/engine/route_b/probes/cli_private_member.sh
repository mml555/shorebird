#!/usr/bin/env bash
# cspell:words dartaotruntime prepass
#
# cli_private_member.sh -- G3.6b's host path: does the PRODUCT accept a private
# member on the strength of the release's own capability manifest, and refuse it
# without one?
#
# WHAT IS NEW HERE, AND WHY IT NEEDED ITS OWN PROBE.
#
# `d_private.sh` proved the MECHANISM on host: a replacement library can name the
# release's private member, given `--resolve-private-names-in-library` and a
# release that retained it. `private_receiver.sh` proved the CLI lowers a private
# CLASS to a dynamic receiver. Both drove the pieces directly.
#
# Neither one asks the question G3.6b is about: does the CLI's own accept/refuse
# decision read the release's manifest? That decision is per-target and lives
# nowhere in the mechanism -- a release can grant a member and withhold its
# class, and then the patch compiles and attaches to nothing. So this runs the
# CLI's analyzer and producer over a release that published a manifest, and over
# the same release with a narrowed one.
#
# THE PRODUCT SHAPE, unchanged from what Phase 0 found dominating:
#
#   class _Hidden {
#     String _secret = 'NEW-PRIV';    // PRIVATE, and never used by the release
#     String value() => 'OLD-priv';   // <- the patch target
#   }
#
# The app allocates `_Hidden`; the patch replaces `value()` and reads `_secret`
# through the receiver the lowering supplies. Both the class and the member are
# private, which is the case P2 exists for.
#
# THREE ARMS. The first is the product path; the other two are controls, and each
# fails for a DIFFERENT reason, which is the whole point of running them:
#
#   granted        manifest names the member AND the class    -> app reads NEW
#   class_withheld manifest names the member, not the class   -> CLI REFUSES
#                  (P3's shape: the grant is real and inert)
#   no_manifest    release published no manifest at all       -> CLI REFUSES
#                  (every release cut before manifests existed)
#
# A control that merely failed would prove nothing -- it has to fail HERE, in the
# CLI, with a reason naming the missing capability, rather than downstream with a
# message about attachment.
#
# Host, not device. This is a producer-and-manifest question; the device
# round-trip is separate.
#
#   cli_private_member.sh
#   CELL_ZIP=... ENGINE=... cli_private_member.sh
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
# The cell must carry a v7 analyzer: v6 refused a private access outright, and
# the CLI pins supportedRouteBAnalysisVersion to 7. Default to a cell staged from
# the current build tree, because no v7 cell is published yet -- that is the mint
# this probe is meant to gate, not a prerequisite for it.
CELL_ZIP=${CELL_ZIP:-$WORK/cell.zip}
ENGINE=${ENGINE:-local-v7-unpublished}

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }
pass=0; fail=0
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1));
  else echo "  FAIL  $1"; echo "        got : $2"; echo "        want: $3";
    fail=$((fail+1)); fi
}

[ -x "$DART" ] || die "no host dart at $DART"
[ -f "$CLI_PKGS" ] || die "no package config at $CLI_PKGS (run dart pub get)"
mkdir -p "$WORK"

# ---- the cell -------------------------------------------------------------
#
# Staged from the build tree rather than downloaded, and NOT published: the whole
# point of this probe is to decide whether the mint should happen. Same seven
# files and same names publish_route_b_compiler.sh uses, so the CLI's resolver
# sees exactly the shape it sees in production.
if [ ! -f "$CELL_ZIP" ]; then
  note "staging an unpublished cell from $OUT"
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
  # PROVENANCE.txt in the form the resolver requires: a sha256 per file, and the
  # engine revision the cell belongs to. Both are enforced -- the published-side
  # audit showed a snapshot with bytes appended still ran and still advertised
  # its flags, and only the hash caught it. Written here rather than faked so the
  # staged cell passes the same checks a published one does.
  {
    echo "Route B compiler cell (UNPUBLISHED, staged by cli_private_member.sh)"
    echo "engine revision : $ENGINE"
    for f in dartaotruntime dart2bytecode.aot vm_platform.dill \
      route_b_analyze.aot route_b_gen_kernel.aot \
      route_b_gen_dynamic_interface.aot flutter_platform_strong.dill; do
      echo "$f : $(shasum -a 256 "$stage/$f" | cut -d' ' -f1)"
    done
  } > "$stage/PROVENANCE.txt"
  (cd "$stage" && zip -q -r "$CELL_ZIP" .)
  echo "    cell: $CELL_ZIP"
fi
[ -f "$CELL_ZIP" ] || die "no compiler cell at $CELL_ZIP"

# ---- the app --------------------------------------------------------------
#
# `_secret` is a private FIELD, so the manifest keys it BARE -- library_index
# applies get:/set: only to a Procedure. Getting that wrong is a silent miss, so
# the probe asserts the key the analyzer reports rather than assuming it.
stage_app() { # <method body source> <dir>
  local body="$1" dir="$2"
  cp "$RB/packaging/container_target.dart" "$dir/lib/container_target.dart"
  BODY="$body" python3 - "$dir/lib/container_target.dart" <<'PY'
import os, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace(
    "void _state(String when) =>",
    """class _Hidden {
  // PRIVATE, and the release never reads it -- so it survives only because the
  // interface named it, which is the condition under test.
  String _secret = 'NEW-PRIV';

  @pragma('vm:never-inline')
  %s
}

void _state(String when) =>""" % os.environ['BODY'],
    1,
)
s = s.replace(
    "print('$when alpha=${alpha()} beta=${beta()}');",
    "print('$when alpha=${alpha()} beta=${beta()} "
    "hidden=${_Hidden().value()}');",
    1,
)
p.write_text(s)
PY
}

package_config() { # <dir>
  cat > "$1/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "dynamic_modules", "rootUri": "file://$1/", "packageUri": "lib/",
    "languageVersion": "3.9" },
  { "name": "crypto", "rootUri": "file://$PKGS_DIR/crypto", "packageUri": "lib/",
    "languageVersion": "3.4" },
  { "name": "typed_data", "rootUri": "file://$PKGS_DIR/typed_data",
    "packageUri": "lib/", "languageVersion": "3.4" } ] }
JSON
}

URI=package:dynamic_modules/container_target.dart
SDK_MEMBERS='dart:core#print,dart:core#DateTime.now,dart:core#DateTime.get:millisecondsSinceEpoch'
MEMBER_KEY="$URI#_Hidden#_secret"
CLASS_KEY="$URI#_Hidden"

# ---- one release, built once ----------------------------------------------
#
# The three arms differ ONLY in the manifest handed to the CLI, never in the
# release. That is deliberate and it is what makes the controls controls: a
# refusal cannot be blamed on a differently-retained release, because it is the
# same release bytes in all three.
note "release under --policy p2 (one release, three manifests)"
dir=$WORK/release; mkdir -p "$dir/lib" "$dir/.dart_tool"
package_config "$dir"
(
  cd "$dir"
  stage_app "String value() =>
      DateTime.now().millisecondsSinceEpoch >= 0 ? 'OLD-priv' : 'X';" "$dir"

  "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
    --packages .dart_tool/package_config.json -o prepass.dill "$URI" >/dev/null
  # The non-AOT kernel supplies the PRIVATE half: the prepass is tree-shaken, so
  # `_secret` -- which the release never reads -- is gone from it before the
  # generator could name it.
  "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --no-aot \
    --no-link-platform --packages .dart_tool/package_config.json \
    -o import.dill "$URI" >/dev/null
  # shellcheck disable=SC2086
  "$DART" $KERNEL_PKGS "$RB/gen_dynamic_interface.dart" --dill prepass.dill \
    --private-dill import.dill --policy p2 --out di.yaml \
    --manifest manifest.json --sdk-members "$SDK_MEMBERS" 2>&1 \
    | sed -n 's/^/    /p'

  "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
    --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
    -o base.dill "$URI" >/dev/null
  "$GEN_SNAPSHOT" --patchable_static_calls --snapshot_kind=app-aot-elf \
    --elf=app.aot base.dill

  # PATCH: reads the private field through the receiver. Nobody writes `self`;
  # the lowering introduces both the parameter and the prefix.
  stage_app "String value() => _secret;" "$dir"
  "$DART" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" --aot \
    --packages .dart_tool/package_config.json --dynamic-interface di.yaml \
    -o patched.dill "$URI" >/dev/null
)

# THE MANIFEST'S OWN PRECONDITIONS, asserted rather than assumed. If the release
# did not actually grant both, the `granted` arm would pass or fail for reasons
# that have nothing to do with the gate.
granted_member=$(python3 -c "
import json,sys
m=json.load(open('$dir/manifest.json'))
print('yes' if '$MEMBER_KEY' in m['privateInstanceCallable'] else 'no')")
granted_class=$(python3 -c "
import json,sys
m=json.load(open('$dir/manifest.json'))
print('yes' if '$CLASS_KEY' in m['privateClassesConstructible'] else 'no')")
echo "    manifest grants _secret: $granted_member    _Hidden: $granted_class"
check "the release granted the private member" "$granted_member" 'yes'
check "the release granted its enclosing class" "$granted_class" 'yes'

buildId=$("$AOT_RUNTIME" "$dir/app.aot" | sed -n 's/^BUILD_ID //p')
[ -n "$buildId" ] || die "no release build id"
echo "    release: $buildId"

# ---- arms -----------------------------------------------------------------
#
# `arm <label> <manifest path or empty> <want value|REFUSED>`
arm() {
  local label="$1" manifest="$2" want="$3"
  local armDir="$dir/$label"; mkdir -p "$armDir"
  note "$label"

  set +e
  "$DART" --packages="$CLI_PKGS" "$HERE/cli_lower.dart" \
    "$CELL_ZIP" "$dir/base.dill" "$dir/patched.dill" "$dir/import.dill" \
    "$buildId" "$armDir/cli" "$dir" "$OUT/vm_platform.dill" "$ENGINE" \
    "$manifest" 2>&1 | tee "$armDir/cli.log" | sed 's/^/    /'
  set -e

  if [ "$want" = REFUSED ]; then
    local reason='<the CLI did not refuse>'
    if grep -q '^REFUSED' "$armDir/cli.log"; then
      reason=$(sed -n 's/^ *REFUSED  *: //p' "$armDir/cli.log" | head -1)
      reason=${reason:+refused}
    fi
    check "$label: the CLI refuses, in the CLI" "$reason" 'refused'
    # WHICH reason, because the two controls must fail differently. A shared
    # message would send the reader to the wrong fix.
    local names_cause=no
    if [ -z "$manifest" ]; then
      grep -q 'published no capability manifest' "$armDir/cli.log" \
        && names_cause=yes
    else
      grep -q 'private enclosing class this release did not retain' \
        "$armDir/cli.log" && names_cause=yes
    fi
    check "$label: the refusal names its own cause" "$names_cause" 'yes'
    return
  fi

  # The lowering is a producer decision and knows nothing about retention, so
  # asserting it here is what proves a control's failure is the GATE and not a
  # lowering regression.
  local got='<the producer wrote no replacement source>'
  if [ -f "$armDir/cli/replacement_0.dart" ]; then
    got=$(grep -m1 'String value' "$armDir/cli/replacement_0.dart" \
      | sed 's/^[[:space:]]*//' || true)
  fi
  check "$label: private class lowered to a dynamic receiver" \
    "$got" 'String value(dynamic self) => self._secret;'

  # AND THE CFE WAS ACTUALLY ASKED. Asserted from the printed argument list, not
  # inferred from the value below: `self._secret` on a dynamic receiver compiles
  # either way, and without the flag it binds to nothing at run time. Two
  # separate claims, so two separate checks.
  local asked=no
  grep -q -- '--resolve-private-names-in-library' "$armDir/cli.log" && asked=yes
  check "$label: the producer asked the CFE to resolve private names" \
    "$asked" 'yes'
  local named=no
  grep -q -- "--resolve-private-names-in-library $URI" "$armDir/cli.log" \
    && named=yes
  check "$label: and named the TARGET's library, not the replacement's" \
    "$named" 'yes'

  local container
  container=$(sed -n 's/^ *OUT=//p' "$armDir/cli.log")
  local value='<no value; the process did not get that far>'
  if [ -n "$container" ] && [ -f "$container" ]; then
    set +e
    (cd "$armDir" && "$AOT_RUNTIME" "$dir/app.aot" "$container" \
      > run.log 2>&1)
    set -e
    grep -q '^APPLY' "$armDir/run.log" \
      && echo "    $(grep -m1 '^APPLY' "$armDir/run.log")"
    value=$(sed -n 's/^after .*hidden=\([^ ]*\).*/\1/p' "$armDir/run.log" \
      | tail -1)
    value=${value:-'<no value; the process did not get that far>'}
  fi
  echo "    hidden = $value"
  check "$label: the app reads the patched value" "$value" "$want"
}

# The narrowed manifest: same release, same member grant, class removed. This is
# P3's shape, and the arm exists because the grant is REAL -- the replacement
# would compile against it -- while being operationally inert.
python3 - "$dir/manifest.json" "$dir/no_class.json" <<'PY'
import json, sys, pathlib
m = json.loads(pathlib.Path(sys.argv[1]).read_text())
m['privateClassesConstructible'] = []
m['implicitlyConstructible'] = []
pathlib.Path(sys.argv[2]).write_text(json.dumps(m, indent=2) + '\n')
PY

arm granted        "$dir/manifest.json" 'NEW-PRIV'
arm class_withheld "$dir/no_class.json" REFUSED
arm no_manifest    ''                   REFUSED

echo
echo "--------------------------------------------------"
echo "cli_private_member: $pass passed, $fail failed"
echo "work dir kept: $WORK"
[ "$fail" -eq 0 ] || exit 1
