#!/usr/bin/env bash
# cspell:words dartaotruntime psdk apfs
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
# The ZIP that must DELIVER the dill above, so the address and the download agree.
#
# WHY THIS EXISTS. FLUTTER_PLATFORM participates in the cell ADDRESS. What a
# release app actually compiles dart:ui against is flutter_patched_sdk_product.zip,
# published beside the engine under that same address — and this script's engine
# clone (`cp -Rc`) carried the DONOR's copy forward, forever, without ever
# re-deriving it. The two therefore drifted apart and stayed apart: the address
# certified 9f5a5f75 while every build downloaded R4's 55e02ed8, and every audit
# said CLEAN because nothing compared them. See
# evidence/g15/hooks_delivery_verdict.txt.
#
# So the zip is now INSTALLED into the new cell, and only after its contained dill
# is checked byte-for-byte against FLUTTER_PLATFORM. Same discipline as
# ios_artifacts_sha256 below: install the exact artifact that was hashed, then
# verify it in place, rather than trusting that a clone still means what it meant.
#
# AND THE DEFAULTS NOW DERIVE ONE FROM THE OTHER, 2026-08-25. Keeping them as
# two independent paths meant they could be stale independently, which is what
# happened: the default FLUTTER_PLATFORM pointed at a published_sdk copy from
# 2026-08-09 (9f5a5f75) while the default PSDK_ZIP pointed at a DIFFERENT out
# directory (host_release_arm64_nodm, inner dill 757d09d7) -- and the cell that
# is actually published, 93a3756, carries neither: it carries 099b0313, the dill
# inside THIS out directory's zip. Both defaults were wrong for the live
# lineage, and the only reason nothing shipped incoherent is that the gate below
# refused the mint.
#
# Proof that 099b0313 is the right one, not a third guess: recomputing the
# 7-file manifest with it reproduces the published address 93a3756 exactly.
#
# So PSDK_ZIP defaults to this build's own zip, and FLUTTER_PLATFORM is
# EXTRACTED from it. The address and the download cannot now disagree by
# construction rather than by two paths happening to match.
PSDK_ZIP=${PSDK_ZIP:-$OUT/zip_archives/flutter_patched_sdk_product.zip}
if [[ -z "${FLUTTER_PLATFORM:-}" ]]; then
  if [[ -f "$PSDK_ZIP" ]]; then
    _fp_dir=$(mktemp -d)
    unzip -q -o "$PSDK_ZIP" 'flutter_patched_sdk_product/platform_strong.dill' \
      -d "$_fp_dir" \
      || { echo "ERROR: $PSDK_ZIP carries no platform_strong.dill" >&2; exit 1; }
    FLUTTER_PLATFORM="$_fp_dir/flutter_patched_sdk_product/platform_strong.dill"
  else
    echo "ERROR: no platform-sdk zip at $PSDK_ZIP" >&2; exit 1
  fi
fi
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SELFHOST="$(cd "$HERE/../.." >/dev/null 2>&1 && pwd)"
# The bundle name bundle_diff_comment reads. It was only ever defined in
# publish_route_b_compiler.sh, which runs as a CHILD process, so under `set -u`
# the deferred map append died with "PLAT: unbound variable" -- after publishing,
# and after writing the ancestry half of the comment. The visible symptom was a
# map with a truncated comment block and NO mapping line, so Caddy would not
# serve the freshly published hash at all. Same default as publish's.
PLAT=${PLAT:-darwin-arm64}
OVERLAY=${OVERLAY:-$SELFHOST/cdn/overlay}
MAP=${MAP:-$SELFHOST/cdn/experimental_hashes.map}
DONOR=""
DRY=0
IOS_ARTIFACTS=""
NOTE=${NOTE:-}

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

