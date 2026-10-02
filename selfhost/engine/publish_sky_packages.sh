#!/usr/bin/env bash
# cspell:words lsha ssha SIGPIPEs
# publish_sky_packages.sh — own sky_engine.zip and flutter_gpu.zip for one of
# our engine hashes, instead of letting them fall through to stock.
#
#   selfhost/engine/publish_sky_packages.sh --hash <engineHash> \
#     --engine-out /path/to/engine/src/out/<config> \
#     [--overlay selfhost/cdn/overlay] [--mirror http://localhost:8085] \
#     [--pinned-hash 69f9831c...] [--sky-zip P] [--gpu-zip P]
#
# WHY THESE TWO, AND WHY THEY WERE INVISIBLE
#
# They are `getPackageDirs()` in flutter_tools' FlutterSdk cache class
# (flutter_cache.dart:264) and are fetched as
# <base>/flutter_infra_release/flutter/<hash>/<name>.zip. Nothing in the
# overlay publishers ever produced them, and @must_be_local never matched
# them, so a request under a CUSTOM hash silently resolved to STOCK bytes from
# the pinned revision. Absent locally, present in the response: the one failure
# shape you cannot see by looking at the overlay.
#
# "Stock is byte-identical today" is not a reason to skip this.
# sky_engine.zip carries sky_engine/lib/_internal/**/*_patch.dart — Dart SDK
# patch SOURCE — and sky_engine/lib/ui, the dart:ui source. Our SHIPPING
# engine's Dart changes are runtime-only, so those files do match stock right
# now. But engine/killgate/0001-attach-bytecode-native.patch modifies
# sdk/lib/_internal/vm/lib/internal_patch.dart, and a tree carrying it would
# produce a DIFFERENT sky_engine while we happily served stock. Own the bytes;
# record the comparison.
#
# ORDER MATTERS — this script publishes and DOES NOT touch the Caddyfile.
# Protecting a path in @must_be_local before the bytes exist 404s every build
# against that hash. Publish, audit, then protect:
#
#   1. selfhost/engine/publish_sky_packages.sh --hash H --engine-out OUT
#   2. selfhost/cdn/audit_overlay.sh --hash H --cell <cell>       # missing-required: 0
#   3. add sky_engine\.zip$|flutter_gpu\.zip$ to @must_be_local
#   4. selfhost/cdn/audit_overlay.sh --hash H --cell <cell>       # AUDIT CLEAN
#
# Do NOT copy these between engine hashes even when they compare equal. They
# are engine-revision namespaced and they are 1.5 MB and 49 KB. Own them
# honestly per hash.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
OVERLAY="$HERE/../cdn/overlay"
MIRROR="http://localhost:8085"
PINNED="69f9831c360d9152862ec3897c67fb09ae843f3b"
HASH=""; ENGINE_OUT=""; ENGINE_SRC=""; SKY_ZIP=""; GPU_ZIP=""; SOURCE_NOTE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hash) HASH="${2:?}"; shift 2 ;;
    --engine-out) ENGINE_OUT="${2:?}"; shift 2 ;;
    --engine-src) ENGINE_SRC="${2:?}"; shift 2 ;;
    --overlay) OVERLAY="${2:?}"; shift 2 ;;
    --mirror) MIRROR="${2:?}"; shift 2 ;;
    --pinned-hash) PINNED="${2:?}"; shift 2 ;;
    --sky-zip) SKY_ZIP="${2:?}"; shift 2 ;;
    --gpu-zip) GPU_ZIP="${2:?}"; shift 2 ;;
    # Where the tree really came from, when it is not the tree you are standing
    # in. The Android flow builds on the box and publishes where the mirror is
    # (see HANDOFF), so the local path is a staging dir and says nothing about
    # origin. Free text, recorded verbatim.
    --source-note) SOURCE_NOTE="${2:?}"; shift 2 ;;
    -h|--help) sed -n '3,43p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$HASH" ]] || { echo "ERROR: --hash is required" >&2; exit 2; }
# <engine-src> is the `src` dir; <engine-out> is src/out/<config> under it.
# Derive one from the other so callers normally pass only --engine-out.
if [[ -z "$ENGINE_SRC" && -n "$ENGINE_OUT" ]]; then
  ENGINE_SRC="$(cd -- "$ENGINE_OUT/../.." >/dev/null 2>&1 && pwd || true)"
fi
[[ -d "$OVERLAY" ]] || { echo "ERROR: no overlay at $OVERLAY" >&2; exit 2; }
command -v unzip >/dev/null || { echo "ERROR: unzip is required" >&2; exit 2; }

sha() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' || sha256sum "$1" | awk '{print $1}'; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
INFRA="$OVERLAY/flutter_infra_release/flutter/$HASH"
mkdir -p "$INFRA"
REPORT="$INFRA/sky_packages_provenance.txt"
: > "$WORK/report"

