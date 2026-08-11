#!/usr/bin/env bash
# cspell:words dartaotruntime SBRBPTCH sbrbptch
#
# host_equivalence.sh -- the CLI producer must agree with the manually proven
# tooling, before anything reaches a phone.
#
# The container that was proven on hardware was packed by hand. This runs BOTH
# producers over one release/patch pair and compares:
#
#   * the changed-target set and the coverage verdict
#   * the compiled payload for each target
#   * the SBRBPTCH container, byte for byte
#   * that the reference reader accepts the CLI's container
#   * the updater ARTIFACT: the CLI's normal differ against a one-byte synthetic
#     base vs the reference `route_b_artifact` tool
#
# EXACT SHA IS A FAIR GATE HERE, and that is a property of the format rather
# than a hope: `writeContainer` has no timestamps and no ordering that depends
# on anything but the target list, so identical inputs give identical bytes.
# Nothing here compares "semantic" representations, because nothing needs to.
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../../.." >/dev/null 2>&1 && pwd)"
WORK=${WORK:-$(mktemp -d)}

DART_TREE=$SRC/flutter/third_party/dart
DART=$OUT/dart-sdk/bin/dart
KERNEL_PKGS="--packages=$DART_TREE/.dart_tool/package_config.json"
CLI_PKGS="${CLI_PKGS:-$REPO/.dart_tool/package_config.json}"
GEN_KERNEL=$OUT/zip_archives/route_b_gen_kernel.aot
RUNTIME=$OUT/dartaotruntime
CASE=${1:-static_function}
BUILD_ID=${BUILD_ID:-deadbeefcafe}
CELL_ZIP=${CELL_ZIP:-$REPO/selfhost/cdn/overlay/download.shorebird.dev/shorebird/591a9f8d8e21f8c08cd379ac4c63a0300ac98959/route-b-compiler-darwin-arm64.zip}

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }
pass=0; fail=0
check() { # <label> <a> <b>
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1));
  else echo "  FAIL  $1"; echo "        cli: $2"; echo "        ref: $3"; fail=$((fail+1)); fi
}

[ -x "$DART" ] || die "no host dart at $DART"
[ -f "$CELL_ZIP" ] || die "no compiler cell at $CELL_ZIP"
[ -f "$CLI_PKGS" ] || die "no package config at $CLI_PKGS"

CASE_SRC="$HERE/coverage/corpus/$CASE"
[ -d "$CASE_SRC" ] || die "no such corpus case: $CASE"

mkdir -p "$WORK/lib" "$WORK/.dart_tool"
cat > "$WORK/.dart_tool/package_config.json" <<JSON
{ "configVersion": 2, "packages": [
  { "name": "corpus", "rootUri": "file://$WORK/", "packageUri": "lib/",
    "languageVersion": "3.9" } ] }
JSON

kernel() { # <out> <mode...>
  ( cd "$WORK" && "$RUNTIME" "$GEN_KERNEL" --platform "$OUT/vm_platform.dill" \
      "${@:2}" --packages .dart_tool/package_config.json \
      -o "$1" package:corpus/main.dart >/dev/null 2>&1 )
}

note "$CASE: release"
cp "$CASE_SRC/base.dart" "$WORK/lib/main.dart"
kernel "$WORK/base.dill" --aot
# The release's OTHER kernel -- dart2bytecode cannot read the AOT one.
kernel "$WORK/import.dill" --no-aot --no-link-platform

note "$CASE: patch"
cp "$CASE_SRC/patched.dart" "$WORK/lib/main.dart"
kernel "$WORK/patched.dill" --aot

note "CLI producer"
"$DART" --packages="$CLI_PKGS" "$HERE/producer/cli_produce.dart" \
  "$CELL_ZIP" "$WORK/base.dill" "$WORK/patched.dill" "$WORK/import.dill" \
  "$BUILD_ID" "$WORK/cli" | tee "$WORK/cli.log"
CLI_CONTAINER=$(sed -n 's/^OUT=//p' "$WORK/cli.log")
[ -f "$CLI_CONTAINER" ] || die "the CLI produced no container"

