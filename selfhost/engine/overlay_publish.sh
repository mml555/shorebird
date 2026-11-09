#!/usr/bin/env bash
#
# overlay_publish.sh — publish a locally built EXPERIMENTAL engine into the CDN
# mirror's overlay, under its own engine hash.
#
# Why an overlay instead of a full artifact set: only a few artifacts actually
# carry an Android arm64 engine change. Everything else in the set (Dart SDK,
# flutter_patched_sdk_product, aot-tools.dill, the patch CLI, iOS/macOS/Windows
# artifacts, other Android ABIs) is identical to the pinned revision — and some
# of it cannot even be produced on Linux (the macOS/Windows host gen_snapshot).
# So we publish what we built and let Caddy serve the rest from the already-warm
# pinned-revision cache, rewriting the hash on the way out.
#
# The mirror is configured so that the artifacts THIS script owns are never
# eligible for that fallback: if a rebuild is missing from the overlay the
# request 404s instead of silently resolving to Shorebird's stock bytes. See
# `@must_be_local` in selfhost/cdn/Caddyfile.
#
# Usage:
#   selfhost/engine/overlay_publish.sh --hash <expHash> [options]
#
#   --hash <sha>       40-hex experimental engine hash. Convention: the git sha
#                      of the engine branch HEAD you built, so the artifact
#                      prefix names its own source.
#   --root <dir>       Flutter checkout that was built. Default: vendor/flutter.
#   --stock <sha>      Hash to fall back to for everything not published here.
#                      Default: the checkout's bin/internal/engine.version.
#   --overlay <dir>    Overlay root. Default: selfhost/cdn/overlay.
#   --bucket <name>    Bucket path segment the CLI uses for shorebird/<rev>/
#                      artifacts. Default: download.shorebird.dev.
#   --host-tag <tag>   Host the release will be BUILT on, for the dart-sdk zip
#                      name: linux-x64 | darwin-arm64 | darwin-x64 | windows-x64.
#                      Default: linux-x64 (we build the engine on Linux).
#   --mirror <url>     Where to fetch pinned-revision Maven modules from.
#                      Default: http://localhost:8085 (the CDN mirror).
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"

EXP_HASH=""
STOCK_HASH=""
FLUTTER_ROOT="$REPO_ROOT/vendor/flutter"
OVERLAY="$REPO_ROOT/selfhost/cdn/overlay"
BUCKET="download.shorebird.dev"
HOST_TAG="linux-x64"
MIRROR_URL="http://localhost:8085"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hash)    EXP_HASH="${2:?}"; shift 2 ;;
    --stock)   STOCK_HASH="${2:?}"; shift 2 ;;
    --root)    FLUTTER_ROOT="${2:?}"; shift 2 ;;
    --overlay) OVERLAY="${2:?}"; shift 2 ;;
    --bucket)  BUCKET="${2:?}"; shift 2 ;;
    --host-tag) HOST_TAG="${2:?}"; shift 2 ;;
    --mirror)  MIRROR_URL="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$EXP_HASH" ]] || die "--hash is required"
[[ "$EXP_HASH" =~ ^[0-9a-f]{40}$ ]] || die \
  "--hash must be 40 lowercase hex chars (it becomes a storage path segment): $EXP_HASH"

FLUTTER_ROOT="$(cd -- "$FLUTTER_ROOT" >/dev/null 2>&1 && pwd)" || die "no checkout at $FLUTTER_ROOT"
OUT="$FLUTTER_ROOT/engine/src/out/android_release_arm64"
[[ -d "$OUT" ]] || die "no build output at $OUT (run build.sh --cell android-arm64 first)"

if [[ -z "$STOCK_HASH" ]]; then
  STOCK_HASH="$(tr -d '[:space:]' < "$FLUTTER_ROOT/bin/internal/engine.version")"
fi
[[ "$STOCK_HASH" =~ ^[0-9a-f]{40}$ ]] || die "bad stock hash: $STOCK_HASH"
[[ "$STOCK_HASH" != "$EXP_HASH" ]] || die \
  "--hash equals the pinned engine revision. Use a distinct hash so an
   experimental build can never be mistaken for, or overwrite, the supported pin."

INFRA="$OVERLAY/flutter_infra_release/flutter/$EXP_HASH"
MAVEN="$OVERLAY/download.flutter.io/io/flutter/arm64_v8a_release/1.0.0-$EXP_HASH"
SB="$OVERLAY/$BUCKET/shorebird/$EXP_HASH"
MAPFILE="$(dirname "$OVERLAY")/experimental_hashes.map"

note "Experimental hash: $EXP_HASH"
note "Falls back to:     $STOCK_HASH"
note "Overlay root:      $OVERLAY"

mkdir -p "$INFRA/android-arm64-release" "$MAVEN" "$SB"