# --- Locate the local copy ---------------------------------------------------
# An explicit --sky-zip/--gpu-zip always wins; otherwise this is the order.
#
# VERIFIED AGAINST A REAL TREE 2026-08-07 (the Android build box). The two
# packages come from DIFFERENT places, which an earlier version of this script
# got wrong by assuming both were under gen/dart-pkg:
#
#   sky_engine   <out>/gen/dart-pkg/sky_engine      288 files — build output
#                (dart:ui + the Dart SDK patch sources)
#   flutter_gpu  <src>/flutter/lib/gpu               34 files — SOURCE dir,
#                packaged as flutter_gpu/. It has no build output at all; the
#                published zip is the .cc/.h/.dart sources verbatim.
#
# Both file lists were diffed against the stock zips and match exactly.
#
# Both published zips also carry a root LICENSE.zip_old_location.md, a
# licensing POINTER (it names the upstream flutter/engine revision where the
# LICENSE lives). We copy stock's verbatim rather than synthesize one: it is a
# statement about where the license is hosted, not a provenance claim, and
# rewriting it would misstate that. Our provenance claim lives in
# sky_packages_provenance.txt and provenance.yaml.
src_dir_for() {  # src_dir_for <name> ; echoes the directory to package, or nothing
  local name="$1"
  case "$name" in
    sky_engine)  [[ -n "$ENGINE_OUT" ]] && printf '%s' "$ENGINE_OUT/gen/dart-pkg/sky_engine" ;;
    flutter_gpu) [[ -n "$ENGINE_SRC" ]] && printf '%s' "$ENGINE_SRC/flutter/lib/gpu" ;;
  esac
}

# Echoes "<zip-path><TAB><human source description>". The description is what
# lands in the provenance record, so it must name the DIRECTORY the bytes came
# from — a temp zip path we just created tells a later reader nothing.
locate_zip() {  # locate_zip <name> <explicit-or-empty> <stock-zip-or-empty>
  local name="$1" explicit="$2" stock="$3" pkg
  if [[ -n "$explicit" ]]; then
    [[ -r "$explicit" ]] || { echo "ERROR: explicit zip $explicit is unreadable" >&2; return 1; }
    printf '%s\t%s' "$explicit" "explicit zip: $explicit"; return 0
  fi
  # 1. GN already built the archive (not the case on either host today, but
  #    cheap to prefer if a future config does emit it).
  if [[ -n "$ENGINE_OUT" && -r "$ENGINE_OUT/zip_archives/$name.zip" ]]; then
    printf '%s\t%s' "$ENGINE_OUT/zip_archives/$name.zip" \
                    "prebuilt archive: $ENGINE_OUT/zip_archives/$name.zip"; return 0
  fi
  # 2. Build it from the directory, matching the published layout: entries are
  #    "<name>/..." relative to a staging root.
  pkg="$(src_dir_for "$name")"
  [[ -n "$pkg" && -d "$pkg" ]] || return 1
  rm -rf "$WORK/stage-$name"; mkdir -p "$WORK/stage-$name"
  cp -R "$pkg" "$WORK/stage-$name/$name"
  # Capture the listing into a variable rather than piping into `grep -q`.
  # Under `set -o pipefail`, grep -q exits on the FIRST match and SIGPIPEs
  # unzip (141), which pipefail then reports as the pipeline's status — so the
  # test reads false. It only misfires on a listing long enough that grep wins
  # the race, which is why sky_engine (289 entries) silently lost its LICENSE
  # pointer while flutter_gpu (35) kept it. Observed for real, 2026-08-07.
  local listing=""
  [[ -n "$stock" ]] && listing="$(unzip -Z1 "$stock" 2>/dev/null || true)"
  case "$listing" in
    *LICENSE.zip_old_location.md*)
      unzip -qq -o "$stock" 'LICENSE.zip_old_location.md' -d "$WORK/stage-$name" ;;
  esac
  ( cd "$WORK/stage-$name" && zip -qr "$WORK/$name.zip" . )
  printf '%s\t%s' "$WORK/$name.zip" "packaged from directory: $pkg"; return 0
}

# --- Compare against stock ---------------------------------------------------
# Zip BYTE identity is a weak signal: mtimes, entry order and compression level
# all move it, and none of them mean the payload changed. So compare CONTENT —
# the extracted tree, file by file — and report both. Byte-differs-but-content-
# matches is the expected, fine result.
compare_content() {  # compare_content <local.zip> <stock.zip> <label>
  local a="$1" b="$2" label="$3"
  rm -rf "$WORK/x-$label-a" "$WORK/x-$label-b"
  mkdir -p "$WORK/x-$label-a" "$WORK/x-$label-b"
  unzip -qq "$a" -d "$WORK/x-$label-a" || return 2
  unzip -qq "$b" -d "$WORK/x-$label-b" || return 2
  ( cd "$WORK/x-$label-a" && find . -type f | sort | while read -r f; do
      printf '%s  %s\n' "$(sha "$f")" "$f"; done ) > "$WORK/$label.a"
  ( cd "$WORK/x-$label-b" && find . -type f | sort | while read -r f; do
      printf '%s  %s\n' "$(sha "$f")" "$f"; done ) > "$WORK/$label.b"
  diff -u "$WORK/$label.b" "$WORK/$label.a" > "$WORK/$label.diff" 2>&1
}

