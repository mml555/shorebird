#!/usr/bin/env bash
# cspell:words dartaotruntime isoformat killgate mendell nodm pathlib utcfromtimestamp
# Publish OUR iOS engine into the CDN overlay so a `shorebird release ios` can be
# built against it instead of Shorebird's prebuilt one.
#
# The iOS artifact set is far smaller than Android's — no Maven modules, no
# per-ABI archives. Everything an app build consumes lives in one zip:
#
#   flutter_infra_release/flutter/<hash>/ios-release/artifacts.zip
#     analyze_snapshot_arm64      universal (x86_64+arm64) host tool
#     gen_snapshot_arm64          universal host tool — must come from OUR tree,
#                                 because the snapshot it emits is version-locked
#                                 to the Flutter.framework that loads it
#     Flutter.xcframework/        the engine itself
#     entitlements.txt, without_entitlements.txt, unsigned_binaries.txt
#
# Plus engine_stamp.json, which Flutter 3.44 fetches before it builds anything and
# whose absence is a fatal 404 (learned on Android).
#
# Two deliberate differences from the stock zip:
#  - Ours carries only the ios-arm64 slice. Stock also ships
#    ios-arm64_x86_64-simulator; we never built a simulator engine, and a device
#    release resolves the ios-arm64 slice only. A simulator build against this
#    hash WILL fail, by design rather than by accident.
#  - Ours is not Apple-code-signed (stock has Flutter.xcframework/_CodeSignature,
#    signed by Google). Xcode re-signs any embedded framework with the app's own
#    identity at build time, so this does not matter for an app build.
set -euo pipefail

OUT=${OUT:-/Volumes/build/ios-engine/flutter/engine/src/out/ios_release}
OVERLAY=${OVERLAY:-/Users/mendell/shorebird/selfhost/cdn/overlay}
STOCK=${STOCK:-69f9831c360d9152862ec3897c67fb09ae843f3b}
# A stock zip is only needed for the three signing-metadata txt files, which we do
# not produce and which no app build reads. Pass STOCK_ZIP= to skip them.
STOCK_ZIP=${STOCK_ZIP:-}

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*"; }

FW="$OUT/Flutter.xcframework"
GEN="$OUT/universal/gen_snapshot_arm64"
ANA="$OUT/analyze_snapshot_arm64"

[[ -d "$FW" ]]  || die "no Flutter.xcframework at $FW — build the engine first"
[[ -f "$GEN" ]] || die "no universal gen_snapshot_arm64 at $GEN"
[[ -f "$ANA" ]] || die "no analyze_snapshot_arm64 at $ANA"

# Both host tools must be universal, like stock: Flutter runs them on whatever Mac
# the release is built on. artifacts_arm64/ holds an arm64-only build that would
# break an Intel host silently.
for f in "$GEN" "$ANA"; do
  archs=$(lipo -archs "$f")
  [[ "$archs" == *x86_64* && "$archs" == *arm64* ]] \
    || die "$(basename "$f") is '$archs', expected universal x86_64+arm64"
done

# Derive the engine hash from the engine binary itself, so the published hash is a
# function of what is actually in it. Any rebuild that changes the engine gets a
# new hash, and re-running this script for an unchanged engine is idempotent.
BIN="$FW/ios-arm64/Flutter.framework/Flutter"
[[ -f "$BIN" ]] || die "no device-slice binary at $BIN"
HASH=${HASH:-$(shasum -a 1 "$BIN" | cut -c1-40)}
note "engine hash: $HASH"
note "  from: $BIN ($(lipo -archs "$BIN"))"

DEST="$OVERLAY/flutter_infra_release/flutter/$HASH/ios-release"
mkdir -p "$DEST"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