# provenance_comment <donorHash> <donorDir> <cellDir> [iosDigest] [note]
#
# Emits the map's comment block for a cell. Two claims live in it and they have
# DIFFERENT sources, which is the whole point of this function existing:
#
#   ADDRESS   -- which digests participate in the cell's identity. Genuinely a
#                property of the INPUTS, so it is driven by --ios-artifacts.
#   ANCESTRY  -- which artifacts this cell actually inherited from its donor.
#                A property of the RESULT, so it is MEASURED, by digesting the
#                installed cell against the donor file by file.
#
# WHY MEASURED, AND WHY THIS IS NOT A STYLE CHOICE. The old sentence inferred
# ancestry from the address inputs: it branched on --ios-artifacts alone and, on
# that basis, asserted "Donor X supplied every OTHER engine artifact". That
# sentence is FALSE whenever anything else was substituted -- and something else
# routinely is, because PSDK_ZIP installs a platform dill over the clone a few
# lines below. It was false for cd137db6 (dill 757d09d7… against the donor's
# 9f5a5f75…, corrected by hand in 064115f9) and it is understated on 87130ae8
# for the same reason. An inference from one flag can only ever describe that
# one flag; the map's entire job is to say what a hash CONTAINS, so the sentence
# has to come from the bytes. Measuring also makes the claim true for
# substitution paths nobody has written yet.
#
# The comparison runs after every install below and before the map append, so
# what it describes is the cell a consumer will actually download.
# bundle_diff_comment <donorHash> <cellHash> <overlayRoot>
#
# The seven CELL files, this cell against the donor's, measured from the
# PUBLISHED bundles rather than from the build directory -- so it describes what
# a consumer downloads. This is the half `provenance_comment` structurally
# cannot see: it compares engine artifact dirs, and the compiler bundle is a zip
# somewhere else entirely.
bundle_diff_comment() {
  local donor=$1 cell=$2 root=$3
  local a b dz cz rel ah bh
  dz="$root/download.shorebird.dev/shorebird/$donor/route-b-compiler-$PLAT.zip"
  cz="$root/download.shorebird.dev/shorebird/$cell/route-b-compiler-$PLAT.zip"
  if [[ ! -f "$dz" || ! -f "$cz" ]]; then
    echo "# CELL FILES: not compared -- one of the two bundles is absent."
    return 0
  fi
  a=$(mktemp -d); b=$(mktemp -d)
  (cd "$a" && unzip -o -q "$dz") ; (cd "$b" && unzip -o -q "$cz")
  echo "# CELL FILES, measured from the PUBLISHED bundles (what a consumer gets):"
  while IFS= read -r rel; do
    ah=$( [[ -f "$a/$rel" ]] && shasum -a 256 "$a/$rel" | cut -c1-16 || echo "absent" )
    bh=$(shasum -a 256 "$b/$rel" | cut -c1-16)
    if [[ "$ah" == "$bh" ]]; then
      echo "#   same    $rel  $bh"
    else
      echo "#   CHANGED $rel  $ah -> $bh"
    fi
  done < <(cd "$b" && find . -type f | sed 's|^\./||' | sort)
  rm -rf "$a" "$b"
}

