#!/usr/bin/env bash
# cspell:words retagged
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
[[ -d "$OUT" ]] || die "no build output at $OUT (run build.sh --cell android first)"

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
    # Drop what an earlier publish left here, so a missing artifact 404s
    # instead of serving another tree's bytes.
    echo "  ! MISSING $1" >&2; missing=1; rm -f "$2"
  fi
}

# --- Engine artifacts --------------------------------------------------------
ZIPS="$OUT/zip_archives/android-arm64-release"
copy "$ZIPS/artifacts.zip"  "$INFRA/android-arm64-release/artifacts.zip"
copy "$ZIPS/symbols.zip"    "$INFRA/android-arm64-release/symbols.zip"
# Host gen_snapshot. NOT optional: see the VM-coupling note below.
copy "$ZIPS/linux-x64.zip"  "$INFRA/android-arm64-release/linux-x64.zip"

# The other two release ABIs. @must_be_local owns all three (each zip holds
# the host gen_snapshot that compiles that ABI's libapp.so), so one that isn't
# built here 404s and `flutter precache` fails for this hash. Build them with
# `build.sh --cell android`.
OWN_MODS=("$OUT:arm64_v8a_release")
STOCK_MODS=()
for abi in arm x64; do
  case "$abi" in
    arm) abi_dir=android_release;     abi_mod=armeabi_v7a_release ;;
    x64) abi_dir=android_release_x64; abi_mod=x86_64_release ;;
  esac
  abi_out="$FLUTTER_ROOT/engine/src/out/$abi_dir"
  if [[ -d "$abi_out/zip_archives/android-$abi-release" ]]; then
    mkdir -p "$INFRA/android-$abi-release"
    for z in artifacts symbols linux-x64; do
      copy "$abi_out/zip_archives/android-$abi-release/$z.zip" "$INFRA/android-$abi-release/$z.zip"
    done
    OWN_MODS+=("$abi_out:$abi_mod")
  else
    echo "  ! MISSING $abi_out: android-$abi-release/ will 404 (build.sh --cell android)" >&2
    missing=1
    # An earlier publish's zips and jars for this ABI came from another tree.
    rm -rf "$INFRA/android-$abi-release" "$OVERLAY/download.flutter.io/io/flutter/$abi_mod/1.0.0-$EXP_HASH"
    STOCK_MODS+=("$abi_mod")
  fi
done
# The Java embedding is ABI-independent; ours when the build made it.
if [[ -f "$OUT/flutter_embedding_release.jar" ]]; then
  OWN_MODS+=("$OUT:flutter_embedding_release")
else
  STOCK_MODS+=(flutter_embedding_release)
  rm -rf "$OVERLAY/download.flutter.io/io/flutter/flutter_embedding_release/1.0.0-$EXP_HASH"
fi

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
# The non-product patched SDK: `flutter precache` fetches it with the product
# one, and @must_be_local owns it.
copy "$HOST_DEBUG_OUT/zip_archives/flutter_patched_sdk.zip" "$INFRA/flutter_patched_sdk.zip"
# font-subset.zip carries const_finder.dart.snapshot and extracts into the same
# cache directory as artifacts.zip. build.sh builds it in host_release
# (flutter/tools/font_subset). The mirror does NOT own linux-x64/font-subset.zip
# for an experimental hash (only per supported cell; see the Caddyfile), so if
# this copy is missing the mirror serves the stock one, whose SDK hash our Dart
# rejects: "ConstFinder failure: Can't load Kernel binary: Invalid SDK hash" at
# the icon tree shaker. The MISSING line below is the only warning you get. Add
# the hash to the Caddyfile's per-cell font-subset arm when it is promoted.
copy "$HOST_OUT/zip_archives/$HOST_TAG/font-subset.zip" "$INFRA/$HOST_TAG/font-subset.zip"

