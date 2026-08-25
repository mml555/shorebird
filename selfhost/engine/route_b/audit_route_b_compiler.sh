#!/usr/bin/env bash
# cspell:words dartaotruntime dynmod SBRBPTCH
#
# audit_route_b_compiler.sh -- is the published Route B compiler cell actually
# RECONSTRUCTIBLE, or merely present?
#
# `audit_overlay.sh` answers "do we own this path". That is necessary and not
# sufficient here: this artifact is three version-locked files, and every way it
# can be wrong is invisible from the outside.
#
#   * a zip that exists but whose contents drifted from PROVENANCE.txt
#   * a runtime and a snapshot from different trees, which either refuse to
#     start or -- far worse -- run and emit bytecode that fails to bind on
#     device, long after the CLI reported success
#   * a platform dill that is not the one the release was compiled against
#   * a dart revision that does not match the engine cell
#
# THE THIRD BULLET WAS NAMED HERE AND NOT ACTUALLY CHECKED, for as long as this
# script has existed. Check 3 compared flutter_platform_strong.dill only against
# the bundle's OWN PROVENANCE.txt -- self-consistency, not agreement with what a
# build downloads. Measured 2026-08-14: every published cell serves a
# flutter_patched_sdk_product.zip whose platform_strong.dill is 55e02ed8 with
# `attachBytecodeToFunction` x0, while the dill that COMPUTED those same cell
# addresses is 9f5a5f75 with x8. The address certified one dill for months while
# the download delivered another, and this audit said CLEAN throughout. Check 4b
# below is that missing comparison; see evidence/g15/hooks_delivery_verdict.txt.
#
# So this proves the CONTENTS. Seven checks, and AUDIT CLEAN means the cell can be
# rebuilt and would produce the same compiler -- not that a file is there.
#
#   audit_route_b_compiler.sh --hash <engineRevision> [--dart-rev <sha>]
#
# Exit codes: 0 clean · 1 findings · 2 usage/environment error
set -uo pipefail

OVERLAY=${OVERLAY:-/Users/mendell/shorebird/selfhost/cdn/overlay}
BUCKET=${BUCKET:-download.shorebird.dev}
PLAT=${PLAT:-darwin-arm64}
HASH=""
EXPECT_DART_REV=""

usage() { sed -n '3,22p' "${BASH_SOURCE[0]}"; exit 2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hash) HASH="${2:?}"; shift 2 ;;
    --dart-rev) EXPECT_DART_REV="${2:?}"; shift 2 ;;
    --overlay) OVERLAY="${2:?}"; shift 2 ;;
    --plat) PLAT="${2:?}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
[[ -n "$HASH" ]] || usage

findings=0
fail() { echo "  FINDING: $*"; findings=$((findings + 1)); }
ok()   { echo "  ok      $*"; }

ZIP="$OVERLAY/$BUCKET/shorebird/$HASH/route-b-compiler-$PLAT.zip"
echo "Route B compiler cell audit"
echo "  engine : $HASH"
echo "  bundle : $ZIP"
echo

# 1. Present at all.
if [[ ! -f "$ZIP" ]]; then
  echo "  FINDING: no bundle published for this engine hash"
  echo
  echo "AUDIT FINDINGS: 1"
  echo "Route B patches cannot be produced for this engine until"
  echo "engine/route_b/publish_route_b_compiler.sh --rev $HASH has run."
  exit 1
fi
ok "bundle exists ($(du -h "$ZIP" | cut -f1))"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
unzip -q "$ZIP" -d "$W" || { echo "  FINDING: bundle does not unzip"; exit 1; }

PROV="$W/PROVENANCE.txt"
[[ -f "$PROV" ]] || { fail "bundle carries no PROVENANCE.txt"; echo; echo "AUDIT FINDINGS: $findings"; exit 1; }

# 2. All three files present. A partial bundle is the failure mode the single
#    artifact exists to prevent, so check it explicitly rather than assuming.
for f in dartaotruntime dart2bytecode.aot vm_platform.dill route_b_analyze.aot \
         route_b_gen_kernel.aot flutter_platform_strong.dill \
         route_b_gen_dynamic_interface.aot route_b_release_probe.aot; do
  [[ -f "$W/$f" ]] && ok "contains $f" || fail "missing $f"