missing=0
copy() {  # copy <src> <dest>
  if [[ -f "$1" ]]; then
    cp -f "$1" "$2"; echo "  + ${2#"$OVERLAY"/}"
  else
    echo "  ! MISSING $1" >&2; missing=1
  fi
}

# --- Engine artifacts --------------------------------------------------------
ZIPS="$OUT/zip_archives/android-arm64-release"
copy "$ZIPS/artifacts.zip"  "$INFRA/android-arm64-release/artifacts.zip"
copy "$ZIPS/symbols.zip"    "$INFRA/android-arm64-release/symbols.zip"
# Host gen_snapshot. NOT optional: see the VM-coupling note below.
copy "$ZIPS/linux-x64.zip"  "$INFRA/android-arm64-release/linux-x64.zip"

# --- VM-coupled host toolchain (learned on device) ---------------------------
# Dart version-locks snapshots against an MD5 over runtime/vm sources
# (tools/make_version.py VM_SNAPSHOT_FILES), and that list includes
# dart_api_impl.cc and image_snapshot.h — both touched by our fork. So an app
# snapshot built by anyone else's gen_snapshot is rejected at launch with
#   "Wrong full snapshot version, expected 'X' found 'Y'"
# and the app dies after installing cleanly. These must therefore come from the
# SAME tree as libflutter.so, not from the pinned revision:
HOST_OUT="$FLUTTER_ROOT/engine/src/out/host_release"
if [[ -d "$HOST_OUT" ]]; then
  # Re-zip every time. Reusing an existing zip once published an SDK older than
  # the dart-sdk/ it sat next to, after a rebuild of the VM.
  if [[ -d "$HOST_OUT/dart-sdk" ]]; then
    note "zipping dart-sdk ($HOST_TAG)"
    rm -f "$HOST_OUT/dart-sdk-$HOST_TAG.zip"
    ( cd "$HOST_OUT" && zip -qr "dart-sdk-$HOST_TAG.zip" dart-sdk )
  fi
  copy "$HOST_OUT/dart-sdk-$HOST_TAG.zip" "$INFRA/dart-sdk-$HOST_TAG.zip"
  copy "$HOST_OUT/zip_archives/flutter_patched_sdk_product.zip" \
       "$INFRA/flutter_patched_sdk_product.zip"
else
  echo "  ! MISSING $HOST_OUT — build it with:" >&2
  echo "      gn --runtime-mode=release --no-prebuilt-dart-sdk && \\" >&2
  echo "      ninja -C out/host_release dart_sdk flutter/build/archives:flutter_patched_sdk" >&2
  echo "    (build.sh --cell does this, and host_debug's artifacts.zip, unless --no-host)" >&2
  echo "    Without it the app installs and then dies at launch." >&2
  missing=1
fi

# Host engine artifacts: impellerc (every `flutter build` compiles shaders with
# it), flutter_tester, the host gen_snapshot. Built in host_debug, as Flutter
# and Shorebird CI do; build.sh --cell builds it unless --no-host.
HOST_DEBUG_OUT="$FLUTTER_ROOT/engine/src/out/host_debug"
mkdir -p "$INFRA/$HOST_TAG"
copy "$HOST_DEBUG_OUT/zip_archives/$HOST_TAG/artifacts.zip" "$INFRA/$HOST_TAG/artifacts.zip"

# The host toolchain must come from the same tree as the Android engine it
# ships with. After `build.sh --no-host`, or a host build that failed, the
# files above are still there from an earlier tree and would be published
# silently. Ask ninja whether they are current; comparing mtimes instead gives
# false alarms, since ninja leaves an output untouched when its inputs didn't
# change even though the Android cell next to it was relinked.
stale_check() {  # stale_check <out dir> <ninja target>...
  local out="$1"; shift
  if [[ ! -f "$out/build.ninja" ]] || ! command -v ninja >/dev/null 2>&1; then
    return 0
  fi
  if ! ninja -C "$out" -n "$@" 2>/dev/null | grep -q '^ninja: no work to do'; then
    echo "  ! STALE $out is not up to date for: $*; rebuild the host toolchain" >&2
    missing=1
  fi
}
stale_check "$HOST_OUT" dart_sdk flutter/build/archives:flutter_patched_sdk
stale_check "$HOST_DEBUG_OUT" flutter/build/archives:artifacts

# engine_stamp.json: Flutter's tool fetches it on every precache (3.47+;
# FlutterEngineStamp) and @must_be_local owns the path, so without it a
# release against this hash fails "Exception: 404". Only reported by the tool.
stamp_ms=$(( $(stat -c %Y "$ZIPS/artifacts.zip" 2>/dev/null || stat -f %m "$ZIPS/artifacts.zip") * 1000 ))
rev_date="$(git -C "$FLUTTER_ROOT" log -1 --format=%cI HEAD 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
content_hash="$EXP_HASH"
if [[ -f "$FLUTTER_ROOT/bin/internal/content_aware_hash.sh" ]]; then
  content_hash="$(cd "$FLUTTER_ROOT" && bash bin/internal/content_aware_hash.sh 2>/dev/null | tail -1)" \
    || content_hash="$EXP_HASH"
