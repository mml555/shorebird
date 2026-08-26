#!/usr/bin/env bash
# cspell:words dynmod prebuilt xcframework PATCHSET patchset
#
# package_ios_mode_artifacts.sh -- package and publish ONE iOS engine mode's
# `artifacts.zip` under a cell hash, with that mode's own provenance assertions.
#
# THE HARD RULE THIS ENFORCES:
#
#   A successful build of one mode must not authorize packaging another. Each
#   mode is qualified from ITS OWN output directory, so a stale directory left
#   by an earlier attempt cannot satisfy the second half of a two-mode build.
#
# The assertion that actually does that work is `flutter_runtime_mode` read out
# of the mode's own `args.gn`: packaging `profile` against the debug directory
# fails on it, by name, before anything is copied.
#
# WHY THESE ARTIFACTS ARE PUBLISHED AT ALL. `flutter_cache.dart`'s
# `_iosBinaryDirs` requires `ios`, `ios-profile` AND `ios-release` before an iOS
# build proceeds, including a release build. "Debug bytes are not linked into
# the release" is NOT permission to exclude them: they are toolchain state the
# consumer requires to perform the workflow from an empty cache, and borrowing
# them from another engine's hash is the defect `sky_engine.zip` exposed.
#
# Follows publish_ios_overlay.sh's shape deliberately -- same staging, same
# symlink-aware content comparison -- with two differences: the hash is GIVEN
# rather than derived from the Flutter binary, and the archive is normalised so
# a re-package is byte-identical (the cell address covers its digest).
#
#   package_ios_mode_artifacts.sh --mode debug|profile --hash <cellHash>
#                                 [--out <engine out dir>] [--dry-run]
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SELFHOST="$(cd "$HERE/../.." >/dev/null 2>&1 && pwd)"
OVERLAY=${OVERLAY:-$SELFHOST/cdn/overlay}
REFERENCE=${REFERENCE:-$SRC/out/ios_release}
STAMP=${STAMP:-202001010000}
MODE=""; HASH=""; OUTDIR=""; DRY=0; STAGE_TO=""

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo; echo "==> $*"; }

usage() { sed -n '3,28p' "${BASH_SOURCE[0]}"; exit 2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:?}"; shift 2 ;;
    --hash) HASH="${2:?}"; shift 2 ;;
    --out) OUTDIR="${2:?}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    # Write the qualified archive to a path WITHOUT publishing. The cell address
    # is a function of these digests, so the mint needs the bytes before the
    # hash they will be filed under exists.
    --stage-to) STAGE_TO="${2:?}"; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$MODE" ]] || usage
[[ -n "$HASH" || -n "$STAGE_TO" ]] || usage
case "$MODE" in
  debug)   DEST_DIR=ios ;;
  profile) DEST_DIR=ios-profile ;;
  *) die "mode must be debug or profile (release is publish_ios_overlay.sh's job)" ;;
esac
OUTDIR=${OUTDIR:-$SRC/out/ios_$MODE}

arg() { sed -n "s/^$1 = //p" "$2" | tr -d '"'; }

# ---- PER-MODE QUALIFICATION, before anything is copied ----------------------
note "qualifying out/ios_$MODE on its own terms"
[[ -d "$OUTDIR" ]] || die "no output directory at $OUTDIR"
A="$OUTDIR/args.gn"
[[ -f "$A" ]] || die "no args.gn in $OUTDIR — it was never configured"

# 1. THE ANTI-STALE ASSERTION. This is the one that makes a debug directory
#    unable to stand in for profile, and it fails by name rather than by
#    producing a plausible archive.
got_mode=$(arg flutter_runtime_mode "$A")
[[ "$got_mode" == "$MODE" ]] \
  || die "$OUTDIR was configured for flutter_runtime_mode=$got_mode, not $MODE"

