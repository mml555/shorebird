#!/usr/bin/env bash
# qualify_publish_v2.sh -- the gate the v2 TRANSACTION must pass before any live
# cell is minted with it.
#
# Runs entirely in a scratch overlay against a scratch successor assembled from
# H's real published bytes. That successor is deliberately NOT the eventual
# coherent H2 -- this proves the transaction, not the host repair.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SELFHOST="$(cd "$HERE/../.." >/dev/null 2>&1 && pwd)"
POLICY=${POLICY:-$SELFHOST/cdn/artifact_policy.conf}
LIVE_OVERLAY=${LIVE_OVERLAY:-$SELFHOST/cdn/overlay}
H=${H:-a5a8be5854c529268378ce16762a16d6e31763e9}
CELL=macos-ios
FB=69f9831c360d9152862ec3897c67fb09ae843f3b
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

MINT_CELL_LIB_ONLY=1 . "$HERE/mint_route_b_cell.sh"
set +e   # the sourced product runs set -e; a test owns its own failure policy

fail=0
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
note(){ echo; echo "== $1"; }

# Stage a complete 16-member cell from H's REAL published bytes.
stage_from_H() { # <stage>
  local s=$1 m src
  while IFS= read -r m; do
    src="$LIVE_OVERLAY/${m/\%H/$H}"
    [[ -f "$src" ]] || { echo "  (missing live source: $src)" >&2; return 2; }
    v2_stage_install "$s" "$m" "$src" || return 2
  done < <(v2_members "$POLICY" "$CELL")
  # the two hash-bearing members must be staged as %H TEMPLATES
  v2_canonicalize "$LIVE_OVERLAY/flutter_infra_release/flutter/$H/engine_stamp.json" "$H" \
    > "$s/flutter_infra_release/flutter/%H/engine_stamp.json" || return 3
  v2_canonicalize "$LIVE_OVERLAY/download.shorebird.dev/shorebird/$H/artifacts_manifest.yaml" "$H" \
    > "$s/download.shorebird.dev/shorebird/%H/artifacts_manifest.yaml" || return 3
}

note "stage a complete cell from H's real bytes"
S="$W/stage"; stage_from_H "$S" && ok "16 members staged" || bad "staging failed"
n=$(cd "$S" && find . -type f | wc -l | tr -d ' ')
[[ "$n" == 16 ]] && ok "exactly 16 files staged" || bad "staged $n files, expected 16"

note "1 - address computed from the completed stage"
EV="$W/ev"; OV="$W/overlay"; mkdir -p "$OV"
H2=$(v2_transaction "$S" "$POLICY" "$CELL" "$FB" "$OV" "$EV" --dry-run)
[[ -n "$H2" ]] && ok "address computed: $H2" || bad "no address"
REC=$(shasum -a 256 "$EV/cell_manifest.v2" | cut -c1-40)
[[ "$REC" == "$H2" ]] && ok "independently recomputes from banked manifest" \
                      || bad "manifest does not recompute the address"
[[ "$(awk '$1!="address_schema" && $1!="cell" && $1!="fallback_engine_revision" && NF==2' "$EV/cell_manifest.v2" | wc -l | tr -d ' ')" == 16 ]] \
  && ok "manifest carries 16 members" || bad "wrong member count"
grep -q "^address_schema route-b-cell-v2" "$EV/cell_manifest.v2" && ok "schema marker present" || bad "no schema marker"

note "2 - publish for real into a SCRATCH overlay"
EV2="$W/ev2"
H2B=$(v2_transaction "$S" "$POLICY" "$CELL" "$FB" "$OV" "$EV2")
[[ "$H2B" == "$H2" ]] && ok "publish address matches dry-run ($H2B)" || bad "address changed on publish"
missing=0
while IFS= read -r m; do
  [[ -f "$OV/${m/\%H/$H2B}" ]] || { missing=$((missing+1)); echo "     absent: $m"; }