note "staging artifact set"
cp "$ANA" "$STAGE/analyze_snapshot_arm64"
cp "$GEN" "$STAGE/gen_snapshot_arm64"
chmod +x "$STAGE/analyze_snapshot_arm64" "$STAGE/gen_snapshot_arm64"
# -R follows nothing but copies the symlink web inside a framework verbatim, which
# is what an .xcframework is; -a would also try to preserve flags cp cannot set here.
cp -R "$FW" "$STAGE/Flutter.xcframework"

if [[ -n "$STOCK_ZIP" && -f "$STOCK_ZIP" ]]; then
  note "taking signing metadata from the stock zip"
  for t in entitlements.txt without_entitlements.txt unsigned_binaries.txt; do
    unzip -o -q -j "$STOCK_ZIP" "$t" -d "$STAGE" 2>/dev/null || true
  done
fi

note "zipping"
# Store entries relative to the set root, the way the stock zip does: flutter_tools
# unpacks it straight into bin/cache/artifacts/engine/ios-release/.
( cd "$STAGE" && zip -q -r -y "$DEST/artifacts.zip" . )
ls -lh "$DEST/artifacts.zip" | awk '{print "    artifacts.zip: " $5}'

# The macOS HOST toolchain. Not optional for a release built through the vended
# Shorebird flutter, and the reason is a chain of version locks:
#   frontend_server_aot (in darwin-arm64/artifacts.zip) is a Dart AOT snapshot run
#   by dartaotruntime (in dart-sdk-darwin-arm64.zip) — mismatch is "Wrong full
#   snapshot version". Its kernel output is then read by OUR gen_snapshot_arm64,
#   against the platform dill in flutter_patched_sdk_product.zip. Mixing trees
#   anywhere along that chain is the Android "Unexpected tag 4 (Field)" failure.
# So all three come from our tree or none of this is ours.
# NOT out/host_release_arm64: that is Track E's killgate rig and carries
# dart_dynamic_modules=true, whose platform dill fails the iOS AOT step with
# "Unexpected tag 4 (Field)". Use a host_release configured like out/ios_release.
HOST_REL=${HOST_REL:-/Volumes/build/ios-engine/flutter/engine/src/out/host_release_arm64_nodm}
HOST_DBG=${HOST_DBG:-/Volumes/build/ios-engine/flutter/engine/src/out/host_debug_arm64}
HASH_DIR="$OVERLAY/flutter_infra_release/flutter/$HASH"

publish_host() {
  local src=$1 rel=$2
  if [[ -f "$src" ]]; then
    mkdir -p "$(dirname "$HASH_DIR/$rel")"
    cp "$src" "$HASH_DIR/$rel"
    echo "    $rel  ($(du -h "$src" | cut -f1))"
  else
    echo "    MISSING $rel  (expected at $src)" >&2
    MISSING_HOST=1
  fi
}

note "publishing macOS host toolchain"
MISSING_HOST=0
publish_host "$HOST_REL/zip_archives/dart-sdk-darwin-arm64.zip"      "dart-sdk-darwin-arm64.zip"
publish_host "$HOST_REL/zip_archives/flutter_patched_sdk_product.zip" "flutter_patched_sdk_product.zip"
publish_host "$HOST_DBG/zip_archives/darwin-arm64/artifacts.zip"      "darwin-arm64/artifacts.zip"
# The non-product platform dill as well. Upstream's copy is byte-DIFFERENT from
# ours at the same size, and mixing it with our compiler yields the opaque
# "Unexpected tag 4 (Field)" from ReadUntilFunctionNode.
publish_host "$HOST_DBG/zip_archives/flutter_patched_sdk.zip"         "flutter_patched_sdk.zip"

# const_finder reads app.dill and checks the SDK hash baked into it, so it is
# version-locked to the frontend the same way dartaotruntime is. Our zip_archives
# rule does not include it (stock's does), so a build would silently keep
# Shorebird's Jun-30 copy and die at the icon-tree-shaker step with
#   IconTreeShakerException: ConstFinder failure: Can't load Kernel binary:
#   Invalid SDK hash.
# Inject ours. `ninja -C out/host_debug_arm64 flutter/tools/const_finder` builds it.
CF="$HOST_DBG/gen/const_finder.dart.snapshot"
if [[ -f "$CF" ]]; then
  ( cd "$(dirname "$CF")" && zip -q "$HASH_DIR/darwin-arm64/artifacts.zip" const_finder.dart.snapshot )
  echo "    darwin-arm64/artifacts.zip += const_finder.dart.snapshot  ($(du -h "$CF" | cut -f1))"
