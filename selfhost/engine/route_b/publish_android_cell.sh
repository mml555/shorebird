#!/usr/bin/env bash
# cspell:words armeabi embedding canonicalize MAPEOF
# publish_android_cell.sh -- mint the macos-ios-android cell into the LIVE
# overlay, wire the CDN to it, and then prove the wiring rather than assume it.
#
# ORDER, and it is the Caddyfile's own rule: publish for a hash FIRST, then
# protect it. Protecting an unpublished hash turns every fetch into a 404, and
# the audit says NOT SAFE TO PROTECT YET for exactly that reason.
#
# The last two steps are the ones worth having. Publication proves the bytes are
# on disk; only an HTTP fetch back THROUGH THE CDN proves the thing a developer
# will actually talk to serves them -- rewrite rules, protection matchers, the
# fallback map and the cache all sit between the disk and the answer, and every
# one of them has been wrong at least once in this programme.
#
#   publish_android_cell.sh --stage <dir> [--dry-run]
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SELFHOST="$(cd "$HERE/../.." >/dev/null 2>&1 && pwd)"
POLICY="$SELFHOST/cdn/artifact_policy.conf"
OVERLAY="$SELFHOST/cdn/overlay"
MAP="$SELFHOST/cdn/experimental_hashes.map"
CADDY="$SELFHOST/cdn/Caddyfile"
CHECKER="$SELFHOST/cdn/check_protection_matchers.py"
CELL=macos-ios-android
FB=69f9831c360d9152862ec3897c67fb09ae843f3b
CDN_BASE=${CDN_BASE:-http://localhost:8085}
STAGE=""; DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage) STAGE="${2:?}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$STAGE" && -d "$STAGE" ]] || { echo "--stage <dir> is required" >&2; exit 2; }

MINT_CELL_LIB_ONLY=1 . "$HERE/mint_route_b_cell.sh"
set +e
fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note(){ printf '\n\033[1m== %s\033[0m\n' "$1"; }

EV="$SELFHOST/evidence/android-cell-supply-2/mint"
note "1 - address"
H=$(v2_transaction "$STAGE" "$POLICY" "$CELL" "$FB" "$OVERLAY" "$EV.dry" --dry-run)
[[ -n "$H" ]] || { echo "no address; refusing" >&2; exit 1; }
echo "  address: $H"
if [[ "$DRY" == 1 ]]; then echo "  (dry run; nothing published)"; exit 0; fi

note "2 - publish into the live overlay, transactionally"
H2=$(v2_transaction "$STAGE" "$POLICY" "$CELL" "$FB" "$OVERLAY" "$EV")
[[ "$H2" == "$H" ]] && ok "published at $H2" || { bad "address changed on publish: $H2"; exit 1; }

note "3 - register the descriptor"
cp "$EV/cell_manifest.v2" "$HERE/cell_manifests/$H2.v2"
[[ "$(shasum -a 256 "$HERE/cell_manifests/$H2.v2" | cut -c1-40)" == "$H2" ]] \
  && ok "cell_manifests/$H2.v2 authenticates its own name" || bad "registered manifest does not authenticate"

note "4 - CDN wiring"
if grep -q "^$H2 " "$MAP"; then ok "already in experimental_hashes.map"; else
  cat >> "$MAP" <<MAPEOF

# The macos-ios-android cell (ANDROID-CELL-SUPPLY-2). iOS/macOS members are
# byte-identical to cd848320's; the Android members were built by us from engine
# f1a59b8a, whose parent is cd848320's producer dfa2b24a.
$H2 $FB
MAPEOF
  ok "added to experimental_hashes.map -> $FB"
fi
# The two per-cell groups in @must_be_local_pkgs. Both are alternations of
# spelled-out hashes; appending is a string edit, so it is done by anchoring on
# the donor's hash rather than on a position.
python3 - "$CADDY" "$H2" <<'PY'
import sys
path, h = sys.argv[1], sys.argv[2]
donor = 'cd848320d605ff8af5060cabf9a8d1b35853f752'
s = open(path).read()
if h in s:
    print('    (Caddyfile already names the cell)')
    sys.exit(0)
n = s.count(donor)
if n != 2:
    sys.exit(f'    expected the donor 2 times in the Caddyfile, found {n} -- refusing to edit blind')