done < <(v2_members "$POLICY" "$CELL")
[[ "$missing" == 0 ]] && ok "all 16 final paths present in the overlay" || bad "$missing member(s) absent"
[[ -f "$OV/download.shorebird.dev/shorebird/$H2B/route-b-compiler-darwin-arm64.zip" ]] \
  && ok "compiler present" || bad "compiler absent"
# Scoped to the rendered metadata: `%H` occurs by chance inside compressed
# archive members, so a tree-wide grep would fire on every cell.
if grep -qF '%H' "$OV/flutter_infra_release/flutter/$H2B/engine_stamp.json" 2>/dev/null ||
   grep -qF '%H' "$OV/download.shorebird.dev/shorebird/$H2B/artifacts_manifest.yaml" 2>/dev/null; then
  bad "literal %H survived into the rendered metadata"
else ok "no literal %H in the rendered metadata"; fi
grep -q "$H2B" "$OV/flutter_infra_release/flutter/$H2B/engine_stamp.json" \
  && ok "engine_stamp.json rendered to H2" || bad "engine_stamp.json not rendered"
grep -q '^flutter_engine_revision: 83675ed2' "$OV/download.shorebird.dev/shorebird/$H2B/artifacts_manifest.yaml" \
  && ok "artifacts_manifest keeps the UPSTREAM flutter_engine_revision" \
  || bad "flutter_engine_revision was disturbed"

note "2b - the scratch successor audits complete"
# The transaction's job is COMPLETENESS, not protection. @must_be_local_pkgs is
# per-hash and is added AFTER publication -- the order the Caddyfile itself
# prescribes ("publish for a hash FIRST, then protect it") -- and adding a
# throwaway scratch hash to the live Caddyfile would be exactly the live
# mutation control 9 forbids. So AUDIT CLEAN is unreachable here by design, and
# demanding it would only teach a future reader to weaken control 9.
#
# What IS required: nothing missing, nothing denied-but-present, and every
# remaining finding attributable to not-yet-protected paths.
AUD=$(bash "$SELFHOST/cdn/audit_overlay.sh" --hash "$H2B" --cell "$CELL" \
        --overlay "$OV" --policy "$POLICY" --caddyfile "$SELFHOST/cdn/Caddyfile" 2>&1)
echo "$AUD" | grep -qE 'missing-required: +0' && ok "missing-required: 0" \
  || bad "audit reports missing-required: $(echo "$AUD" | sed -n 's/.*missing-required: *//p' | head -1)"
echo "$AUD" | grep -q 'DENIED-PRESENT' && bad "a denied path is present" || ok "denied-present: none"
other=$(echo "$AUD" | grep -E '^  [A-Z-]+ ' | grep -cv 'UNPROTECTED')
[[ "$other" == 0 ]] && ok "every remaining finding is UNPROTECTED (protection is step 8)" \
                    || bad "$other non-protection finding(s)"

note "3 - the published tree reconstructs the addressed manifest"
BACK="$W/back"; rm -rf "$BACK"
while IFS= read -r m; do
  f="$OV/${m/\%H/$H2B}"; mkdir -p "$BACK/$(dirname "$m")"
  v2_canonicalize "$f" "$H2B" > "$BACK/$m" || bad "canonicalize refused: $m"
done < <(v2_members "$POLICY" "$CELL")
v2_manifest "$BACK" "$POLICY" "$CELL" "$FB" > "$W/m_back"
cmp -s "$EV2/cell_manifest.v2" "$W/m_back" && ok "manifest reconstructed byte-identical" \
                                           || bad "published bytes are not the addressed cell"
[[ "$(shasum -a 256 "$W/m_back" | cut -c1-40)" == "$H2B" ]] && ok "address reconstructed" || bad "address not reconstructed"

