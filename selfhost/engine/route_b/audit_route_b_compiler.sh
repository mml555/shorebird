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
# So this proves the CONTENTS. Six checks, and AUDIT CLEAN means the cell can be
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
         route_b_gen_dynamic_interface.aot; do
  [[ -f "$W/$f" ]] && ok "contains $f" || fail "missing $f"
done

# 3. Extracted hashes match what provenance claims. This is the check that makes
#    the cell reconstructible rather than merely present: a bundle whose bytes
#    drifted from its own record cannot be reasoned about later.
recorded() { sed -nE "s/^$1[[:space:]]*:[[:space:]]*([0-9a-f]{64}).*/\1/p" "$PROV" | head -1; }
for f in dart2bytecode.aot dartaotruntime vm_platform.dill route_b_analyze.aot \
         route_b_gen_kernel.aot flutter_platform_strong.dill \
         route_b_gen_dynamic_interface.aot; do
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
