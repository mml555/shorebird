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

# Derive the engine hash from the engine binary itself.
#
# NOTE WHAT THIS HASH IS AND IS NOT. It is sha1 of the DEVICE-SLICE FLUTTER
# BINARY, so it is a function of the ENGINE — not of the artifact set. The zip
# also ships gen_snapshot_arm64 and analyze_snapshot_arm64, and a change to
# either leaves this hash unchanged. The collision guard further down is what
# stops that from silently overwriting a live hash; do not remove it on the
# strength of the sentence above.
#
# Re-running for an unchanged artifact set IS idempotent, but only because that
# guard compares CONTENTS and leaves the published zip in place. `zip` embeds
# mtimes, so a re-zip is never byte-identical — before the guard existed, every
# re-run silently replaced the published bytes, which would break the
# ios_artifacts_sha256 equality audit_route_b_compiler.sh enforces.
BIN="$FW/ios-arm64/Flutter.framework/Flutter"
[[ -f "$BIN" ]] || die "no device-slice binary at $BIN"
HASH=${HASH:-$(shasum -a 1 "$BIN" | cut -c1-40)}
note "engine hash: $HASH"
note "  from: $BIN ($(lipo -archs "$BIN"))"

DEST="$OVERLAY/flutter_infra_release/flutter/$HASH/ios-release"
mkdir -p "$DEST"

STAGE=$(mktemp -d)
# "$STAGE.zip" too: the collision guard below can exit non-zero with the staged
# zip still on disk, and a refusal must not leave litter behind.
trap 'rm -rf "$STAGE" "$STAGE.zip"' EXIT

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
#
# Zipped to a TEMP path, never straight to $DEST — see the collision guard below.
( cd "$STAGE" && zip -q -r -y "$STAGE.zip" . )

# ---------------------------------------------------------------------------
# FAIL-CLOSED COLLISION GUARD.
#
# HASH above is sha1 of the DEVICE-SLICE FLUTTER BINARY ALONE. It is therefore
# NOT a function of the whole artifact set: a change that moves gen_snapshot but
# leaves Flutter.framework untouched derives the hash that is ALREADY PUBLISHED.
# Writing straight to $DEST then overwrites a live hash with different contents,
# and that is worse than a clobber:
#   * the hash stops being a function of what is in it;
#   * any checkout that already cached it keeps the OLD tools forever, because
#     the cache keys on the hash and nothing refetches;
#   * a cell minted from that hash records an ios_artifacts_sha256 that no longer
#     matches what is served, which audit_route_b_compiler.sh checks.
# Measured 2026-08-13: patch 0008 (--load-obfuscation-map) changed gen_snapshot
# only, derived 11e5695710275f829ef1e4a45636d39454ca1769 — already serving a zip
# whose gen_snapshot lacked the flag.
#
# CONTENTS, NOT CONTAINER BYTES. `zip` embeds mtimes, so a re-zip of an identical
# tree is never byte-identical (mint_route_b_cell.sh relies on this being true).
# Comparing zip digests would therefore fire on every legitimate idempotent
# re-run. The comparison is over per-member digests, with symlinks compared by
# target because an .xcframework is a symlink web.
content_manifest() { # <dir> -> "<path> <sha256|symlink target>" lines, sorted
  ( cd "$1" && find . \( -type f -o -type l \) | LC_ALL=C sort |
    while IFS= read -r f; do
      if [[ -L "$f" ]]; then printf '%s symlink:%s\n' "$f" "$(readlink "$f")"
      else printf '%s %s\n' "$f" "$(shasum -a 256 "$f" | cut -d' ' -f1)"; fi
    done )
}

if [[ -f "$DEST/artifacts.zip" ]]; then
  note "a zip already exists for $HASH — comparing CONTENTS before touching it"
  PRIOR=$(mktemp -d)
  unzip -q -o "$DEST/artifacts.zip" -d "$PRIOR"
  if diff -q <(content_manifest "$PRIOR") <(content_manifest "$STAGE") >/dev/null; then
    rm -rf "$PRIOR"
    note "identical contents — leaving the published zip untouched"
    echo "    (its digest may already participate in a minted cell address;"
    echo "     re-zipping would change those bytes for no reason)"
    ls -lh "$DEST/artifacts.zip" | awk '{print "    artifacts.zip: " $5 " (unchanged)"}'
  else
    echo >&2
    echo "REFUSING TO OVERWRITE A PUBLISHED ENGINE HASH." >&2
    echo "  hash : $HASH" >&2
    echo "  dest : $DEST/artifacts.zip" >&2
    echo >&2
    echo "The derived hash is already published with DIFFERENT contents. The hash" >&2
    echo "comes from Flutter.framework alone, so a gen_snapshot-only change lands" >&2
    echo "here. Differing members:" >&2
    # `|| true` is load-bearing: diff exits 1 when there ARE differences, and
    # under `set -e -o pipefail` that would abort the script here — truncating
    # this very message and making the FORCE check below unreachable.
    { diff <(content_manifest "$PRIOR") <(content_manifest "$STAGE") || true; } |
      grep -E '^[<>]' | head -12 | sed 's/^/    /' >&2 || true
    echo >&2
    echo "WHAT TO DO INSTEAD — this is the path cell 40eaa0ef used:" >&2
    echo "  1. re-run with OVERLAY=<scratch dir> to build the zip without" >&2
    echo "     touching the real overlay;" >&2
    echo "  2. pass that zip to mint_route_b_cell.sh --ios-artifacts, which" >&2
    echo "     clones the donor to a NEW address and overwrites only that copy." >&2
    echo "     The donor is never modified." >&2
    echo >&2
    echo "Set FORCE=1 only if you can show no consumer ever fetched this hash." >&2
    rm -rf "$PRIOR"
    [[ "${FORCE:-0}" == "1" ]] || exit 1
    echo "FORCE=1 set — overwriting anyway." >&2
    mv "$STAGE.zip" "$DEST/artifacts.zip"
    ls -lh "$DEST/artifacts.zip" | awk '{print "    artifacts.zip: " $5 " (FORCED)"}'
  fi
else
  mv "$STAGE.zip" "$DEST/artifacts.zip"
  ls -lh "$DEST/artifacts.zip" | awk '{print "    artifacts.zip: " $5}'
fi
rm -f "$STAGE.zip"

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
# Route B: the compiler cell is engine-scoped, so a rebuilt engine has none
# until it is republished. Patching would then fail with "tooling unavailable"
# for a release that is otherwise perfectly patchable — a confusing place to
# learn this, so it is part of publishing rather than a checklist elsewhere.
if nm -a "$BIN" 2>/dev/null | grep -qi interpretcall; then
  echo "  4) THIS IS A ROUTE B ENGINE — republish the compiler cell and audit it:"
  echo "       selfhost/engine/route_b/build_dart2bytecode.sh"
  echo "       selfhost/engine/route_b/publish_route_b_compiler.sh --rev $HASH"
  echo "       selfhost/engine/route_b/audit_route_b_compiler.sh --hash $HASH"
  echo "     Patches for releases on $HASH cannot be produced until this passes."
fi
