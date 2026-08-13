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
IOS_ARTIFACTS=""
NOTE=${NOTE:-}

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --donor) DONOR="${2:?}"; shift 2 ;;
    # The FINAL published ios-release/artifacts.zip. Its digest joins the manifest,
    # so the address means "this host cell AND this engine" -- see below.
    --ios-artifacts) IOS_ARTIFACTS="${2:?}"; shift 2 ;;
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

# THE iOS ENGINE JOINS THE IDENTITY.
#
# The seven files above are the HOST compiler cell. They do not cover the iOS
# engine, and an embedder-only change (shell/common/shorebird/shorebird.cc) moves
# the runtime bytes while leaving every one of them byte-identical -- so the mint
# computed the SAME address for a different engine. Measured, not supposed: a
# --dry-run after such a change reproduced 4288817249400e62 exactly.
#
# That made the address claim more than its inputs supported, which is the same
# defect as release 25's stamp claiming artifacts the cache never fetched. So the
# digest of the FINAL PUBLISHED zip participates in the address, and is recorded
# under its own name so provenance can be inspected rather than inferred from the
# aggregate.
#
# The zip bytes, not the unpacked binary and not a directory: a re-zip is not
# byte-identical (mtimes), so the digest must be of the artifact that actually
# ships. This script therefore INSTALLS that exact file rather than re-creating it.
#
# SCOPE, stated so it is not over-read: this closes the iOS ambiguity in front of
# us. An Android-only runtime change would leave the same hole. Either every
# published platform artifact eventually joins the manifest, or this address is
# defined as the Route-B/iOS cell identity. It is currently the latter.
IOS_DIGEST=""
if [[ -n "$IOS_ARTIFACTS" ]]; then
  [[ -f "$IOS_ARTIFACTS" ]] || die "no iOS artifacts zip at $IOS_ARTIFACTS"
  IOS_DIGEST=$(shasum -a 256 "$IOS_ARTIFACTS" | cut -d' ' -f1)
fi

MANIFEST=$(mktemp)
{
  for pair in "${files[@]}"; do
    name=${pair%%:*}; path=${pair#*:}
    [[ -f "$path" ]] || die "missing cell file $name at $path"
    printf '%s %s\n' "$name" "$(shasum -a 256 "$path" | cut -d' ' -f1)"
  done
  [[ -n "$IOS_DIGEST" ]] && printf 'ios_artifacts_sha256 %s\n' "$IOS_DIGEST"
} | sort > "$MANIFEST"

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

# THE EXACT ZIP THAT WAS HASHED, installed rather than regenerated. If these ever
# diverge the address is a lie, so audit_route_b_compiler.sh recomputes this digest
# and requires equality.
if [[ -n "$IOS_ARTIFACTS" ]]; then
  note "installing the hashed iOS artifacts.zip under $REV"
  if [[ "$DRY" != 1 ]]; then
    mkdir -p "$ENGINE_DST/ios-release"
    cp "$IOS_ARTIFACTS" "$ENGINE_DST/ios-release/artifacts.zip"
    got=$(shasum -a 256 "$ENGINE_DST/ios-release/artifacts.zip" | cut -d' ' -f1)
    [[ "$got" == "$IOS_DIGEST" ]] || die \
      "installed iOS artifacts digest $got != hashed $IOS_DIGEST"
    echo "    ios-release/artifacts.zip: ${IOS_DIGEST:0:16} (verified in place)"
  fi
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
  # The digest that DERIVED the address is the one recorded, so audit compares
  # the published zip against the same number the identity was built from.
  ROUTE_B_IOS_ARTIFACTS_SHA256="$IOS_DIGEST" \
    "$HERE/publish_route_b_compiler.sh" --rev "$REV"
fi

echo
echo "--------------------------------------------------"
echo "engine hash: $REV"
echo
echo "TWO PRECONDITIONS BEFORE ANY CLIENT FETCHES THIS HASH. Both were learned by"
echo "breaking them on 2026-08-13, and both fail in the direction that looks like"
echo "success."
echo
echo "1. RELOAD THE MIRROR FIRST, then clear any cache that could hold a fallback."
echo "   This script appends $REV to experimental_hashes.map, so Caddy has NOT read"
echo "   it yet. A client that fetches before the reload is served FALLBACK bytes"
echo "   from the pinned hash, and Caddy CACHES that response under this hash's URL."
echo "   After that, @must_be_local cannot save you: the Caddyfile sets"
echo "   'order cache before respond' on purpose, so a cache HIT beats the 404 that"
echo "   ownership would otherwise return. Restart the cdn container, and clear"
echo "   <flutterDir>/bin/cache/downloads as well, or a poisoned download persists."
echo
echo "2. NEVER ESTABLISH A REVISION BY WRITING CACHE STAMPS. A stamp asserts what"
echo "   the cache ALREADY contains, so writing $REV into it tells Flutter there is"
echo "   nothing to fetch — and the build then consumes the OLD engine while every"
echo "   report says $REV. Delete the state and force consumption instead:"
echo "     rm -rf <flutterDir>/bin/cache/{artifacts,dart-sdk,downloads}"
echo "     rm -f  <flutterDir>/bin/cache/*.stamp"
echo "   then set bin/internal/engine.version to $REV and let the next build fetch."
echo
echo "3. WARM THE CACHE BEFORE THE RELEASE THAT MATTERS. isRouteBEngine reads the"
echo "   ios-release Flutter binary and returns false when it does not EXIST, and"
echo "   after a clear it does not exist until a build fetches it. So the FIRST"
echo "   release after a clear silently takes the non-Route-B path: no patchable"
echo "   calls, no provenance, and a normal success message. Measured on release 33:"
echo "   8 patchable sites against a 100/MB threshold, with the correct engine"
echo "   consumed. Warm it, confirm the binary exists, then cut."
echo "   Verify the CONSUMED bytes afterwards, not the published ones."
echo
echo "Next, in the Flutter checkout that will cut the release:"
echo "  echo $REV > <flutterDir>/bin/internal/engine.version"
echo "  # and export FLUTTER_STORAGE_BASE_URL / SHOREBIRD_STORAGE_BASE_URL at the"
echo "  # mirror, or the fetch goes to Google and this hash does not exist there."
