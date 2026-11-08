#!/usr/bin/env bash
# qualify_cell_address_v2.sh -- the gate route-b-cell-v2 must pass before any
# cell is minted with it.
#
# Sources mint_route_b_cell.sh with MINT_CELL_LIB_ONLY so it exercises THE
# PRODUCT'S OWN generator. A copy would keep passing after the product changed,
# which is the false-green shape this repo has now named several times.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SELFHOST="$(cd "$HERE/../.." >/dev/null 2>&1 && pwd)"
POLICY=${POLICY:-$SELFHOST/cdn/artifact_policy.conf}
CELL=${CELL:-macos-ios}
FB=${FB:-69f9831c360d9152862ec3897c67fb09ae843f3b}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

MINT_CELL_LIB_ONLY=1 . "$HERE/mint_route_b_cell.sh"
# The sourced product runs `set -euo pipefail`, and a `.` inherits it into THIS
# shell. Under -e the first non-zero status ends the harness mid-run -- which it
# did, silently truncating a control to its header. A test must decide its own
# failure policy, so restore it explicitly.
set +e

# Defined AFTER the source on purpose: mint_route_b_cell.sh defines its own
# note()/die(), and whichever is defined last wins.
fail=0
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
note(){ echo; echo "== $1"; }

# A staged tree mirroring the overlay, with a LITERAL %H directory.
stage() { # <dir>
  local s=$1 m
  while read -r m; do
    mkdir -p "$s/$(dirname "$m")"
    printf 'content-of %s\n' "$m" > "$s/$m"
  done < <(v2_members "$POLICY" "$CELL")
  # the two hash-bearing members are TEMPLATES carrying %H
  printf '{"git_revision": "%%H", "content_hash": ""}\n' \
    > "$s/flutter_infra_release/flutter/%H/engine_stamp.json"
  printf '# selfhost_engine_hash:  %%H\nflutter_engine_revision: 83675ed27633283e7fc296c8bca22e841224c096\n' \
    > "$s/download.shorebird.dev/shorebird/%H/artifacts_manifest.yaml"
}

note "membership derives from policy"
MEMBERS=$(v2_members "$POLICY" "$CELL")
printf '  %d members\n' "$(printf '%s\n' "$MEMBERS" | grep -c .)"
for want in dart-sdk-darwin-arm64.zip darwin-arm64/artifacts.zip \
            flutter_patched_sdk.zip flutter_patched_sdk_product.zip \
            darwin-arm64/font-subset.zip route-b-compiler-darwin-arm64.zip; do
  printf '%s\n' "$MEMBERS" | grep -q "$want" \
    && ok "member present: $want" || bad "member MISSING: $want"
done

note "A - legacy isolation: v2 differs from a v1-shaped digest over the same set"
S1="$W/s1"; stage "$S1"
v2_manifest "$S1" "$POLICY" "$CELL" "$FB" > "$W/m1" || bad "manifest generation"
A1=$(v2_address "$W/m1")
# v1-shaped: the same member digests with NO schema/cell/fallback preamble.
grep -vE '^(address_schema|cell|fallback_engine_revision) ' "$W/m1" | sort > "$W/m1_v1shape"
A1V1=$(v2_address "$W/m1_v1shape")
[[ "$A1" != "$A1V1" ]] && ok "schema marker changes the address ($A1 != $A1V1)" \
                       || bad "schema marker is not load-bearing"

note "B - determinism"
S2="$W/s2"; stage "$S2"
v2_manifest "$S2" "$POLICY" "$CELL" "$FB" > "$W/m2"
cmp -s "$W/m1" "$W/m2" && ok "manifest bytes identical" || bad "manifest not deterministic"
A2=$(v2_address "$W/m2")
[[ "$A1" == "$A2" ]] && ok "address identical ($A1)" || bad "address not deterministic"

note "C - every-member sensitivity"
while read -r m; do
  S="$W/c"; rm -rf "$S"; stage "$S"
  printf 'MUTATED' >> "$S/$m"
  v2_manifest "$S" "$POLICY" "$CELL" "$FB" > "$W/mc" 2>/dev/null
  AC=$(v2_address "$W/mc")
  [[ "$AC" != "$A1" ]] && ok "address moves: $m" || bad "address DID NOT move: $m"
done < <(v2_members "$POLICY" "$CELL")

note "D - missing-member refusal"
while read -r m; do
  S="$W/d"; rm -rf "$S"; stage "$S"; rm -f "$S/$m"
  if v2_manifest "$S" "$POLICY" "$CELL" "$FB" >/dev/null 2>&1; then
    bad "did NOT refuse a missing member: $m"
  else
    ok "refuses missing: $m"
  fi
done < <(v2_members "$POLICY" "$CELL")