# 2. SAME PINNED TREE as the release. Three separate revisions, because an
#    engine built from a different Dart or Skia is a different toolchain even
#    when the Flutter revision matches.
if [[ -f "$REFERENCE/args.gn" ]]; then
  for k in engine_version dart_version skia_version; do
    want=$(arg "$k" "$REFERENCE/args.gn"); got=$(arg "$k" "$A")
    [[ "$want" == "$got" ]] \
      || die "$k differs from the release build: release=$want $MODE=$got"
    echo "    $k matches the release: ${got:0:16}"
  done
else
  echo "    (no reference release args.gn; tree comparison skipped)"
fi

# 3. THE ROUTE B FLAGS. Both, because they are the pair build_ios.sh records as
#    the trap: vanilla Dart's interpreter ON, Shorebird's private one OFF.
[[ "$(arg dart_dynamic_modules "$A")" == "true" ]] \
  || die "$MODE was not built with dart_dynamic_modules=true"
[[ "$(arg shorebird_use_interpreter "$A")" == "false" ]] \
  || die "$MODE was not built with shorebird_use_interpreter=false"
echo "    dart_dynamic_modules=true, shorebird_use_interpreter=false"

# 4. THE OUTPUTS THIS MODE MUST HAVE.
FW="$OUTDIR/Flutter.xcframework"
[[ -d "$FW" ]] || FW="$OUTDIR/flutter/xcframework/Flutter.xcframework"
[[ -d "$FW" ]] || die "no Flutter.xcframework under $OUTDIR — the build did not finish"
BIN="$FW/ios-arm64/Flutter.framework/Flutter"
[[ -f "$BIN" ]] || die "no device-slice Flutter binary at $BIN"
echo "    Flutter.xcframework present, device slice $(shasum -a 256 "$BIN" | cut -c1-16)"

# 5. FRESHNESS. Built AFTER it was configured, so a directory left from an
#    earlier attempt at a different configuration cannot pass step 1 and then
#    ship stale bytes.
[[ "$BIN" -nt "$A" ]] \
  || die "$BIN is not newer than $A — this looks like a stale build"
echo "    the binary is newer than its own args.gn"

# universal/ is where these actually land, and it is where
# publish_ios_overlay.sh reads them from for the release archive. A first version
# of this script looked in the out root and clang_x64 and found neither -- which
# the qualification gate then correctly refused for profile rather than shipping
# an archive missing its AOT tool. The refusal was right; the path was mine.
GEN="$OUTDIR/universal/gen_snapshot_arm64"
[[ -f "$GEN" ]] || GEN="$OUTDIR/gen_snapshot_arm64"
ANA="$OUTDIR/analyze_snapshot_arm64"
[[ -f "$ANA" ]] || ANA="$OUTDIR/artifacts_x64/analyze_snapshot_arm64"
# Required for BOTH modes: all three iOS builds produce them, and the release
# archive carries them, so an archive that silently omits them is not the same
# artifact set the consumer gets for the other modes.
[[ -f "$GEN" ]] || die "$MODE has no gen_snapshot_arm64 (looked in $OUTDIR/universal and $OUTDIR)"
[[ -f "$ANA" ]] || die "$MODE has no analyze_snapshot_arm64"
echo "    host tools: gen_snapshot $(shasum -a 256 "$GEN" | cut -c1-16), analyze_snapshot $(shasum -a 256 "$ANA" | cut -c1-16)"