s = s.replace(donor, f'{donor}|{h}')
open(path, 'w').write(s)
print(f'    Caddyfile: added {h} beside the donor in {n} places')
PY
[[ $? -eq 0 ]] && ok "Caddyfile per-cell matchers extended" || bad "Caddyfile edit refused"
python3 - "$CHECKER" "$H2" <<'PY'
import sys
path, h = sys.argv[1], sys.argv[2]
s = open(path).read()
if h in s:
    sys.exit(0)
anchor = "    'cd848320d605ff8af5060cabf9a8d1b35853f752',   # v13 successor\n"
if anchor not in s:
    sys.exit('    could not find the PROTECTED_CELLS anchor')
s = s.replace(anchor, anchor + f"    '{h}',   # macos-ios-android\n", 1)
open(path, 'w').write(s)
PY
[[ $? -eq 0 ]] && ok "the matcher checker now asserts coverage for this cell" || bad "checker not updated"
python3 "$CHECKER" >/dev/null 2>&1 && ok "matcher coverage OK at the new address" || bad "matcher coverage FAILED"

note "5 - restart the CDN (the fallback map is read at startup)"
( cd "$SELFHOST/cdn" && docker compose -f docker-compose.cdn.yaml up -d --force-recreate cdn-cache ) >/dev/null 2>&1
for _ in $(seq 1 40); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$CDN_BASE/flutter_infra_release/flutter/$H2/engine_stamp.json")
  [[ "$code" == 200 ]] && break; sleep 1
done
[[ "$code" == 200 ]] && ok "CDN answers for the new cell (engine_stamp.json 200)" \
                     || bad "CDN did not come back for the new cell (last code $code)"

note "6 - the verifier, on the live overlay"
out=$(bash "$HERE/verify_cell_members.sh" "$H2" 2>&1)
echo "$out" | sed 's/^/    /'
echo "$out" | grep -q "CELL MEMBERS VERIFIED (30/30)" && ok "30/30 on disk" || bad "verifier not green"

note "7 - FETCH BACK THROUGH THE CDN and compare bytes"
# Not from disk. Every member, over HTTP, byte-compared against the stage.
T=$(mktemp -d); n=0; good=0
while IFS= read -r m; do
  n=$((n+1)); url="$CDN_BASE/${m//%H/$H2}"
  curl -fsS "$url" -o "$T/x" 2>/dev/null || { echo "    HTTP FAILED $url"; continue; }
  case "$(basename "$m")" in
    engine_stamp.json|artifacts_manifest.yaml|*.pom)
      # Rendered metadata: compare the CANONICAL form against the stage, which
      # is the only comparison that is defined for a member carrying its own
      # address.
      a=$(python3 "$HERE/lib/v2_canonicalize.py" "$T/x" "$H2" --digest 2>/dev/null)
      b=$(shasum -a 256 "$STAGE/$m" | cut -d' ' -f1)
      [[ -n "$a" && "$a" == "$b" ]] && good=$((good+1)) || echo "    CANONICAL MISMATCH $m" ;;
    *)
      cmp -s "$T/x" "$STAGE/$m" && good=$((good+1)) || echo "    BYTES DIFFER $m" ;;
  esac
done < <(v2_members "$POLICY" "$CELL")
rm -rf "$T"
[[ "$good" == "$n" ]] && ok "$good of $n members fetched back identical over HTTP" \
                      || bad "$good of $n fetched back identical"

note "8 - the donor cell is untouched"
out=$(bash "$HERE/verify_cell_members.sh" "cd848320d605ff8af5060cabf9a8d1b35853f752" 2>&1)
echo "$out" | grep -q "CELL MEMBERS VERIFIED (16/16)" && ok "donor still 16/16" || bad "donor disturbed"

note "9 - overlay audit for the new cell"
AUD=$(bash "$SELFHOST/cdn/audit_overlay.sh" --hash "$H2" --cell "$CELL" 2>&1)
echo "$AUD" | grep -E 'missing-required|DENIED-PRESENT|AUDIT' | sed 's/^/    /'
echo "$AUD" | grep -qE 'missing-required: +0' && ok "missing-required: 0" || bad "audit reports missing required artifacts"
echo "$AUD" | grep -q 'DENIED-PRESENT' && bad "a denied path is present" || ok "denied-present: none"

echo
echo "  ADDRESS: $H2"
if [[ $fail -eq 0 ]]; then echo "RESULT: macos-ios-android CELL PUBLISHED AND SERVED"; else
  echo "RESULT: $fail FAILURE(S)"; exit 1; fi