note "E - policy-completeness (membership really comes from policy)"
cp "$POLICY" "$W/policy2"
echo "macos-ios owned-built required flutter_infra_release/flutter/%H/synthetic-required.zip synthetic control" >> "$W/policy2"
v2_members "$W/policy2" "$CELL" | grep -q synthetic-required.zip \
  && ok "synthetic policy line joins membership" || bad "policy line ignored"
S="$W/e"; rm -rf "$S"; stage "$S"   # staged from the ORIGINAL policy: file absent
if v2_manifest "$S" "$W/policy2" "$CELL" "$FB" >/dev/null 2>&1; then
  bad "did NOT refuse when the new required artifact is absent"
else
  ok "refuses until the new required artifact exists"
fi

note "F - Route B compiler is mandatory even though policy says optional"
awk '$4 !~ /route-b-compiler-/' "$POLICY" > "$W/policy3"
grep -q 'route-b-compiler' "$W/policy3" && bad "compiler line not removed from control policy"
S="$W/f"; rm -rf "$S"; stage "$S"
rm -f "$S/download.shorebird.dev/shorebird/%H/route-b-compiler-darwin-arm64.zip"
if v2_manifest "$S" "$POLICY" "$CELL" "$FB" >/dev/null 2>&1; then
  bad "did NOT refuse with the compiler absent"
else
  ok "refuses with the compiler absent"
fi

note "G - canonicalizer: permitted fields only"
HH=a5a8be5854c529268378ce16762a16d6e31763e9
printf '{"git_revision": "%s", "content_hash": ""}\n' "$HH" > "$W/engine_stamp.json"
v2_canonicalize "$W/engine_stamp.json" "$HH" | grep -q '"git_revision": "%H"' \
  && ok "engine_stamp git_revision canonicalized" || bad "engine_stamp not canonicalized"
printf '{"git_revision": "", "other": "%s"}\n' "$HH" > "$W/engine_stamp.json"
v2_canonicalize "$W/engine_stamp.json" "$HH" >/dev/null 2>&1 \
  && bad "accepted the hash outside git_revision" || ok "refuses hash outside git_revision"
printf '# selfhost_engine_hash:  %s\nflutter_engine_revision: 83675ed2\n' "$HH" > "$W/artifacts_manifest.yaml"
v2_canonicalize "$W/artifacts_manifest.yaml" "$HH" >/dev/null 2>&1 \
  && ok "manifest comment canonicalized" || bad "manifest comment refused"
printf 'flutter_engine_revision: %s\n' "$HH" > "$W/artifacts_manifest.yaml"
v2_canonicalize "$W/artifacts_manifest.yaml" "$HH" >/dev/null 2>&1 \
  && bad "accepted the cell hash as flutter_engine_revision" \
  || ok "refuses the cell hash on a data line"
printf 'x %s\n' "$HH" > "$W/sky_engine.zip"
v2_canonicalize "$W/sky_engine.zip" "$HH" >/dev/null 2>&1 \
  && bad "accepted a hash in a file with no permitted field" \
  || ok "refuses a hash in a non-metadata member"

note "H - CONTRAST: the same five members against v1's actual membership"
# Not decoration. If v2's sensitivity test would also pass under v1, it proves
# nothing about the defect that forced this schema. v1's membership is the
# `files=(...)` array plus the *_sha256 lines, so grep the product for each
# path's basename and require v1 to be BLIND to exactly the four that caused
# the STOP -- and sighted for the one it did cover.
MINT="$HERE/mint_route_b_cell.sh"
v1_blind=0
for b in dart-sdk-darwin-arm64.zip darwin-arm64/artifacts.zip \
         flutter_patched_sdk.zip darwin-arm64/font-subset.zip; do
  # count occurrences BEFORE the v2 library, i.e. in v1's own inputs
  n=$(sed -n '1,/ROUTE B CELL ADDRESS SCHEMA v2/p' "$MINT" | grep -cF "$b" || true)
  if [[ "$n" -eq 0 ]]; then ok "v1 is blind to $b (as measured)"; v1_blind=$((v1_blind+1))
  else bad "expected v1 to be blind to $b, found $n reference(s)"; fi
done
[[ "$v1_blind" -eq 4 ]] && ok "v1 blind to 4 of 5; v2 addresses all 5" \
                        || bad "contrast control did not reproduce the measured v1 gap"
n=$(sed -n '1,/ROUTE B CELL ADDRESS SCHEMA v2/p' "$MINT" | grep -cF 'FLUTTER_PLATFORM' || true)
[[ "$n" -gt 0 ]] && ok "v1 did cover the platform dill (the 5th), indirectly" \
                 || bad "v1 platform-dill coverage not found"

echo
if [[ $fail -eq 0 ]]; then echo "RESULT: route-b-cell-v2 QUALIFIED"; else
  echo "RESULT: $fail FAILURE(S)"; exit 1; fi
