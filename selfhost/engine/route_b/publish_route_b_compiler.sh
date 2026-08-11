#!/usr/bin/env bash
# cspell:words dartaotruntime SBRBPTCH killgate dynmod
#
# publish_route_b_compiler.sh -- Route B producer step 1, distribution half.
#
# Publishes the Route B bytecode compiler under an ENGINE HASH, so a patch is
# always compiled by the toolchain that built the release it patches.
#
#   URL  {storageBaseUrl}/{bucket}/shorebird/{engineRevision}/route-b-compiler-<plat>.zip
#
# ONE ARTIFACT, FOUR FILES. `dartaotruntime` and `dart2bytecode_aot.snapshot` are
# a version-locked pair: the runtime refuses a snapshot it did not match ("Wrong
# full snapshot version"), and worse, a MISmatched-but-accepted pair would
# produce bytecode that fails to bind at load time — on device, long after the
# CLI reported success. So they ship in ONE zip and are never published,
# resolved or substituted independently. Anything that lets a caller fetch one
# without the other re-opens the mixed-provenance failure class this exists to
# close.
#
# The platform dill travels with them for the same reason: bytecode compiled
# against a different platform does not bind, and that failure surfaces on
# device rather than here.
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
OVERLAY=${OVERLAY:-/Users/mendell/shorebird/selfhost/cdn/overlay}
BUCKET=${BUCKET:-download.shorebird.dev}
REV=""
PLAT=${PLAT:-darwin-arm64}

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rev) REV="${2:?}"; shift 2 ;;
    --overlay) OVERLAY="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    --plat) PLAT="${2:?}"; shift 2 ;;
    -h|--help) sed -n '3,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$REV" ]] || die "--rev <engineRevision> is required"

SNAPSHOT="$OUT/zip_archives/dart2bytecode_aot.snapshot"
RUNTIME="$OUT/dartaotruntime"
PLATFORM="$OUT/vm_platform.dill"
# The coverage analyzer travels with the compiler for the same reason the
# platform dill does: it READS the release's kernel, and the kernel binary
# format is versioned. An analyzer from another lineage would refuse the dill,
# or worse, misread it.
ANALYZER="$OUT/zip_archives/route_b_analyze.aot"

[[ -f "$SNAPSHOT" ]] || die "no snapshot at $SNAPSHOT — run build_dart2bytecode.sh first"
[[ -x "$RUNTIME" ]]  || die "no dartaotruntime at $RUNTIME"
[[ -f "$PLATFORM" ]] || die "no vm_platform.dill at $PLATFORM"
[[ -f "$ANALYZER" ]] || die "no analyzer at $ANALYZER — run build_route_b_analyzer.sh first"

# The pair must come from ONE out dir. Publishing a runtime from one tree beside
# a snapshot from another is precisely the mixed-provenance shape that has cost
# this project the most time, and it is invisible until a device fails.
grep -q 'dart_dynamic_modules = true' "$OUT/args.gn" 2>/dev/null \
  || die "$OUT is not a dart_dynamic_modules build — wrong tree for Route B"

note "capability probe BEFORE publishing"
# Prove the pair works together, here, rather than discovering it after
# download. Build-time verification proves what we published; the CLI runs the
# same probe after download to prove what it received.
usage=$("$RUNTIME" "$SNAPSHOT" --help 2>&1 || true)
grep -q 'Compiles Dart sources to Dart bytecode' <<<"$usage" \
  || die "the runtime/snapshot pair does not run as dart2bytecode"
grep -q 'flutter' <<<"$usage" \
  || die "the pair does not advertise --target flutter"
echo "    pair runs and advertises --target flutter"
analyzer_usage=$("$RUNTIME" "$ANALYZER" --help 2>&1 || true)
grep -q 'Route B coverage analyzer' <<<"$analyzer_usage" \
  || die "the analyzer does not identify itself as the Route B coverage analyzer"
echo "    analyzer runs and identifies itself"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp "$SNAPSHOT" "$STAGE/dart2bytecode.aot"
cp "$RUNTIME"  "$STAGE/dartaotruntime"
cp "$PLATFORM" "$STAGE/vm_platform.dill"
cp "$ANALYZER" "$STAGE/route_b_analyze.aot"
chmod +x "$STAGE/dartaotruntime"

DART_REV=$(git -C "$SRC/flutter/third_party/dart" rev-parse HEAD 2>/dev/null || echo unknown)
# Hashes of the files AS PUBLISHED, so the audit compares like with like.
cat > "$STAGE/PROVENANCE.txt" <<EOF
Route B producer tooling — one logical artifact, four files.
Never substitute any of them independently.

engine revision  : $REV
built            : $(date -u +%FT%TZ)
host out         : $OUT
dart revision    : $DART_REV
platform         : $PLAT

dart2bytecode.aot : $(shasum -a 256 "$STAGE/dart2bytecode.aot" | cut -d' ' -f1)
dartaotruntime    : $(shasum -a 256 "$STAGE/dartaotruntime" | cut -d' ' -f1)
vm_platform.dill  : $(shasum -a 256 "$STAGE/vm_platform.dill" | cut -d' ' -f1)
route_b_analyze.aot : $(shasum -a 256 "$STAGE/route_b_analyze.aot" | cut -d' ' -f1)

The runtime and the snapshot are version-locked: a mismatched pair either
refuses to start ("Wrong full snapshot version") or, worse, runs and produces
bytecode that fails to bind at load time -- on device, long after the CLI
reported success.
EOF

DEST="$OVERLAY/$BUCKET/shorebird/$REV"
mkdir -p "$DEST"
ZIP="$DEST/route-b-compiler-$PLAT.zip"
( cd "$STAGE" && zip -q -r -y "$ZIP" . )

note "published"
ls -lh "$ZIP" | awk '{print "    " $9 "  " $5}'
echo
sed 's/^/    /' "$STAGE/PROVENANCE.txt"
echo
echo "NEXT: selfhost/engine/route_b/audit_route_b_compiler.sh --hash $REV"