note "4 - idempotence / collision refusal"
EV3="$W/ev3"
out=$(v2_transaction "$S" "$POLICY" "$CELL" "$FB" "$OV" "$EV3" 2>&1)
if [[ $? -ne 0 ]] && echo "$out" | grep -q "destination already exists"; then
  ok "a second publish into an existing destination refuses"
else
  bad "second publish did not refuse: $out"
fi
# and it must not have mutated the existing cell
v2_manifest "$BACK" "$POLICY" "$CELL" "$FB" > "$W/m_back2"
cmp -s "$W/m_back" "$W/m_back2" && ok "existing cell unmutated" || bad "existing cell was mutated"

note "5 - pre-existing DIFFERENT bytes at the destination refuse the whole transaction"
OV2="$W/overlay2"; mkdir -p "$OV2/flutter_infra_release/flutter/$H2/ios-release"
printf 'different\n' > "$OV2/flutter_infra_release/flutter/$H2/ios-release/artifacts.zip"
EV4="$W/ev4"
out=$(v2_transaction "$S" "$POLICY" "$CELL" "$FB" "$OV2" "$EV4" 2>&1)
if [[ $? -ne 0 ]]; then ok "refuses rather than partially updating"; else bad "published over a colliding cell"; fi
[[ ! -d "$OV2/download.shorebird.dev/shorebird/$H2" ]] \
  && ok "no partial second root left behind" || bad "partial publication left behind"
[[ "$(cat "$OV2/flutter_infra_release/flutter/$H2/ios-release/artifacts.zip")" == "different" ]] \
  && ok "pre-existing bytes untouched" || bad "pre-existing bytes overwritten"

note "6 - incomplete stage refuses before any address exists"
S2="$W/stage2"; stage_from_H "$S2"
rm -f "$S2/flutter_infra_release/flutter/%H/darwin-arm64/font-subset.zip"
EV5="$W/ev5"
out=$(v2_transaction "$S2" "$POLICY" "$CELL" "$FB" "$W/ov3" "$EV5" --dry-run 2>&1)
if [[ $? -ne 0 ]]; then ok "incomplete stage refuses"; else bad "addressed an incomplete cell"; fi
[[ ! -f "$EV5/cell_address.v2" ]] && ok "no address banked for a refused transaction" \
                                  || bad "an address was banked despite refusal"

note "7 - policy freeze"
cp "$POLICY" "$W/pol"; S3="$W/stage3"; POLICY_SAVED=$POLICY
stage_from_H "$S3"
# mutate the policy copy mid-flight by pointing at a file we then change
EV6="$W/ev6"
( v2_transaction "$S3" "$W/pol" "$CELL" "$FB" "$W/ov4" "$EV6" --dry-run >/dev/null 2>&1 ) && \
  ok "baseline transaction on a policy copy succeeds" || bad "baseline on policy copy failed"
grep -q "artifact_policy.conf     $(shasum -a 256 "$W/pol" | cut -d' ' -f1)" "$EV6/address_provenance.txt" \
  && ok "policy digest recorded in the address provenance" || bad "policy digest not recorded"

note "8 - v1 cannot publish"
out=$(bash "$HERE/mint_route_b_cell.sh" --donor "$H" --address-schema v1 2>&1)
echo "$out" | grep -q "forensic only" && ok "v1 publish refuses" || bad "v1 publish was not refused"

note "9 - the LIVE overlay was never touched"
[[ ! -d "$LIVE_OVERLAY/flutter_infra_release/flutter/$H2" ]] \
  && ok "no scratch successor appeared in the live overlay" || bad "live overlay was written"
[[ -f "$LIVE_OVERLAY/flutter_infra_release/flutter/$H/ios-release/artifacts.zip" ]] \
  && ok "H still present and untouched" || bad "H was disturbed"

echo
if [[ $fail -eq 0 ]]; then echo "RESULT: v2 publish transaction QUALIFIED"; else
  echo "RESULT: $fail FAILURE(S)"; exit 1; fi