# ---- stage and archive ------------------------------------------------------
stage_and_zip() { # <zip-path>
  local zip=$1 stage; stage=$(mktemp -d)
  # -R, not -a: an .xcframework is a symlink web and -a tries to preserve flags
  # cp cannot set here. Same reasoning as publish_ios_overlay.sh.
  cp -R "$FW" "$stage/Flutter.xcframework"
  [[ -f "$GEN" ]] && { cp "$GEN" "$stage/gen_snapshot_arm64"; chmod +x "$stage/gen_snapshot_arm64"; }
  [[ -f "$ANA" ]] && { cp "$ANA" "$stage/analyze_snapshot_arm64"; chmod +x "$stage/analyze_snapshot_arm64"; }
  # NORMALISE so a re-package is byte-identical: the cell address covers this
  # digest, and zip embeds mtimes. -h so symlinks are touched, not their targets.
  find "$stage" -exec touch -h -t "$STAMP" {} + 2>/dev/null || true
  rm -f "$zip"
  ( cd "$stage" && find . \( -type f -o -type l -o -type d \) | sed 's|^\./||' \
      | grep -v '^\.$' | LC_ALL=C sort | zip -q -X -y -o "$zip" -@ )
  rm -rf "$stage"
}

note "packaging twice, and requiring the two to be byte-identical"
T1=$(mktemp -d)/a.zip; T2=$(mktemp -d)/b.zip
stage_and_zip "$T1"
stage_and_zip "$T2"
D1=$(shasum -a 256 "$T1" | cut -d' ' -f1)
D2=$(shasum -a 256 "$T2" | cut -d' ' -f1)
if [[ "$D1" != "$D2" ]]; then
  die "packaging is NOT deterministic ($D1 vs $D2); the cell address would depend on the clock"
fi
echo "    REPRODUCIBLE  ${D1:0:32}"
echo "    $(wc -c < "$T1" | tr -d ' ') bytes"

if [[ -n "$STAGE_TO" ]]; then
  mkdir -p "$(dirname "$STAGE_TO")"
  cp "$T1" "$STAGE_TO"
  note "staged (not published) $STAGE_TO"
  echo "    $D1"
  exit 0
fi

DEST="$OVERLAY/flutter_infra_release/flutter/$HASH/$DEST_DIR"
if [[ "$DRY" == 1 ]]; then
  note "(dry run) would publish to $DEST/artifacts.zip"
  echo "$D1"; exit 0
fi

# FAIL-CLOSED against overwriting a live hash with different contents, the same
# guard publish_ios_overlay.sh carries and for the same reason.
if [[ -f "$DEST/artifacts.zip" ]]; then
  existing=$(shasum -a 256 "$DEST/artifacts.zip" | cut -d' ' -f1)
  if [[ "$existing" == "$D1" ]]; then
    note "identical archive already published for $HASH/$DEST_DIR — nothing to do"
    exit 0
  fi
  die "$DEST/artifacts.zip exists with DIFFERENT contents ($existing). A published
hash must not change meaning; mint a successor instead."
fi

mkdir -p "$DEST"
cp "$T1" "$DEST/artifacts.zip"
REV=$(git -C "$SRC/flutter" rev-parse HEAD 2>/dev/null || echo unknown)
PATCHSET=$(cat "$HERE"/*.patch 2>/dev/null | shasum -a 256 | cut -c1-16)
cat > "$DEST/artifacts.zip.provenance" <<EOF
Route B iOS $MODE engine artifacts
built        : $(date -u +%FT%TZ)
mode         : $MODE (flutter_runtime_mode=$got_mode)
out dir      : $OUTDIR
engine rev   : $REV
engine_version: $(arg engine_version "$A")
dart_version : $(arg dart_version "$A")
skia_version : $(arg skia_version "$A")
route b patchset: $PATCHSET (sha256 over engine/route_b/*.patch, first 16)
flags        : dart_dynamic_modules=true shorebird_use_interpreter=false
archive      : $D1
determinism  : fixed mtime $STAMP, sorted entries, zip -X -y. Verified by
               packaging twice and comparing bytes.
why published: flutter_cache.dart's _iosBinaryDirs requires ios, ios-profile and
               ios-release before an iOS build proceeds, INCLUDING a release
               build. Borrowing them from another engine's hash was refused.
EOF
note "published $DEST/artifacts.zip"
shasum -a 256 "$DEST/artifacts.zip" | sed 's/^/    /'