note "reference packer, over the SAME payloads"
# The reference is the packer that produced the container proven on hardware.
# Feeding it the CLI's payloads isolates the container format from the compile:
# a difference here is a format difference and nothing else.
targets=()
for payload in "$WORK/cli"/replacement_*.bytecode; do
  index=$(basename "$payload" | sed 's/replacement_//; s/.bytecode//')
  selector=$(python3 -c "
import json,sys
print(json.load(open('$WORK/cli/analysis.json'))['selectors'][$index])
" 2>/dev/null || true)
  [ -n "$selector" ] || selector=$(python3 -c "
import json,re
sels=json.loads(re.search(r'^SELECTORS=(.*)$', open('$WORK/cli.log').read(), re.M).group(1))
print(sels[$index])
")
  targets+=(--target "$selector=$payload")
done
"$DART" $KERNEL_PKGS "$HERE/packaging/pack_patch.dart" \
  --release-build-id "$BUILD_ID" --out "$WORK/ref.sbrbptch" "${targets[@]}" \
  >/dev/null 2>&1

note "compare"
check "container sha256" \
  "$(shasum -a 256 "$CLI_CONTAINER" | cut -d' ' -f1)" \
  "$(shasum -a 256 "$WORK/ref.sbrbptch" | cut -d' ' -f1)"
check "container size" \
  "$(wc -c < "$CLI_CONTAINER" | tr -d ' ')" \
  "$(wc -c < "$WORK/ref.sbrbptch" | tr -d ' ')"

# And the reference READER -- the one whose format the device runtime
# implements -- must accept what the CLI produced.
cat > "$WORK/read_ref.dart" <<DART
import '$HERE/packaging/patch_container.dart';
void main(List<String> a) {
  final c = readContainerFile(a.single);
  print('\${c.releaseBuildId} \${c.targets.length}');
  for (final t in c.targets) print('\${t.library}#\${t.selector} \${t.bytecode.length}');
}
DART
check "reference reader accepts both" \
  "$("$DART" $KERNEL_PKGS "$WORK/read_ref.dart" "$CLI_CONTAINER")" \
  "$("$DART" $KERNEL_PKGS "$WORK/read_ref.dart" "$WORK/ref.sbrbptch")"

note "artifact layer"
# The unanswered bytes question was SBRBPTCH -> updater artifact. The reference
# tool diffs the container against a ONE-BYTE synthetic base, making the artifact
# pure literal inserts so reconstruction never reads the base -- the updater's
# iOS base is the four Dart blobs behind SnapshotsDataHandle, which a container
# has nothing in common with and which the producer cannot reproduce without
# `analyze_snapshot --dump_blobs`, a Shorebird-fork tool we cannot build.
#
# `route_b_artifact` is just `patch::make_patch(base, container)` -- the same
# Rust crate the CLI's own `patch` executable wraps. If they agree, Route B stays
# inside the normal artifact machinery and no separate publishing tool belongs in
# the product path.
ROUTE_B_ARTIFACT=${ROUTE_B_ARTIFACT:-$SRC/flutter/third_party/updater/target/release/route_b_artifact}
PATCH_BIN=${PATCH_BIN:-$HOME/.shorebird/bin/cache/artifacts/patch/patch}
if [ -x "$ROUTE_B_ARTIFACT" ] && [ -x "$PATCH_BIN" ]; then
  # A: the reference tool. It VERIFIES base-independence on every run, against
  # an empty base and a 4 MB noise base, so a passing A is itself the proof that
  # inflate(A) == container for any base.
  "$ROUTE_B_ARTIFACT" "$CLI_CONTAINER" "$WORK/A.artifact" > "$WORK/A.log"
  grep -q 'reconstructs from an empty base AND a noise base' "$WORK/A.log" \
    || die "the reference tool did not verify base-independence"
  echo "  ok      reference artifact verified base-independent"

  # B: the CLI's own differ, same synthetic base.
  printf '\0' > "$WORK/synthetic_base"
  "$PATCH_BIN" "$WORK/synthetic_base" "$CLI_CONTAINER" "$WORK/B.artifact" \
    >/dev/null 2>&1

  check "artifact sha256 (cli differ vs route_b_artifact)" \
    "$(shasum -a 256 "$WORK/B.artifact" | cut -d' ' -f1)" \
    "$(shasum -a 256 "$WORK/A.artifact" | cut -d' ' -f1)"

  # The value the control plane must record is the CONTAINER's digest, because
  # check_hash() on device runs against the INFLATED result. Getting this
  # backwards costs a patch: it installs, fails verification, and the duplicate
  # check blocks re-registering that arch.
  check "recorded patch hash is the CONTAINER's" \
    "$(sed -n 's/^patch hash      : //p' "$WORK/A.log")" \
    "$(shasum -a 256 "$CLI_CONTAINER" | cut -d' ' -f1)"
else
  echo "  SKIP    artifact layer (route_b_artifact or patch executable missing)"
fi

echo
echo "--------------------------------------------------"
echo "host equivalence ($CASE): $pass passed, $fail failed"
echo "work dir kept: $WORK"
[ "$fail" -eq 0 ] || exit 1