publish_one() {  # publish_one <name> <explicit-zip>
  local name="$1" explicit="$2" local_zip stock_zip rc
  echo "--- $name"

  # Stock comes FIRST: besides the comparison, it supplies the root
  # LICENSE.zip_old_location.md when we have to build the archive ourselves.
  stock_zip="$WORK/stock-$name.zip"
  if curl -fsSL "$MIRROR/flutter_infra_release/flutter/$PINNED/$name.zip" -o "$stock_zip"; then
    echo "  stock:  $MIRROR/.../$PINNED/$name.zip"
  else
    echo "  WARN: could not fetch stock $name — publishing anyway, comparison" >&2
    echo "        recorded as 'not performed' and the LICENSE pointer omitted." >&2
    stock_zip=""
  fi

  local located source_desc
  if ! located="$(locate_zip "$name" "$explicit" "$stock_zip")"; then
    echo "  ERROR: could not find $name locally." >&2
    echo "         Looked for: \$ENGINE_OUT/zip_archives/$name.zip" >&2
    echo "                 and $(src_dir_for "$name" || echo '<no source dir known>')" >&2
    echo "         Pass --sky-zip / --gpu-zip <path> if it lives elsewhere." >&2
    return 1
  fi
  local_zip="${located%%	*}"
  source_desc="${located#*	}"
  echo "  source: $source_desc"

  local lsha ssha content byte
  lsha="$(sha "$local_zip")"
  if [[ -n "$stock_zip" ]]; then
    ssha="$(sha "$stock_zip")"
    byte=$([[ "$lsha" == "$ssha" ]] && echo yes || echo no)
    if compare_content "$local_zip" "$stock_zip" "$name"; then
      content=yes
    else
      rc=$?
      [[ $rc -eq 2 ]] && content="ERROR-unreadable" || content=no
    fi
  else
    ssha="(not fetched)"; byte="(not compared)"; content="(not compared)"
  fi

  echo "  local sha256:      $lsha"
  echo "  stock sha256:      $ssha"
  echo "  zip bytes match:   $byte"
  echo "  CONTENT matches:   $content"
  if [[ "$content" == "no" ]]; then
    # Keep the evidence: $WORK is deleted on exit, and a divergence here is
    # exactly the finding someone will want to read afterwards.
    cp -f "$WORK/$name.diff" "$INFRA/$name.content-diff.txt"
    echo "  differing files (stock -> ours):"
    grep -E '^[-+][^-+]' "$WORK/$name.diff" | head -20 | sed 's/^/    /'
    echo "    full diff kept at $INFRA/$name.content-diff.txt"
  else
    # A stale diff from a previous divergent run would otherwise outlive its truth.
    rm -f "$INFRA/$name.content-diff.txt"
  fi

  # Publish REGARDLESS of the comparison result. Equality is a fact to record,
  # never a reason to skip: it removes fallback from the correctness path.
  cp -f "$local_zip" "$INFRA/$name.zip"
  echo "  + flutter_infra_release/flutter/$HASH/$name.zip"

  {
    echo "artifact:          $name.zip"
    echo "engine_hash:       $HASH"
    echo "local_sha256:      $lsha"
    echo "stock_sha256:      $ssha"
    echo "stock_source:      $PINNED"
    echo "zip_bytes_match:   $byte"
    echo "content_matches:   $content"
    echo "built_from:        $source_desc"
    [[ -n "$SOURCE_NOTE" ]] && echo "source_note:       $SOURCE_NOTE"
    echo
  } >> "$WORK/report"
}

FAILED=0
publish_one sky_engine  "$SKY_ZIP" || FAILED=1
publish_one flutter_gpu "$GPU_ZIP" || FAILED=1

if [[ $FAILED -eq 0 ]]; then
  { echo "# sky_engine / flutter_gpu provenance for $HASH"
    echo "# Written by selfhost/engine/publish_sky_packages.sh"
    echo "# 'content_matches: yes' with 'zip_bytes_match: no' is the EXPECTED"
    echo "# result — zip byte identity moves with mtimes and entry order."
    echo
    cat "$WORK/report"; } > "$REPORT"
  echo
  echo "wrote $REPORT"
  echo
  echo "NEXT: audit, then protect (in that order):"
  echo "  selfhost/cdn/audit_overlay.sh --hash $HASH --cell <macos-ios|linux-android>"
  echo "  then add sky_engine/flutter_gpu to @must_be_local in selfhost/cdn/Caddyfile"
  echo "  and re-run the audit; it should print AUDIT CLEAN."
else
  echo
  echo "FAILED: at least one package was not published; nothing to protect yet." >&2
  exit 1
fi