provenance_comment() {
  local donor=$1 donor_dir=$2 cell_dir=$3 ios_digest=${4:-} note_text=${5:-}
  local rel ch dh entry
  local -a changed=() added=() removed=()
  local same=0 total=0

  while IFS= read -r rel; do
    total=$((total + 1))
    if [[ ! -f "$donor_dir/$rel" ]]; then
      added+=("$rel"); continue
    fi
    ch=$(shasum -a 256 "$cell_dir/$rel" | cut -d' ' -f1)
    dh=$(shasum -a 256 "$donor_dir/$rel" | cut -d' ' -f1)
    if [[ "$ch" == "$dh" ]]; then
      same=$((same + 1))
    else
      changed+=("$rel|$ch|$dh")
    fi
  done < <(cd "$cell_dir" && find . -type f | sed 's|^\./||' | sort)

  while IFS= read -r rel; do
    [[ -f "$cell_dir/$rel" ]] || removed+=("$rel")
  done < <(cd "$donor_dir" && find . -type f | sed 's|^\./||' | sort)

  local n_diff=$(( ${#changed[@]} + ${#added[@]} + ${#removed[@]} ))

  echo "# Route B compiler cell, minted $(date -u +%Y-%m-%d) from the cell"
  echo "# manifest (see mint_route_b_cell.sh)."
  if (( n_diff == 0 )); then
    # SAY WHICH DIRECTORY WAS MEASURED. This compares the ENGINE artifact dir,
    # and the engine dir happens to hold about seven files -- so "all 7
    # artifacts identical" read as if it covered the CELL's seven files, which
    # are the ones the map exists to describe and the ones a tooling-only mint
    # changes. Corrected 2026-08-25 after this sentence was emitted for a cell
    # whose whole purpose was two changed host artifacts. Same failure the
    # header above describes, one level up: a measurement of one directory,
    # worded as if it covered the whole cell.
    echo "# ANCESTRY, MEASURED against donor $donor at mint time:"
    echo "# all $total ENGINE artifacts identical, cloned byte-for-byte."
    echo "# (This says nothing about the seven CELL files -- see the bundle"
    echo "#  comparison below, which is where a tooling-only change shows up.)"
  else
    echo "# ANCESTRY, MEASURED against donor $donor at mint time —"
    echo "# $n_diff of $total artifacts differ:"
    if (( ${#changed[@]} )); then
      for entry in "${changed[@]}"; do
        IFS='|' read -r rel ch dh <<<"$entry"
        printf '#   CHANGED %s — sha256 %s (donor %s)\n' "$rel" "$ch" "$dh"
      done
    fi
    if (( ${#added[@]} )); then
      for rel in "${added[@]}"; do
        printf '#   ADDED   %s — the donor has no such artifact\n' "$rel"
      done
    fi
    if (( ${#removed[@]} )); then
      for rel in "${removed[@]}"; do
        printf '#   ABSENT  %s — present in the donor, NOT here\n' "$rel"
      done
    fi
    if (( same > 0 )); then
      echo "# Donor $donor supplied the other $same, byte-for-byte."
    else
      echo "# Donor $donor supplied NO artifact unchanged."
    fi
  fi
  if [[ -n "$ios_digest" ]]; then
    echo "# ADDRESS: iOS artifacts sha256 $ios_digest"
    echo "# participates in this cell's address (--ios-artifacts)."
  fi
  if [[ -n "$note_text" ]]; then
    echo "#"
    printf '# %s\n' "$note_text"
  fi
}

# Sourcing for test: define the functions above and stop, so the regression probe
# exercises THE PRODUCT'S OWN generator rather than a copy of it. A copy would go
# on passing after this script changed, which is the false-green shape this repo
# has now named five times.
if [[ -n "${MINT_CELL_LIB_ONLY:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

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
  # P4.1: profile-schema knowledge belongs to the compiler that emitted
  # the profile, so the probe is addressed with the rest of the cell.
  "route_b_release_probe.aot:$OUT/zip_archives/route_b_release_probe.aot"
  "flutter_platform_strong.dill:$FLUTTER_PLATFORM"
)

# THE iOS ENGINE JOINS THE IDENTITY.
#
# The eight files above are the HOST compiler cell. They do not cover the iOS
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
  # `if`, not `[[ ... ]] && ...`: as a bare statement the latter returns 1 when
  # the test is false, and under `set -e` that killed the whole script -- so a
  # mint WITHOUT --ios-artifacts (the tooling-only case, which is the common one
  # when only the compiler cell changes) exited 1 with no message at all. Found
  # 2026-08-25 while minting a cell that changes two host artifacts and no engine
  # bytes.
  if [[ -n "$IOS_DIGEST" ]]; then
    printf 'ios_artifacts_sha256 %s\n' "$IOS_DIGEST"
  fi
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

# RE-DERIVE THE ENGINE STAMP. The clone above copies the donor's
# `engine_stamp.json` verbatim, and nothing ever rewrote it -- so a cell minted
# this way SHIPPED A STAMP CLAIMING TO BE ITS DONOR. Found 2026-08-25 on cell
# 93a3756, whose stamp said 2c4443ce; `flutter.version.json` derives from it, and
# the release then baked FLUTTER_ENGINE_REVISION=2c4443cedd into its injected
# defines while `route_b.json` correctly recorded the new hash. Same drift class
# as the platform dill a few lines below, one directory over -- and it went
# unnoticed because engine_stamp.json is NOT part of the cell address, so no
# digest gate could see it.
#
# Note what this does NOT do: it does not retro-fix an already-published cell.
# A cell is immutable per engine hash (publish_route_b_compiler.sh says why), so
# a published stamp stays as it is and the next mint is correct.
if [[ "$DRY" != 1 && -f "$ENGINE_DST/engine_stamp.json" ]]; then
  note "re-deriving engine_stamp.json for $REV"
  python3 - "$ENGINE_DST/engine_stamp.json" "$REV" <<'STAMP'
import json, sys
path, rev = sys.argv[1], sys.argv[2]
d = json.load(open(path))
was = d.get('git_revision', '')
if was != rev:
    d['git_revision'] = rev
    json.dump(d, open(path, 'w'))
    print(f"    git_revision {was[:10]} -> {rev[:10]}")
else:
    print("    git_revision already correct")
STAMP
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

# THE PLATFORM DILL THE ADDRESS WAS COMPUTED OVER, installed so a build downloads
# the same bytes. Verified before AND after, because a clone that silently means
# something else is exactly the defect this closes.
if [[ -n "$PSDK_ZIP" ]]; then
  [[ -f "$PSDK_ZIP" ]] || die "no platform-sdk zip at $PSDK_ZIP"
  PW=$(mktemp -d)
  unzip -q -o "$PSDK_ZIP" 'flutter_patched_sdk_product/platform_strong.dill' -d "$PW" \
    || die "$PSDK_ZIP carries no flutter_patched_sdk_product/platform_strong.dill"
  zip_dill=$(shasum -a 256 "$PW/flutter_patched_sdk_product/platform_strong.dill" | cut -d' ' -f1)
  want_dill=$(shasum -a 256 "$FLUTTER_PLATFORM" | cut -d' ' -f1)
  rm -rf "$PW"
  [[ "$zip_dill" == "$want_dill" ]] || die \
    "platform dill MISMATCH — the address would certify a dill the build never gets.
    address computed over : ${want_dill:0:16}…  ($FLUTTER_PLATFORM)
    zip would deliver     : ${zip_dill:0:16}…  ($PSDK_ZIP)"
  note "installing the addressed platform dill under $REV"
  if [[ "$DRY" != 1 ]]; then
    cp "$PSDK_ZIP" "$ENGINE_DST/flutter_patched_sdk_product.zip"
    echo "    flutter_patched_sdk_product.zip: dill ${want_dill:0:16} (verified in place)"
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
  # The ancestry sentence is MEASURED from the installed cell (see
  # provenance_comment). A dry run never creates that cell, so there is nothing
  # truthful to preview and the block is deliberately not guessed at.
  if [[ "$DRY" == 1 ]]; then
    note "map entry not previewed: ancestry is measured from the installed cell,"
    note "which --dry-run does not create"
  else
    # DEFERRED UNTIL AFTER PUBLISHING. The comment now includes a comparison of
    # the PUBLISHED cell bundles, and that bundle does not exist yet at this
    # point -- appending here could only ever describe the engine half, which is
    # exactly the half that does not change in a tooling-only mint.
    MAP_PENDING=1
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

if [[ "${MAP_PENDING:-0}" == 1 ]]; then
  note "recording ancestry in $(basename "$MAP")"
  {
    echo
    provenance_comment "$DONOR" "$ENGINE_SRC" "$ENGINE_DST" "$IOS_DIGEST" "$NOTE"
    bundle_diff_comment "$DONOR" "$REV" "$OVERLAY"
    echo "$REV $FALLBACK"
  } >> "$MAP"
fi

echo
echo "--------------------------------------------------"
echo "engine hash: $REV"
echo
echo "TWO PRECONDITIONS BEFORE ANY CLIENT FETCHES THIS HASH. Both were learned by"
echo "breaking them on 2026-08-13, and both fail in the direction that looks like"
echo "success."
echo
echo "1. PROVE THE CONSUMER PATH SERVES THIS CELL, by digest, before anything"
echo "   consumes it. Run:"
echo
echo "     verify_cell_delivery.sh --hash $REV"
echo
echo "   THE INVARIANT IS THE DIGEST, NOT A RELOAD. Before any release or client"
echo "   may consume a newly published cell, the exact hash URL through the real"
echo "   consumer path must return bytes matching the published cell manifest."
echo "   That is stronger than either \"reload first\" or \"no reload needed\":"
echo "   whether this deployment rereads experimental_hashes.map per request or"
echo "   at startup is a property of how it happens to be configured, and was"
echo "   measured to differ between deployments on 2026-08-25. A reload is a"
echo "   deployment-specific REMEDIATION for a mismatch, not the invariant."
echo
echo "   AND A 200 IS NOT THE PROOF. The failure this closes serves a perfectly"
echo "   valid response containing the WRONG cell: the mapping is not live, the"
echo "   mirror falls back to the pinned hash, and Caddy CACHES that under this"
echo "   hash URL. After that @must_be_local cannot save you -- the Caddyfile"
echo "   sets 'order cache before respond' on purpose, so a cache HIT beats the"
echo "   404 ownership would otherwise return. The check therefore compares the"
echo "   delivered digest against the published one AND against the donor's, so"
echo "   fallback bytes are named as fallback rather than reported as absent."
echo "   On a mismatch: reload or reconcile the serving config, clear the cache,"
echo "   clear <flutterDir>/bin/cache/downloads, and re-verify."
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