# The host toolchain must come from the same tree as the Android engine it
# ships with. After `build.sh --no-host`, or a host build that failed, the
# files above are still there from an earlier tree and would be published
# silently. Ask ninja whether they are current; comparing mtimes instead gives
# false alarms, since ninja leaves an output untouched when its inputs didn't
# change even though the Android cell next to it was relinked.
# The Android cells are checked the same way: an ABI left over from an older
# tree, published next to a newer host gen_snapshot, dies at launch with
# "Wrong full snapshot version". Unable to ask counts as stale.
stale_check() {  # stale_check <out dir> <ninja target>...
  local out="$1"; shift
  [[ -d "$out" ]] || return 0   # absent: already reported MISSING above
  if [[ ! -f "$out/build.ninja" ]] || ! command -v ninja >/dev/null 2>&1; then
    echo "  ! STALE? cannot ask ninja about $out (no build.ninja, or ninja not on PATH)" >&2
    missing=1; return 0
  fi
  local plan
  plan="$(ninja -C "$out" -n "$@" 2>&1 || true)"
  if ! grep -q '^ninja: no work to do' <<<"$plan"; then
    echo "  ! STALE $out is not up to date for: $*; rebuild it (build.sh --cell android)" >&2
    missing=1
  fi
}
stale_check "$HOST_OUT" dart_sdk flutter/build/archives:flutter_patched_sdk flutter/tools/font_subset
stale_check "$HOST_DEBUG_OUT" flutter/build/archives:artifacts flutter/build/archives:flutter_patched_sdk
for d in android_release_arm64 android_release android_release_x64; do
  stale_check "$FLUTTER_ROOT/engine/src/out/$d" default
done

# engine_stamp.json: Flutter's tool fetches it on every precache (3.47+;
# FlutterEngineStamp) and @must_be_local owns the path, so without it a
# release against this hash fails "Exception: 404". Only reported by the tool.
stamp_s="$(stat -c %Y "$ZIPS/artifacts.zip" 2>/dev/null || stat -f %m "$ZIPS/artifacts.zip" 2>/dev/null || date +%s)"
stamp_ms=$(( stamp_s * 1000 ))
# Only this checkout's own history: in a tree without its own .git, `git log`
# would read whatever repository encloses it.
rev_date=""
if [[ -e "$FLUTTER_ROOT/.git" ]]; then
  rev_date="$(git -C "$FLUTTER_ROOT" log -1 --format=%cI HEAD 2>/dev/null || true)"
fi
if [[ -z "$rev_date" ]]; then
  echo "  ! engine_stamp.json: no git history at $FLUTTER_ROOT; git_revision_date is the publish time" >&2
  rev_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi
content_hash=""
if [[ -f "$FLUTTER_ROOT/bin/internal/content_aware_hash.sh" ]]; then
  content_hash="$(cd "$FLUTTER_ROOT" && bash bin/internal/content_aware_hash.sh 2>/dev/null | tail -1 || true)"
fi
if [[ ! "$content_hash" =~ ^[0-9a-f]{40}$ ]]; then
  echo "  ! engine_stamp.json: no content hash from bin/internal/content_aware_hash.sh; using $EXP_HASH" >&2
  content_hash="$EXP_HASH"
fi
printf '{"build_date":"%s","build_time_ms":%d,"git_revision":"%s","git_revision_date":"%s","content_hash":"%s"}\n' \
  "$(date -u -d "@$stamp_s" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -r "$stamp_s" +%Y-%m-%dT%H:%M:%S)" \
  "$stamp_ms" "$EXP_HASH" "$rev_date" "$content_hash" > "$INFRA/engine_stamp.json"
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

# Our modules: copy, then make whatever version the build stamped ours.
for entry in "${OWN_MODS[@]}"; do
  mod_out="${entry%%:*}"; mod="${entry#*:}"
  d="$OVERLAY/download.flutter.io/io/flutter/$mod/1.0.0-$EXP_HASH"
  mkdir -p "$d"
  copy "$mod_out/$mod.jar" "$d/$mod-1.0.0-$EXP_HASH.jar"
  copy "$mod_out/$mod.pom" "$d/$mod-1.0.0-$EXP_HASH.pom"
  pom="$d/$mod-1.0.0-$EXP_HASH.pom"
  [[ -f "$pom" ]] || continue
  BUILT_VER="$(sed -n 's|.*<version>1\.0\.0-\([0-9a-f]\{40\}\)</version>.*|\1|p' "$pom" | head -1)"
  if [[ -n "$BUILT_VER" && "$BUILT_VER" != "$EXP_HASH" ]]; then
    pom_retag "$pom" "$BUILT_VER"
    echo "    (POM version $BUILT_VER -> $EXP_HASH)"
  fi
  # maven-metadata.xml: the engine build writes <module>.maven-metadata.xml
  # beside the jar and pom, and the policy requires it for arm64_v8a_release
  # (it used to be added by hand). Published under the same naming the jar and
  # pom use, and retagged the same way, since it names the version too.
  meta="$d/$mod-1.0.0-$EXP_HASH.maven-metadata.xml"
  copy "$mod_out/$mod.maven-metadata.xml" "$meta"
  if [[ -f "$meta" && -n "$BUILT_VER" && "$BUILT_VER" != "$EXP_HASH" ]]; then
    pom_retag "$meta" "$BUILT_VER"
  fi