fi
printf '{"build_date":"%s","build_time_ms":%d,"git_revision":"%s","git_revision_date":"%s","content_hash":"%s"}\n' \
  "$(date -u -d "@$((stamp_ms / 1000))" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S)" \
  "$stamp_ms" "$EXP_HASH" "$rev_date" "${content_hash:-$EXP_HASH}" > "$INFRA/engine_stamp.json"
echo "  + ${INFRA#"$OVERLAY"/}/engine_stamp.json"

# NOTE: aot-tools.dill is deliberately NOT published. It lives in
# pkg/aot_tools inside Shorebird's PRIVATE Dart fork, so we cannot build it, and
# vanilla Dart has no equivalent. It is the AOT linker and only the Apple
# patchers invoke it, so Android is unaffected and the pinned copy is served.
# This single artifact is what blocks iOS on a self-built engine.

# --- Maven modules -----------------------------------------------------------
# A proxy CANNOT hash-rewrite these: Gradle validates the version inside the
# .pom body and fails with "inconsistent module metadata found". So every module
# a release resolves must exist locally under our hash — including the ABIs we
# did not build, whose jars are copied from the pinned revision with only the
# POM version rewritten.
#
# Our own module's POM also needs rewriting: the engine build stamps it with the
# Flutter checkout's HEAD, not the hash we publish under.
pom_retag() {  # pom_retag <file> <old-version-hash>
  [[ -f "$1" ]] || return 0
  sed -i.bak "s|1\.0\.0-$2|1.0.0-$EXP_HASH|g" "$1" && rm -f "$1.bak"
}

copy "$OUT/arm64_v8a_release.jar" "$MAVEN/arm64_v8a_release-1.0.0-$EXP_HASH.jar"
copy "$OUT/arm64_v8a_release.pom" "$MAVEN/arm64_v8a_release-1.0.0-$EXP_HASH.pom"
if [[ -f "$MAVEN/arm64_v8a_release-1.0.0-$EXP_HASH.pom" ]]; then
  # whatever version the build stamped in, make it ours
  BUILT_VER="$(sed -n 's|.*<version>1\.0\.0-\([0-9a-f]\{40\}\)</version>.*|\1|p' \
    "$MAVEN/arm64_v8a_release-1.0.0-$EXP_HASH.pom" | head -1)"
  if [[ -n "$BUILT_VER" && "$BUILT_VER" != "$EXP_HASH" ]]; then
    pom_retag "$MAVEN/arm64_v8a_release-1.0.0-$EXP_HASH.pom" "$BUILT_VER"
    echo "    (POM version $BUILT_VER -> $EXP_HASH)"
  fi
fi

# The ABIs and the embedding jar we did not build: take the pinned ones and
# retag. MIRROR_URL must serve the pinned revision (the CDN mirror does).
for mod in flutter_embedding_release armeabi_v7a_release x86_64_release; do
  d="$OVERLAY/download.flutter.io/io/flutter/$mod/1.0.0-$EXP_HASH"
  mkdir -p "$d"
  for ext in jar pom; do
    dest="$d/$mod-1.0.0-$EXP_HASH.$ext"
    [[ -f "$dest" ]] && continue
    src="$MIRROR_URL/download.flutter.io/io/flutter/$mod/1.0.0-$STOCK_HASH/$mod-1.0.0-$STOCK_HASH.$ext"
    if curl -fsSL "$src" -o "$dest"; then
      echo "  + ${dest#"$OVERLAY"/} (from $STOCK_HASH)"
    else
      echo "  ! could not fetch $src" >&2; missing=1; rm -f "$dest"
    fi
  done
  pom_retag "$d/$mod-1.0.0-$EXP_HASH.pom" "$STOCK_HASH"
done

# --- Manifest ----------------------------------------------------------------
# Informational for now: Caddy rewrites experimental hashes to the pinned one
# before artifact_proxy sees them, so artifact_proxy reads the pinned manifest.
# Publishing it anyway keeps the prefix self-describing and makes the eventual
# move to publish_to_store.sh a no-op.
# Flutter forks before shorebirdtech/flutter#220 ship generate_manifest.sh;
# later ones only the template that upstream's shard_runner fills in.
GEN="$FLUTTER_ROOT/shorebird/ci/internal/generate_manifest.sh"
TEMPLATE="$FLUTTER_ROOT/shorebird/ci/artifacts_manifest.template.yaml"
if [[ -f "$GEN" ]]; then
  bash "$GEN" "$EXP_HASH" > "$SB/artifacts_manifest.yaml"
  echo "  + ${SB#"$OVERLAY"/}/artifacts_manifest.yaml"