done

# 3. Extracted hashes match what provenance claims. This is the check that makes
#    the cell reconstructible rather than merely present: a bundle whose bytes
#    drifted from its own record cannot be reasoned about later.
recorded() { sed -nE "s/^$1[[:space:]]*:[[:space:]]*([0-9a-f]{64}).*/\1/p" "$PROV" | head -1; }
for f in dart2bytecode.aot dartaotruntime vm_platform.dill route_b_analyze.aot \
         route_b_gen_kernel.aot flutter_platform_strong.dill \
         route_b_gen_dynamic_interface.aot route_b_release_probe.aot; do
  [[ -f "$W/$f" ]] || continue
  want=$(recorded "$f")
  got=$(shasum -a 256 "$W/$f" | cut -d' ' -f1)
  if [[ -z "$want" ]]; then
    fail "$f has no recorded hash in PROVENANCE.txt"
  elif [[ "$want" != "$got" ]]; then
    fail "$f hash drifted (recorded ${want:0:16}…, actual ${got:0:16}…)"
  else
    ok "$f matches its recorded hash"
  fi
done

# 4. The engine revision recorded inside the bundle is the one it is filed
#    under. A bundle copied between hashes would otherwise pass everything else.
FILED=$(sed -nE 's/^engine revision[[:space:]]*:[[:space:]]*([0-9a-f]+).*/\1/p' "$PROV" | head -1)
if [[ "$FILED" == "$HASH" ]]; then
  ok "records the engine revision it is filed under"
else
  fail "records engine ${FILED:-<none>} but is published under $HASH"
fi

# THE iOS ENGINE DIGEST, recomputed rather than trusted.
#
# mint_route_b_cell.sh puts ios_artifacts_sha256 into the manifest that derives the
# address, so if the published zip and that digest ever diverge the address is
# claiming an engine it does not have -- exactly the defect that let an
# embedder-only change reuse address 4288817249400e62. A manifest entry nobody
# recomputes is decoration.
#
# Absent for addresses minted before this existed (442860e6, 4288817..., and
# earlier). Those keep their original semantics -- host cell only -- and are not
# retrofitted: they are historical evidence now. So a missing entry is reported and
# is NOT a failure.
IOS_ZIP="$OVERLAY/flutter_infra_release/flutter/$HASH/ios-release/artifacts.zip"
IOS_WANT=$(sed -n 's/^ios_artifacts_sha256 *: *//p' "$PROV" | head -1)
if [[ -z "$IOS_WANT" ]]; then
  echo "  --      no ios_artifacts_sha256 recorded (pre-dates iOS-in-address; host-cell identity only)"
elif [[ ! -f "$IOS_ZIP" ]]; then
  fail "records ios_artifacts_sha256 but no published ios-release/artifacts.zip"
else
  IOS_GOT=$(shasum -a 256 "$IOS_ZIP" | cut -d' ' -f1)
  if [[ "$IOS_GOT" == "$IOS_WANT" ]]; then
    ok "published ios-release/artifacts.zip matches ios_artifacts_sha256"
  else
    fail "ios artifacts drifted (recorded ${IOS_WANT:0:16}…, actual ${IOS_GOT:0:16}…)"
  fi
fi