done

# Modules we did not build: take the pinned ones and retag. MIRROR_URL must
# serve the pinned revision (the CDN mirror does).
for mod in ${STOCK_MODS[@]+"${STOCK_MODS[@]}"}; do
  d="$OVERLAY/download.flutter.io/io/flutter/$mod/1.0.0-$EXP_HASH"
  mkdir -p "$d"
  for ext in jar pom; do
    dest="$d/$mod-1.0.0-$EXP_HASH.$ext"
    src="$MIRROR_URL/download.flutter.io/io/flutter/$mod/1.0.0-$STOCK_HASH/$mod-1.0.0-$STOCK_HASH.$ext"
    if curl -fsSL "$src" -o "$dest"; then
      echo "  + ${dest#"$OVERLAY"/} (from $STOCK_HASH)"
    else
      echo "  ! could not fetch $src" >&2; missing=1; rm -f "$dest"
    fi
  done
  pom_retag "$d/$mod-1.0.0-$EXP_HASH.pom" "$STOCK_HASH"
done

# --- sky_engine.zip and flutter_gpu.zip -------------------------------------
# @must_be_local_pkgs owns them per hash, and the policy requires them, so they
# are published with everything else instead of as a separate hand step. The
# publisher fetches stock through the mirror to record whether the content
# matches; it publishes ours either way. This script still does not touch the
# Caddyfile: add the hash to @must_be_local_pkgs once the audit shows the bytes
# are there.
SKY_PUB="$(dirname "${BASH_SOURCE[0]}")/publish_sky_packages.sh"
# The Android out dir, not host_*: a Linux host_* out dir holds a one-file stub
# gen/dart-pkg/sky_engine, while the Android ones carry the full 289-file tree.
SKY_OUT="$OUT"
if [[ -d "$SKY_OUT/gen/dart-pkg/sky_engine" ]] && bash "$SKY_PUB" --hash "$EXP_HASH" \
     --engine-out "$SKY_OUT" --engine-src "$FLUTTER_ROOT/engine/src" \
     --overlay "$OVERLAY" --mirror "$MIRROR_URL" --pinned-hash "$STOCK_HASH" >/dev/null; then
  echo "  + ${INFRA#"$OVERLAY"/}/{sky_engine,flutter_gpu}.zip (via publish_sky_packages.sh)"
else
  echo "  ! sky_engine.zip / flutter_gpu.zip not published (no gen/dart-pkg/sky_engine under $SKY_OUT, or publish_sky_packages.sh failed; run it by hand)" >&2
  missing=1
  # As copy() does: drop what an earlier publish left, so a miss 404s instead
  # of serving another tree's bytes under this hash.
  rm -f "$INFRA/sky_engine.zip" "$INFRA/flutter_gpu.zip" "$INFRA/sky_packages_provenance.txt" \
        "$INFRA/sky_engine.content-diff.txt" "$INFRA/flutter_gpu.content-diff.txt"
fi

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
  echo "local_artifacts:          android-{arm64,arm,x64}-release/{artifacts,symbols,linux-x64}.zip (as built),"
  echo "                          $HOST_TAG/{artifacts,font-subset}.zip, dart-sdk-$HOST_TAG.zip,"
  echo "                          flutter_patched_sdk{,_product}.zip, engine_stamp.json,"
  echo "                          sky_engine.zip, flutter_gpu.zip,"
  echo "                          maven (jar, pom, maven-metadata.xml): ${OWN_MODS[*]##*:}"
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
  exit 3
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
