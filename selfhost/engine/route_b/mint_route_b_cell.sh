#!/usr/bin/env bash
# cspell:words dartaotruntime
#
# mint_route_b_cell.sh -- give a changed compiler cell its own engine hash.
#
# The cell is immutable per engine hash (publish_route_b_compiler.sh explains
# why), so every change to any of its seven files needs a new hash -- even when
# the engine BINARY is byte-identical, which it usually is. This has now been
# done three times by hand, and twice it cost time on the same two rig facts.
#
# THE ADDRESS IS THE WHOLE CELL. `54fb8772…` was addressed on the one file that
# happened to change, `dart2bytecode.aot`, which stops being well-defined as
# soon as a different file changes -- as it did when the coverage analyzer went
# to v3. From here the hash is the first 40 hex of sha256 over the cell's own
# manifest: `<name> <sha256>` for each file, sorted. It changes if and only if
# some file changes, and it does not pretend the engine moved.
#
# What this does NOT do: cut a release. Pointing a Flutter checkout at the new
# hash (bin/internal/engine.version, plus the cache stamps) belongs to whoever
# is building, because it mutates their checkout.
#
#   mint_route_b_cell.sh --donor <engineHash> [--dry-run]
#
# donor is the hash whose ENGINE artifacts the new hash reuses: the binary is
# unchanged, so its ios-release, dart-sdk, sky_engine and the rest are cloned
# rather than rebuilt.
set -euo pipefail

SRC=${SRC:-/Volumes/build/route-b/flutter/engine/src}
OUT=${OUT:-$SRC/out/host_release_arm64}
FLUTTER_PLATFORM=${FLUTTER_PLATFORM:-/Volumes/build/route-b/published_sdk/flutter_patched_sdk_product/platform_strong.dill}
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SELFHOST="$(cd "$HERE/../.." >/dev/null 2>&1 && pwd)"
OVERLAY=${OVERLAY:-$SELFHOST/cdn/overlay}
MAP=${MAP:-$SELFHOST/cdn/experimental_hashes.map}
DONOR=""
DRY=0
NOTE=${NOTE:-}

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --donor) DONOR="${2:?}"; shift 2 ;;
    --note) NOTE="${2:?}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '3,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$DONOR" ]] || die "--donor <engineHash> is required"

# The same seven files publish_route_b_compiler.sh stages, named as they are
# named inside the zip -- so the address is over what a consumer receives, not
# over build-tree paths that mean nothing to it.
files=(
  "dart2bytecode.aot:$OUT/zip_archives/dart2bytecode_aot.snapshot"
  "dartaotruntime:$OUT/dartaotruntime"
  "vm_platform.dill:$OUT/vm_platform.dill"
  "route_b_analyze.aot:$OUT/zip_archives/route_b_analyze.aot"
  "route_b_gen_kernel.aot:$OUT/zip_archives/route_b_gen_kernel.aot"
  "route_b_gen_dynamic_interface.aot:$OUT/zip_archives/route_b_gen_dynamic_interface.aot"
  "flutter_platform_strong.dill:$FLUTTER_PLATFORM"
)

MANIFEST=$(mktemp)
for pair in "${files[@]}"; do
  name=${pair%%:*}; path=${pair#*:}
  [[ -f "$path" ]] || die "missing cell file $name at $path"
  printf '%s %s\n' "$name" "$(shasum -a 256 "$path" | cut -d' ' -f1)"
done | sort > "$MANIFEST"

REV=$(shasum -a 256 "$MANIFEST" | cut -c1-40)
note "cell manifest"
sed 's/^/    /' "$MANIFEST"
echo
note "cell address: $REV"

ENGINE_SRC="$OVERLAY/flutter_infra_release/flutter/$DONOR"
ENGINE_DST="$OVERLAY/flutter_infra_release/flutter/$REV"
[[ -d "$ENGINE_SRC" ]] || die "no donor engine artifacts at $ENGINE_SRC"

if [[ -d "$ENGINE_DST" ]]; then
  note "engine artifacts already present for $REV"
else
  # `@must_be_local` 404s rather than falling back, so a mapped hash must own
  # every artifact a build asks for. cp -Rc is an APFS clone: ~205 MB that costs
  # no disk and is byte-identical, which is what makes reusing the donor's
  # engine honest rather than approximate.
  note "cloning engine artifacts from $DONOR (APFS clone, ~0 bytes)"
  [[ "$DRY" == 1 ]] || cp -Rc "$ENGINE_SRC" "$ENGINE_DST"
fi

# The bidiff tool is engine-hash-scoped too, and a patch cannot be built
# without it. Missing it fails late, at the diff step, long after the release.
SB_SRC="$OVERLAY/download.shorebird.dev/shorebird/$DONOR"
SB_DST="$OVERLAY/download.shorebird.dev/shorebird/$REV"
mkdir -p "$SB_DST"
for tool in "$SB_SRC"/patch-*.zip; do
  [[ -f "$tool" ]] || continue
  base=$(basename "$tool")
  if [[ -f "$SB_DST/$base" ]]; then
    note "$base already present for $REV"
  else
    note "cloning $base from $DONOR"
    [[ "$DRY" == 1 ]] || cp -c "$tool" "$SB_DST/$base"
  fi
done

if grep -q "^$REV " "$MAP" 2>/dev/null; then
  note "map entry already present"
else
  FALLBACK=$(sed -nE "s/^$DONOR ([0-9a-f]{40}).*/\1/p" "$MAP" | head -1)
  [[ -n "$FALLBACK" ]] || die "donor $DONOR has no map entry to copy a fallback from"
  note "mapping $REV -> $FALLBACK"
  if [[ "$DRY" != 1 ]]; then
    {
      echo
      echo "# Route B compiler cell, minted $(date -u +%Y-%m-%d) from the cell"
      echo "# manifest (see mint_route_b_cell.sh). Engine binary is $DONOR's,"
      echo "# cloned byte-for-byte; only the CELL differs."
      [[ -n "$NOTE" ]] && echo "#"
      [[ -n "$NOTE" ]] && printf '# %s\n' "$NOTE"
      echo "$REV $FALLBACK"
    } >> "$MAP"
  fi
fi

note "publishing the cell"
if [[ "$DRY" == 1 ]]; then
  echo "    (dry run) publish_route_b_compiler.sh --rev $REV"
else
  "$HERE/publish_route_b_compiler.sh" --rev "$REV"
fi

echo
echo "--------------------------------------------------"
echo "engine hash: $REV"
echo
echo "Next, in the Flutter checkout that will cut the release:"
echo "  echo $REV > <flutterDir>/bin/internal/engine.version"
echo "  restamp bin/cache/{engine,ios-sdk,engine-dart-sdk}.stamp to $REV"
echo "and reload the CDN so Caddy picks up the new map entry."
