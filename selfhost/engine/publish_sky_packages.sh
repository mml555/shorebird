#!/usr/bin/env bash
# cspell:words lsha ssha
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
HASH=""; ENGINE_OUT=""; SKY_ZIP=""; GPU_ZIP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hash) HASH="${2:?}"; shift 2 ;;
    --engine-out) ENGINE_OUT="${2:?}"; shift 2 ;;
    --overlay) OVERLAY="${2:?}"; shift 2 ;;
    --mirror) MIRROR="${2:?}"; shift 2 ;;
    --pinned-hash) PINNED="${2:?}"; shift 2 ;;
    --sky-zip) SKY_ZIP="${2:?}"; shift 2 ;;
    --gpu-zip) GPU_ZIP="${2:?}"; shift 2 ;;
    -h|--help) sed -n '3,43p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$HASH" ]] || { echo "ERROR: --hash is required" >&2; exit 2; }
[[ -d "$OVERLAY" ]] || { echo "ERROR: no overlay at $OVERLAY" >&2; exit 2; }
command -v unzip >/dev/null || { echo "ERROR: unzip is required" >&2; exit 2; }

sha() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' || sha256sum "$1" | awk '{print $1}'; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
INFRA="$OVERLAY/flutter_infra_release/flutter/$HASH"
mkdir -p "$INFRA"
REPORT="$INFRA/sky_packages_provenance.txt"
: > "$WORK/report"

# --- Locate the local copy ---------------------------------------------------
# Preference order, and each is a real place these land depending on how the
# tree was built. An explicit --sky-zip/--gpu-zip always wins.
locate_zip() {  # locate_zip <name> <explicit-or-empty> ; echoes a zip path
  local name="$1" explicit="$2"
  if [[ -n "$explicit" ]]; then
    [[ -r "$explicit" ]] || { echo "ERROR: --${name%_*}-zip $explicit is unreadable" >&2; return 1; }
    printf '%s' "$explicit"; return 0
  fi
  [[ -n "$ENGINE_OUT" ]] || return 1
  # 1. GN already built the archive.
  if [[ -r "$ENGINE_OUT/zip_archives/$name.zip" ]]; then
    printf '%s' "$ENGINE_OUT/zip_archives/$name.zip"; return 0
  fi
  # 2. Only the package tree exists — build the archive ourselves, matching the
  #    published layout: entries are "<name>/..." relative to the parent dir.
  local pkg="$ENGINE_OUT/gen/dart-pkg/$name"
  if [[ -d "$pkg" ]]; then
    ( cd "$(dirname "$pkg")" && zip -qr "$WORK/$name.zip" "$name" )
    printf '%s' "$WORK/$name.zip"; return 0
  fi
  return 1
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

  if ! local_zip="$(locate_zip "$name" "$explicit")"; then
    echo "  ERROR: could not find $name locally." >&2
    echo "         Looked for: \$ENGINE_OUT/zip_archives/$name.zip" >&2
    echo "                 and \$ENGINE_OUT/gen/dart-pkg/$name/" >&2
    echo "         Pass --${name%_*}-zip <path> if it lives elsewhere in this tree." >&2
    return 1
  fi
  echo "  local:  $local_zip"

  stock_zip="$WORK/stock-$name.zip"
  if curl -fsSL "$MIRROR/flutter_infra_release/flutter/$PINNED/$name.zip" -o "$stock_zip"; then
    echo "  stock:  $MIRROR/.../$PINNED/$name.zip"
  else
    echo "  WARN: could not fetch stock $name for comparison — publishing anyway," >&2
    echo "        with the comparison recorded as 'not performed'." >&2
    stock_zip=""
  fi

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
    echo "built_from:        $local_zip"
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