# 4b. THE DILL THE ADDRESS CERTIFIES MUST BE THE DILL A BUILD DOWNLOADS.
#
# `flutter_platform_strong.dill` is one of the seven files that COMPUTE the cell
# address (mint_route_b_cell.sh:31,68). Separately, an app's release kernel is
# compiled against `flutter_patched_sdk_product/platform_strong.dill`, taken from
# the zip published beside the engine under that same address --
# artifacts.dart:757 and :1323 select the `_product` variant for BuildMode.release.
# Nothing held those two in agreement, and they are not in agreement: the mint
# APFS-clones the donor cell's copy (mint_route_b_cell.sh:127) and the original
# came from publish_ios_overlay.sh's HOST_REL default, which points at a DIFFERENT
# TREE (R4's out/host_release_arm64_nodm) from the one the iOS engine is built in.
#
# Consequence, and it is why this is a FINDING and not a note: a dart:ui or
# dart:_internal change made in the tree that owns the engine does not reach any
# app built against the cell, while every audit reports CLEAN. That is the same
# shape as sky_engine serving stock Dart-SDK patch sources under self-hosted
# hashes -- one level further down, in the artifact that every release consumes.
#
# THIS CHECK IS EXPECTED TO FIRE ON EVERY CELL MINTED BEFORE THE PUBLICATION
# REPAIR. That is the point: it converts a silent divergence into a loud one. Do
# not suppress it to restore a green line.
PSDK_ZIP="$OVERLAY/flutter_infra_release/flutter/$HASH/flutter_patched_sdk_product.zip"
CELL_DILL="$W/flutter_platform_strong.dill"
if [[ ! -f "$CELL_DILL" ]]; then
  echo "  --      no flutter_platform_strong.dill in the bundle to compare against"
elif [[ ! -f "$PSDK_ZIP" ]]; then
  fail "no published flutter_patched_sdk_product.zip -- release builds fall through to STOCK"
else
  PD=$(mktemp -d)
  if unzip -q -o "$PSDK_ZIP" 'flutter_patched_sdk_product/platform_strong.dill' \
       -d "$PD" 2>/dev/null &&
     [[ -f "$PD/flutter_patched_sdk_product/platform_strong.dill" ]]; then
    SERVED=$(shasum -a 256 "$PD/flutter_patched_sdk_product/platform_strong.dill" |
             cut -d' ' -f1)
    CELLD=$(shasum -a 256 "$CELL_DILL" | cut -d' ' -f1)
    if [[ "$SERVED" == "$CELLD" ]]; then
      ok "served platform dill is the one the address was computed over"
    else
      fail "PLATFORM DILL SPLIT: address computed over ${CELLD:0:16}…, builds download ${SERVED:0:16}… — a dart:ui/dart:_internal change in the engine's tree does NOT reach apps built on this cell"
    fi
  else
    fail "published flutter_patched_sdk_product.zip carries no platform_strong.dill"
  fi
  rm -rf "$PD"
fi

# 5. Dart revision matches the cell, when the caller knows what to expect.
DART_REV=$(sed -nE 's/^dart revision[[:space:]]*:[[:space:]]*([0-9a-f]+).*/\1/p' "$PROV" | head -1)
if [[ -z "$DART_REV" ]]; then
  fail "no dart revision recorded"
elif [[ -n "$EXPECT_DART_REV" && "$DART_REV" != "$EXPECT_DART_REV" ]]; then
  fail "dart revision $DART_REV does not match the cell's $EXPECT_DART_REV"
else
  ok "dart revision recorded ($DART_REV)"
fi

# 6. The pair actually WORKS, from the extracted form the CLI will see. Every
#    check above compares bytes to records; only this one proves the thing runs.
if [[ -f "$W/dartaotruntime" && -f "$W/dart2bytecode.aot" ]]; then
  chmod +x "$W/dartaotruntime" 2>/dev/null
  probe=$("$W/dartaotruntime" "$W/dart2bytecode.aot" --help 2>&1)
  if grep -q 'Compiles Dart sources to Dart bytecode' <<<"$probe"; then
    if grep -q 'flutter' <<<"$probe"; then
      ok "capability probe: runs and advertises --target flutter"
    else
      fail "runs but does not advertise --target flutter"
    fi
  else
    fail "runtime/snapshot pair does not run as dart2bytecode"
  fi
fi

echo
if [[ "$findings" -eq 0 ]]; then
  echo "AUDIT CLEAN — this compiler cell is reconstructible"
  exit 0
fi
echo "AUDIT FINDINGS: $findings"
echo
echo "Treat these as corruption or a bad cache, NOT as a reason to cut a new"
echo "release: the release is fine, the published tooling is not."
exit 1