else
  echo "    MISSING const_finder.dart.snapshot (expected at $CF)" >&2
  MISSING_HOST=1
fi

if (( MISSING_HOST )); then
  echo "warning: host toolchain incomplete — a release built against $HASH will" >&2
  echo "         404 on the missing piece rather than silently using stock bytes." >&2
fi

note "writing engine_stamp.json"
python3 - "$HASH" "$OVERLAY" <<'PY'
import json, pathlib, sys, datetime, os
h, overlay = sys.argv[1], sys.argv[2]
d = pathlib.Path(overlay) / 'flutter_infra_release' / 'flutter' / h
d.mkdir(parents=True, exist_ok=True)
zip_path = d / 'ios-release' / 'artifacts.zip'
# Date the stamp from the artifact so it describes this set, not the run.
ts = datetime.datetime.utcfromtimestamp(zip_path.stat().st_mtime)
(d / 'engine_stamp.json').write_text(json.dumps({
    'build_date': ts.isoformat(),
    'build_time_ms': int(ts.timestamp() * 1000),
    'git_revision': h,
    'git_revision_date': ts.isoformat(),
    'content_hash': '',
}))
print('    engine_stamp.json written')
PY

# font-subset.zip carries const_finder.dart.snapshot and extracts into the same
# cache dir as artifacts.zip, so if it is not ours the STOCK const_finder wins
# and every release dies with "Invalid SDK hash". Publish it with the engine so
# it can never become a hand-injected artifact again (see the script header).
FONT_SUBSET="$(dirname "${BASH_SOURCE[0]}")/publish_font_subset.sh"
DART="${DART:-$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart}" \
  bash "$FONT_SUBSET" --overlay "$OVERLAY" --rev "$HASH" \
  && note "font-subset (with our const_finder) published for $HASH" \
  || echo "WARNING: publish_font_subset.sh failed — releases on $HASH will hit the stock const_finder" >&2

# The CLI fetches patch-<plat>.zip from shorebird/<rev>/, and @must_be_local in
# the Caddyfile owns that path for experimental hashes — publish the host's
# differ zip alongside the engine or patch builds against this hash 404.
PATCH_TOOL="$(dirname "${BASH_SOURCE[0]}")/publish_patch_tool.sh"
bash "$PATCH_TOOL" --overlay "$OVERLAY" --rev "$HASH" >/dev/null \
  && note "patch differ published for $HASH" \
  || echo "WARNING: publish_patch_tool.sh failed — patch builds against $HASH will 404" >&2

# Alongside the Android sets, so provenance travels with the artifacts it
# describes (and stays out of git, since the overlay is ignored).
PROV_DIR="$OVERLAY/download.shorebird.dev/shorebird/$HASH"
mkdir -p "$PROV_DIR"
cat >"$PROV_DIR/PROVENANCE.txt" <<EOF
ios_engine_hash:  $HASH
falls_back_to:    $STOCK
built_from:       $OUT
engine_binary:    $BIN
slices:           ios-arm64 only (no simulator — see script header)
interpreter:      shorebird_use_interpreter=false (vanilla Dart; no iOS code patches)
published_at:     $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

note "done. Next:"
echo "  1) add to selfhost/cdn/experimental_hashes.map:"
echo "       $HASH $STOCK;"
echo "  2) docker restart shorebird-cdn-cdn-cache-1   # re-read the bind mount"
echo "  3) point the build's engine.version at $HASH and set"
echo "     FLUTTER_STORAGE_BASE_URL to the mirror"