elif [[ -f "$TEMPLATE" ]]; then
  sed "s/{{flutter_engine_revision}}/$EXP_HASH/g" "$TEMPLATE" \
    > "$SB/artifacts_manifest.yaml"
  echo "  + ${SB#"$OVERLAY"/}/artifacts_manifest.yaml (from template)"
else
  echo "  ! MISSING $GEN and $TEMPLATE (manifest not written)" >&2
fi

# --- Patch differ (Flow B) -----------------------------------------------------
# The CLI fetches patch-<plat>.zip from shorebird/<rev>/, and @must_be_local in
# the Caddyfile owns that path for experimental hashes — so every publish must
# carry the differ or patch builds against this hash die on a loud 404. This
# builds the HOST platform's zip; other platforms' zips are published from
# their own build hosts (windows stays mirrored — recorded gap).
PATCH_TOOL="$(dirname "${BASH_SOURCE[0]}")/publish_patch_tool.sh"
if bash "$PATCH_TOOL" --overlay "$OVERLAY" --rev "$EXP_HASH" >/dev/null; then
  echo "  + ${SB#"$OVERLAY"/}/patch-<host>.zip (via publish_patch_tool.sh)"
else
  echo "  ! publish_patch_tool.sh failed — patch builds against $EXP_HASH will 404" >&2
fi

# --- Provenance --------------------------------------------------------------
{
  echo "experimental_engine_hash: $EXP_HASH"
  echo "falls_back_to:            $STOCK_HASH"
  echo "built_from:               $FLUTTER_ROOT"
  if git -C "$FLUTTER_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "git_head:                 $(git -C "$FLUTTER_ROOT" rev-parse HEAD)"
    echo "git_branch:               $(git -C "$FLUTTER_ROOT" rev-parse --abbrev-ref HEAD)"
    echo "git_dirty:                $(git -C "$FLUTTER_ROOT" status --porcelain | wc -l | tr -d ' ') file(s)"
  else
    echo "git_head:                 (not a git checkout)"
  fi
  echo "built_on:                 $(uname -srm) $(hostname)"
  echo "published_at:             $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "local_artifacts:          android-arm64-release/{artifacts,symbols,linux-x64}.zip,"
  echo "                          $HOST_TAG/artifacts.zip, dart-sdk-$HOST_TAG.zip,"
  echo "                          flutter_patched_sdk_product.zip, engine_stamp.json,"
  echo "                          arm64_v8a_release-1.0.0-$EXP_HASH.{jar,pom}"
  echo "everything_else:          served from $STOCK_HASH by the mirror"
} > "$SB/PROVENANCE.txt"
echo "  + ${SB#"$OVERLAY"/}/PROVENANCE.txt"

# --- Hash map consumed by Caddy ---------------------------------------------
# One `<expHash> <stockHash>` per line. Idempotent: replace any existing entry.
mkdir -p "$(dirname "$MAPFILE")"
touch "$MAPFILE"
grep -v "^$EXP_HASH " "$MAPFILE" > "$MAPFILE.tmp" || true
echo "$EXP_HASH $STOCK_HASH" >> "$MAPFILE.tmp"
# Sort the ENTRIES only, keeping the comment header in its authored order. This
# file is checked in and its comments are what document why it ships empty;
# sorting the whole file (as this did) sorts them into nonsense, and the
# damage lands in a tracked file.
{
  grep '^[[:space:]]*#' "$MAPFILE.tmp" || true
  grep -v '^[[:space:]]*#' "$MAPFILE.tmp" | grep -v '^[[:space:]]*$' | sort
} > "$MAPFILE"
rm -f "$MAPFILE.tmp"
note "Hash map: $MAPFILE"
sed 's/^/  /' "$MAPFILE"

if [[ "$missing" == "1" ]]; then
  echo >&2
  echo "WARNING: some owned artifacts were not published. The mirror will 404 on" >&2
  echo "those paths rather than serve stock bytes — that is intentional, but the" >&2
  echo "build will fail until you rebuild and re-run this script." >&2
fi

cat <<EOF

==> Reload the mirror so Caddy picks up the new hash map:
      docker compose -f selfhost/cdn/docker-compose.cdn.yaml up -d --force-recreate cdn-cache

==> Point the CLI at this engine (on the machine that runs \`shorebird\`):
      echo $EXP_HASH > \$HOME/.shorebird/bin/cache/flutter/<flutterRevision>/bin/internal/engine.version
      shorebird cache clean
      shorebird doctor    # must report: Engine • revision $EXP_HASH
    Revert with: git -C \$HOME/.shorebird/bin/cache/flutter/<flutterRevision> \\
      checkout bin/internal/engine.version
EOF
