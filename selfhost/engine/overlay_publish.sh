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
# So we publish what we built and let nginx serve the rest from the already-warm
# pinned-revision cache, rewriting the hash on the way out.
#
# The mirror is configured so that the artifacts THIS script owns are never
# eligible for that fallback: if a rebuild is missing from the overlay the
# request 404s instead of silently resolving to Shorebird's stock bytes. See
# `$overlay_owned` in selfhost/cdn/nginx.conf.
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
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1 && pwd)"

EXP_HASH=""
STOCK_HASH=""
FLUTTER_ROOT="$REPO_ROOT/vendor/flutter"
OVERLAY="$REPO_ROOT/selfhost/cdn/overlay"
BUCKET="download.shorebird.dev"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hash)    EXP_HASH="${2:?}"; shift 2 ;;
    --stock)   STOCK_HASH="${2:?}"; shift 2 ;;
    --root)    FLUTTER_ROOT="${2:?}"; shift 2 ;;
    --overlay) OVERLAY="${2:?}"; shift 2 ;;
    --bucket)  BUCKET="${2:?}"; shift 2 ;;
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

# --- Artifacts this overlay OWNS (nginx will 404 rather than fall back) ------
ZIPS="$OUT/zip_archives/android-arm64-release"
copy "$ZIPS/artifacts.zip"  "$INFRA/android-arm64-release/artifacts.zip"
copy "$ZIPS/symbols.zip"    "$INFRA/android-arm64-release/symbols.zip"
# Host gen_snapshot built here. Only a Linux-host build consumes it; a Mac-driven
# `shorebird release android` fetches darwin-x64.zip, which cannot be produced on
# Linux and is served stock by design.
copy "$ZIPS/linux-x64.zip"  "$INFRA/android-arm64-release/linux-x64.zip"

# The Maven artifact is what Gradle resolves, so this jar is the one that
# actually puts our libflutter.so in the APK.
copy "$OUT/arm64_v8a_release.jar" "$MAVEN/arm64_v8a_release-1.0.0-$EXP_HASH.jar"
copy "$OUT/arm64_v8a_release.pom" "$MAVEN/arm64_v8a_release-1.0.0-$EXP_HASH.pom"
if [[ -f "$OUT/arm64_v8a_release.maven-metadata.xml" ]]; then
  copy "$OUT/arm64_v8a_release.maven-metadata.xml" \
       "$MAVEN/arm64_v8a_release-1.0.0-$EXP_HASH.maven-metadata.xml"
fi

# --- Manifest ----------------------------------------------------------------
# Informational for now: nginx rewrites experimental hashes to the pinned one
# before artifact_proxy sees them, so artifact_proxy reads the pinned manifest.
# Publishing it anyway keeps the prefix self-describing and makes the eventual
# move to publish_to_store.sh a no-op.
GEN="$FLUTTER_ROOT/shorebird/ci/internal/generate_manifest.sh"
if [[ -f "$GEN" ]]; then
  bash "$GEN" "$EXP_HASH" > "$SB/artifacts_manifest.yaml"
  echo "  + ${SB#"$OVERLAY"/}/artifacts_manifest.yaml"
else
  echo "  ! MISSING $GEN (manifest not written)" >&2
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
  echo "                          arm64_v8a_release-1.0.0-$EXP_HASH.{jar,pom}"
  echo "everything_else:          served from $STOCK_HASH by the mirror"
} > "$SB/PROVENANCE.txt"
echo "  + ${SB#"$OVERLAY"/}/PROVENANCE.txt"

# --- Hash map consumed by nginx ---------------------------------------------
# One `<expHash> <stockHash>;` per line. Idempotent: replace any existing entry.
mkdir -p "$(dirname "$MAPFILE")"
touch "$MAPFILE"
grep -v "^$EXP_HASH " "$MAPFILE" > "$MAPFILE.tmp" || true
echo "$EXP_HASH $STOCK_HASH;" >> "$MAPFILE.tmp"
sort -o "$MAPFILE" "$MAPFILE.tmp"
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

==> Reload the mirror so nginx picks up the new hash map:
      docker compose -f selfhost/cdn/docker-compose.cdn.yaml up -d --force-recreate cdn-cache

==> Point the CLI at this engine (on the machine that runs \`shorebird\`):
      echo $EXP_HASH > \$HOME/.shorebird/bin/cache/flutter/<flutterRevision>/bin/internal/engine.version
      shorebird cache clean
      shorebird doctor    # must report: Engine • revision $EXP_HASH
    Revert with: git -C \$HOME/.shorebird/bin/cache/flutter/<flutterRevision> \\
      checkout bin/internal/engine.version
EOF
