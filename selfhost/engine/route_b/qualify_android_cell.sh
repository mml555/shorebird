#!/usr/bin/env bash
# cspell:words armeabi embedding canonicalization canonicalize flipbyte defaultdict newok pomok armv UNMUTATED MREG clonefile
# qualify_android_cell.sh -- the gate the macos-ios-android cell must pass
# BEFORE anything is published live.
#
# Everything happens in a scratch overlay against a scratch address. The live
# overlay is read for the donor's bytes and never written; control Z proves it.
#
# The controls are arranged so that no single one of them could pass by
# accident. Every mutation control is paired with the un-mutated baseline it is
# compared against, and every refusal control asserts the REFUSAL TEXT, not
# merely a non-zero exit -- a script that dies for an unrelated reason must not
# be able to read as a passing negative control.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SELFHOST="$(cd "$HERE/../.." >/dev/null 2>&1 && pwd)"
POLICY=${POLICY:-$SELFHOST/cdn/artifact_policy.conf}
LIVE_OVERLAY=${LIVE_OVERLAY:-$SELFHOST/cdn/overlay}
# Named CELL_DONOR because sourcing the mint library declares its own DONOR=""
# for argument parsing and would silently empty this -- the trap
# stage_v13_cell.sh already records. Restored after the source.
CELL_DONOR=${DONOR:-cd848320d605ff8af5060cabf9a8d1b35853f752}
PRODUCER_REV=${PRODUCER_REV:-f1a59b8a1609c51397601c36d586ad7763d57153}
MEMBERS=${MEMBERS:?set MEMBERS to the dir holding the 14 built Android members}
STAGE=${STAGE:?set STAGE to the staged 30-member cell (stage_android_cell.sh)}
CELL=macos-ios-android
FB=69f9831c360d9152862ec3897c67fb09ae843f3b
W=${W:-$(mktemp -d /Volumes/build/route-b/acs2/qual.XXXXXX)}

MINT_CELL_LIB_ONLY=1 . "$HERE/mint_route_b_cell.sh"
DONOR="$CELL_DONOR"
set +e

fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note(){ printf '\n\033[1m== %s\033[0m\n' "$1"; }

MV='download.flutter.io/io/flutter'
FI='flutter_infra_release/flutter/%H'
SB='download.shorebird.dev/shorebird/%H'
POM="$MV/arm64_v8a_release/1.0.0-%H/arm64_v8a_release-1.0.0-%H.pom"
JAR="$MV/arm64_v8a_release/1.0.0-%H/arm64_v8a_release-1.0.0-%H.jar"

[[ -d "$STAGE" ]] || { echo "no stage at $STAGE -- run stage_android_cell.sh first" >&2; exit 2; }

# A scratch clone of the stage, so a mutation control can never touch the real
# one. `cp -c` asks APFS for a copy-on-write clone: the blocks are shared until
# written, so flipping a byte in the clone cannot reach the original, and six
# clones of a 1.3 GB stage cost seconds instead of minutes. Falls back to a real
# copy on a filesystem without clonefile. NOT hard links, which would share the
# bytes for real and make every mutation control mutate the subject.
clone() {
  local d="$W/$1"; rm -rf "$d"
  cp -Rc "$STAGE" "$d" 2>/dev/null || cp -R "$STAGE" "$d"
  echo "$d"
}
addr()  { v2_transaction "$1" "$POLICY" "$CELL" "$FB" "$W/void_$RANDOM" "$W/ev_$RANDOM" --dry-run 2>/dev/null; }
# Flip ONE byte, in place, without rewriting the file.
flipbyte() { python3 - "$1" "${2:-0}" <<'PY'
import sys
p, off = sys.argv[1], int(sys.argv[2])
with open(p, 'r+b') as f:
    f.seek(off); b = f.read(1)
    f.seek(off); f.write(bytes([b[0] ^ 0x01]))
PY
}

# =============================================================================
note "A - the twin macOS/iOS lines agree between the two cells"
# macos-ios-android duplicates macos-ios's host/iOS lines. Duplication is a
# choice (membership is an exact cell match, and an inheritance rule would be a
# second mechanism to get wrong), so the agreement must be MECHANICAL or it will
# rot the first time one side is edited.
python3 - "$POLICY" <<'PY'
import sys, collections
rows = collections.defaultdict(dict)
for line in open(sys.argv[1]):
    line = line.strip()
    if not line or line.startswith('#'):
        continue
    f = line.split(None, 4)
    if len(f) < 4:
        continue
    cell, prov, req, path = f[0], f[1], f[2], f[3]
    rows[cell][path] = (prov, req)
a, b = rows.get('macos-ios', {}), rows.get('macos-ios-android', {})
shared = set(a) & set(b)
bad = [p for p in sorted(shared) if a[p] != b[p]]
# Every macos-ios path must be present in the twin, or the new cell silently
# drops an artifact the old one owned.
missing = sorted(set(a) - set(b))
print(f'    shared paths: {len(shared)}   divergent: {len(bad)}   missing from twin: {len(missing)}')
for p in bad:
    print(f'    DIVERGENT {p}: macos-ios={a[p]} macos-ios-android={b[p]}')
for p in missing:
    print(f'    MISSING   {p}')
sys.exit(1 if bad or missing else 0)
PY
[[ $? -eq 0 ]] && ok "no divergence and nothing dropped" || bad "the twin cells' shared lines disagree"

MC=$(v2_members "$POLICY" "$CELL" | wc -l | tr -d ' ')
[[ "$MC" == 30 ]] && ok "policy derives 30 members for $CELL" || bad "policy derives $MC members, expected 30"
MO=$(v2_members "$POLICY" macos-ios | wc -l | tr -d ' ')
[[ "$MO" == 16 ]] && ok "macos-ios still derives 16 (the existing cell is untouched)" \
                  || bad "macos-ios now derives $MO"

# =============================================================================
note "B - the stage is the cell it claims to be"
n=$(cd "$STAGE" && find . -type f | wc -l | tr -d ' ')
[[ "$n" == 30 ]] && ok "exactly 30 files staged" || bad "staged $n files"
ident=0
for m in "$FI/dart-sdk-darwin-arm64.zip" "$FI/darwin-arm64/artifacts.zip" \
         "$FI/darwin-arm64/font-subset.zip" "$FI/flutter_gpu.zip" \
         "$FI/flutter_patched_sdk.zip" "$FI/flutter_patched_sdk_product.zip" \
         "$FI/ios-release/artifacts.zip" "$FI/ios/artifacts.zip" \
         "$FI/ios-profile/artifacts.zip" "$FI/sky_engine.zip" \
         "$SB/patch-darwin-arm64.zip" "$SB/patch-darwin-x64.zip" \
         "$SB/patch-linux-x64.zip" "$SB/route-b-compiler-darwin-arm64.zip"; do
  cmp -s "$STAGE/$m" "$LIVE_OVERLAY/${m/\%H/$DONOR}" && ident=$((ident+1)) \
    || echo "    NOT byte-identical: $m"
done
[[ "$ident" == 14 ]] && ok "14 macOS/iOS members byte-identical to the donor" \
                     || bad "$ident of 14 byte-identical"
a=$(python3 "$HERE/lib/v2_canonicalize.py" "$LIVE_OVERLAY/flutter_infra_release/flutter/$DONOR/engine_stamp.json" "$DONOR" --digest)
b=$(shasum -a 256 "$STAGE/$FI/engine_stamp.json" | cut -d' ' -f1)
[[ "$a" == "$b" ]] && ok "engine_stamp.json identical in canonical form (15th)" \
                   || bad "engine_stamp.json canonical form differs"
# The 16th, and the one member of the iOS half that is DELIBERATELY different.
d=$(python3 "$HERE/lib/v2_canonicalize.py" "$LIVE_OVERLAY/download.shorebird.dev/shorebird/$DONOR/artifacts_manifest.yaml" "$DONOR" \
    | diff - "$STAGE/$SB/artifacts_manifest.yaml" | grep -c '^[<>]')
[[ "$d" == 4 ]] && ok "artifacts_manifest.yaml differs in exactly 2 lines (target, override_list_from)" \
               || bad "artifacts_manifest.yaml differs in $((d/2)) lines, expected 2"
grep -q '^# target:                ios+android$' "$STAGE/$SB/artifacts_manifest.yaml" \
  && ok "and it declares target ios+android" || bad "target line not updated"
# The 14 Android members must be the ones we built, by digest.
newok=0
for abi in arm arm64 x64; do for obj in darwin-x64 artifacts; do
  cmp -s "$STAGE/$FI/android-$abi-release/$obj.zip" "$MEMBERS/android-$abi-release--$obj.zip" \
    && newok=$((newok+1)) || echo "    differs: android-$abi-release/$obj.zip"
done; done
for art in arm64_v8a_release armeabi_v7a_release x86_64_release flutter_embedding_release; do
  cmp -s "$STAGE/$MV/$art/1.0.0-%H/$art-1.0.0-%H.jar" "$MEMBERS/$art-1.0.0-$PRODUCER_REV.jar" \
    && newok=$((newok+1)) || echo "    differs: $art jar"
done
[[ "$newok" == 10 ]] && ok "10 Android binary members are the built bytes verbatim" \
                     || bad "$newok of 10 match the built bytes"
pomok=0
for art in arm64_v8a_release armeabi_v7a_release x86_64_release flutter_embedding_release; do
  f="$STAGE/$MV/$art/1.0.0-%H/$art-1.0.0-%H.pom"
  grep -qF '<version>1.0.0-%H</version>' "$f" && ! grep -qF "$PRODUCER_REV" "$f" \
    && pomok=$((pomok+1)) || echo "    not templated: $art.pom"
done
[[ "$pomok" == 4 ]] && ok "4 POMs templated to 1.0.0-%H with no producer revision left" \
                    || bad "$pomok of 4 POMs templated"

# =============================================================================
note "C - the address, from a stage that is already complete"
EV="$W/ev"; OV="$W/overlay"; mkdir -p "$OV"
H2=$(v2_transaction "$STAGE" "$POLICY" "$CELL" "$FB" "$OV" "$EV" --dry-run)
[[ -n "$H2" ]] && ok "address computed: $H2" || bad "no address"
REC=$(shasum -a 256 "$EV/cell_manifest.v2" | cut -c1-40)
[[ "$REC" == "$H2" ]] && ok "recomputes independently from the banked manifest" \
                      || bad "manifest does not recompute the address"
MN=$(awk '$1!="address_schema" && $1!="cell" && $1!="fallback_engine_revision" && NF==2' "$EV/cell_manifest.v2" | wc -l | tr -d ' ')
[[ "$MN" == 30 ]] && ok "manifest carries 30 members" || bad "manifest carries $MN members"
grep -q '^cell macos-ios-android$' "$EV/cell_manifest.v2" \
  && ok "descriptor declares cell macos-ios-android" || bad "wrong cell scope in the descriptor"
[[ "$H2" != "$DONOR" ]] && ok "the address is NOT the donor's" || bad "address collided with the donor"

# =============================================================================
note "D - MUTATION CONTROLS: one byte must move the address"
# Each is a fresh clone of the stage with exactly one byte flipped, addressed
# with --dry-run so nothing is published. If any of these reproduces H2, the
# address is not committing to that member's bytes.
for spec in "a Maven JAR:$JAR" \
            "a release gen_snapshot (darwin-x64.zip):$FI/android-arm64-release/darwin-x64.zip" \
            "a release engine artifacts.zip:$FI/android-arm64-release/artifacts.zip" \
            "an armv7 gen_snapshot:$FI/android-arm-release/darwin-x64.zip" \
            "an x86_64 gen_snapshot:$FI/android-x64-release/darwin-x64.zip"; do
  desc=${spec%%:*}; rel=${spec#*:}
  C=$(clone "mut_$(echo "$rel" | tr '/%.' '___')")
  before=$(shasum -a 256 "$C/$rel" | cut -c1-16)
  flipbyte "$C/$rel" 512
  after=$(shasum -a 256 "$C/$rel" | cut -c1-16)
  [[ "$before" != "$after" ]] || { bad "$desc: the byte flip did not change the file"; continue; }
  H=$(addr "$C")
  if [[ -z "$H" ]]; then bad "$desc: mutated stage produced no address"
  elif [[ "$H" == "$H2" ]]; then bad "$desc: ONE BYTE CHANGED AND THE ADDRESS DID NOT"
  else ok "$desc: address moved $H2 -> $H"; fi
  rm -rf "$C"
done

# An ordinary POM mutation -- a field the schema does not treat specially -- must
# also move the address. Without this, "the POM is canonicalized" could be read
# as "the POM's content does not matter".
C=$(clone mut_pom_ordinary)
sed -i '' 's|<packaging>jar</packaging>|<packaging>aar</packaging>|' "$C/$POM"
H=$(addr "$C")
[[ -n "$H" && "$H" != "$H2" ]] && ok "an ordinary POM field change moves the address ($H)" \
                              || bad "a POM field change did not move the address"
rm -rf "$C"

# And the control that keeps the four above from being vacuous: an UNMUTATED
# clone must reproduce H2 exactly. If cloning alone perturbed the address, every
# "address moved" result above would be meaningless.
C=$(clone mut_none)
H=$(addr "$C")
[[ "$H" == "$H2" ]] && ok "an unmutated clone reproduces the same address (so the moves above are the mutations)" \
                    || bad "an unmutated clone addressed differently: $H"
rm -rf "$C"

# =============================================================================
note "E - REFUSAL CONTROLS: the hash is permitted in exactly one POM field"
refuses() { # <desc> <file> <hash> <expectedFragment>
  local desc=$1 f=$2 h=$3 want=$4 out rc
  out=$(python3 "$HERE/lib/v2_canonicalize.py" "$f" "$h" 2>&1 >/dev/null); rc=$?
  if [[ $rc -eq 0 ]]; then bad "$desc: canonicalization ACCEPTED it"
  elif [[ "$out" != *"$want"* ]]; then bad "$desc: refused for the wrong reason: $out"
  else ok "$desc: refused -- $out"; fi
}
FAKE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
P="$W/probe.pom"

# 1. the permitted shape is accepted, so the refusals below are about placement
#    and not about the file being a POM at all.
sed "s/%H/$FAKE/" "$STAGE/$POM" > "$P"
python3 "$HERE/lib/v2_canonicalize.py" "$P" "$FAKE" >/dev/null 2>&1 \
  && ok "baseline: the project <version> IS accepted" || bad "baseline POM was refused"

# 2. the hash in a DEPENDENCY version -- the cell's identity leaking into a
#    third-party coordinate. Must be refused, never normalised away.
#
#    Constructed with EXACTLY ONE hash-bearing line, and it is the dependency's:
#    the project version is set to something else. Otherwise the occurrence
#    budget refuses the file first and the PLACEMENT rule is never exercised --
#    which is what a first draft of this control did, and it looked like a pass.
sed "s/%H/$FAKE/" "$STAGE/$MV/flutter_embedding_release/1.0.0-%H/flutter_embedding_release-1.0.0-%H.pom" \
  | sed "s|<version>1.0.0-$FAKE</version>|<version>1.0.0-other</version>|" \
  | awk -v h="$FAKE" 'BEGIN{done=0}
      /<version>2\.7\.0<\/version>/ && !done { sub(/2\.7\.0/, "1.0.0-" h); done=1 }
      { print }' > "$P"
[[ "$(grep -c "$FAKE" "$P")" == 1 ]] \
  && ok "probe has exactly one hash-bearing line, and it is a dependency's" \
  || bad "probe is not isolated: $(grep -c "$FAKE" "$P") hash-bearing lines"
refuses "the hash in a dependency <version>" "$P" "$FAKE" "outside the project <version> element"

# 3. the hash in a comment -- a place that is legitimate in
#    artifacts_manifest.yaml and must NOT be legitimate here.
sed "s/%H/$FAKE/" "$STAGE/$POM" | sed "1a\\
  <!-- $FAKE -->" > "$P"
refuses "the hash in a POM comment" "$P" "$FAKE" "outside the project <version> element"

# 4. a SECOND hash-bearing field of the permitted shape. Per-line matching alone
#    would accept this; the occurrence budget is what refuses it.
sed "s/%H/$FAKE/" "$STAGE/$POM" \
  | sed "s|<packaging>jar</packaging>|<packaging>jar</packaging>\\
  <version>1.0.0-$FAKE</version>|" > "$P"
refuses "a second <version>1.0.0-hash</version> line" "$P" "$FAKE" "hash-bearing lines, exactly 1 permitted"

# 5. the same rule still holds for the other two schemas. engine_stamp.json is
#    a single JSON line, so a hash smuggled into `content_hash` sits on the same
#    line as the permitted `git_revision` -- the residual check is what catches
#    it, and asserting the budget message here would have been asserting a
#    refusal that cannot fire for this file shape.
sed "s/\"content_hash\": \"\"/\"content_hash\": \"$FAKE\"/" \
  "$STAGE/$FI/engine_stamp.json" | sed "s/%H/$FAKE/" > "$W/engine_stamp.json"
refuses "a second hash on engine_stamp.json's single line" "$W/engine_stamp.json" "$FAKE" "residual hash after canonicalization"
sed "s/%H/$FAKE/" "$STAGE/$SB/artifacts_manifest.yaml" \
  | sed "s|^storage_bucket: .*|storage_bucket: $FAKE|" > "$W/artifacts_manifest.yaml"
refuses "the hash on a data line of artifacts_manifest.yaml" "$W/artifacts_manifest.yaml" "$FAKE" "on a non-comment line"
# A file type with no permitted field at all.
printf 'x %s x\n' "$FAKE" > "$W/random.txt"
refuses "any hash in a member with no permitted field" "$W/random.txt" "$FAKE" "no permitted hash-bearing field"

# =============================================================================
note "F - publish for real, into a SCRATCH overlay"
EV2="$W/ev2"
H2B=$(v2_transaction "$STAGE" "$POLICY" "$CELL" "$FB" "$OV" "$EV2")
[[ "$H2B" == "$H2" ]] && ok "publish address matches the dry run ($H2B)" || bad "address changed on publish: $H2B"
missing=0
while IFS= read -r m; do
  [[ -f "$OV/${m//%H/$H2B}" ]] || { missing=$((missing+1)); echo "     absent: ${m//%H/$H2B}"; }
done < <(v2_members "$POLICY" "$CELL")
[[ "$missing" == 0 ]] && ok "all 30 rendered paths present in the overlay" || bad "$missing member(s) absent"
# The Maven roots are four separate transaction roots, four levels down, with %H
# in the FILENAME as well -- the shape the old hard-coded root list could not
# express.
mvn=$(find "$OV/download.flutter.io" -type f 2>/dev/null | wc -l | tr -d ' ')
[[ "$mvn" == 8 ]] && ok "8 Maven files published under 4 version directories" || bad "$mvn Maven files published"
[[ -z "$(find "$OV" -name '*%H*' 2>/dev/null)" ]] && ok "no literal %H survives in any published PATH" \
                                                  || bad "a published path still contains %H"
res=0
while IFS= read -r f; do grep -qF '%H' "$f" && { echo "     %H in $f"; res=$((res+1)); }; done \
  < <(find "$OV" -type f \( -name engine_stamp.json -o -name artifacts_manifest.yaml -o -name '*.pom' \))
[[ "$res" == 0 ]] && ok "no literal %H survives in any rendered metadata BODY" || bad "$res file(s) retain %H"

note "F2 - every published POM declares the version it is served under"
pv=0
for art in arm64_v8a_release armeabi_v7a_release x86_64_release flutter_embedding_release; do
  f="$OV/$MV/$art/1.0.0-$H2B/$art-1.0.0-$H2B.pom"
  if grep -qF "<version>1.0.0-$H2B</version>" "$f" 2>/dev/null; then pv=$((pv+1))
  else echo "     $art declares: $(grep -m1 -o '<version>[^<]*</version>' "$f" 2>/dev/null)"; fi
done
[[ "$pv" == 4 ]] && ok "4 of 4 -- Gradle's consistency check can succeed" || bad "$pv of 4 POMs agree"

note "F3 - FETCH BACK: the bytes in the overlay are the bytes we staged"
bb=0; bn=0
while IFS= read -r m; do
  case "$(basename "$m")" in engine_stamp.json|artifacts_manifest.yaml|*.pom) continue ;; esac
  bn=$((bn+1))
  cmp -s "$STAGE/$m" "$OV/${m//%H/$H2B}" && bb=$((bb+1)) || echo "     BYTES DIFFER: $m"
done < <(v2_members "$POLICY" "$CELL")
[[ "$bb" == "$bn" ]] && ok "$bb of $bn non-metadata members byte-identical after publication" \
                     || bad "$bb of $bn byte-identical"

note "F4 - the published tree reconstructs the addressed manifest"
BACK="$W/back"; rm -rf "$BACK"
rcb=0
while IFS= read -r m; do
  f="$OV/${m//%H/$H2B}"; mkdir -p "$BACK/$(dirname "$m")"
  python3 "$HERE/lib/v2_canonicalize.py" "$f" "$H2B" > "$BACK/$m" || { bad "canonicalize refused: $m"; rcb=1; }
done < <(v2_members "$POLICY" "$CELL")
v2_manifest "$BACK" "$POLICY" "$CELL" "$FB" > "$W/m_back"
cmp -s "$EV2/cell_manifest.v2" "$W/m_back" && ok "manifest reconstructed byte-identical" \
                                           || bad "published bytes are not the addressed cell"
[[ "$(shasum -a 256 "$W/m_back" | cut -c1-40)" == "$H2B" ]] && ok "address reconstructed from the overlay" \
                                                            || bad "address not reconstructed"

# =============================================================================
note "G - verify_cell_members.sh sees a green 30/30, and can go red"
MREG="$W/manifests"; mkdir -p "$MREG"; cp "$EV2/cell_manifest.v2" "$MREG/$H2B.v2"
out=$(CELL_MANIFESTS="$MREG" bash "$HERE/verify_cell_members.sh" "$H2B" --overlay "$OV" 2>&1)
echo "$out" | sed 's/^/    /'
echo "$out" | grep -q "CELL MEMBERS VERIFIED (30/30)" && ok "30/30 verified" || bad "verifier did not report 30/30"
echo "$out" | grep -q "4 Maven POM(s) declare the version they are served under" \
  && ok "the Maven coordinate check ran on 4 POMs" || bad "the POM coordinate check did not run"

# The verifier must be falsifiable in each of the three distinct ways this cell
# can break. A green verifier proves nothing until it has been made to go red.
note "G2 - DRIFT: one byte in a published JAR"
cp "$OV/$MV/arm64_v8a_release/1.0.0-$H2B/arm64_v8a_release-1.0.0-$H2B.jar" "$W/jar.bak"
flipbyte "$OV/$MV/arm64_v8a_release/1.0.0-$H2B/arm64_v8a_release-1.0.0-$H2B.jar" 4096
out=$(CELL_MANIFESTS="$MREG" bash "$HERE/verify_cell_members.sh" "$H2B" --overlay "$OV" 2>&1)
echo "$out" | grep -q "DRIFTED.*arm64_v8a_release" && ok "reports DRIFTED on the exact member" \
                                                   || bad "drift not detected: $(echo "$out" | tail -1)"
cp "$W/jar.bak" "$OV/$MV/arm64_v8a_release/1.0.0-$H2B/arm64_v8a_release-1.0.0-$H2B.jar"

note "G3 - SMUGGLING: the address moved into a POM field the schema forbids"
PF="$OV/$MV/x86_64_release/1.0.0-$H2B/x86_64_release-1.0.0-$H2B.pom"
cp "$PF" "$W/pom.bak"
sed -i '' "s|<packaging>jar</packaging>|<packaging>jar</packaging>\\
  <!-- $H2B -->|" "$PF"
out=$(CELL_MANIFESTS="$MREG" bash "$HERE/verify_cell_members.sh" "$H2B" --overlay "$OV" 2>&1)
echo "$out" | grep -q "canonicalization refused" && ok "the verifier refuses rather than normalising it away" \
                                                 || bad "a forbidden hash location was accepted: $(echo "$out" | tail -1)"
cp "$W/pom.bak" "$PF"

note "G4 - COORDINATE MISMATCH: a POM whose bytes are addressed but whose version is wrong"
# Constructed so canonicalization CANNOT catch it: the wrong version carries no
# occurrence of this cell's hash at all, so canon_hash passes the file through
# and only the coordinate check can see the problem. This is the failure that
# would otherwise surface as Gradle's "bad version: expected=… found=…" on a
# developer's machine.
PF="$OV/$MV/armeabi_v7a_release/1.0.0-$H2B/armeabi_v7a_release-1.0.0-$H2B.pom"
cp "$PF" "$W/pom2.bak"
sed -i '' "s|<version>1.0.0-$H2B</version>|<version>1.0.0-$FB</version>|" "$PF"
! grep -qF "$H2B" "$PF" && ok "the probe file contains no occurrence of the cell hash" \
                        || bad "probe still contains the hash, so this control is not testing the coordinate check"
out=$(CELL_MANIFESTS="$MREG" bash "$HERE/verify_cell_members.sh" "$H2B" --overlay "$OV" 2>&1)
echo "$out" | grep -q "Maven coordinate disagrees" && ok "reports the coordinate mismatch" \
                                                   || bad "coordinate mismatch not detected: $(echo "$out" | tail -1)"
cp "$W/pom2.bak" "$PF"
out=$(CELL_MANIFESTS="$MREG" bash "$HERE/verify_cell_members.sh" "$H2B" --overlay "$OV" 2>&1)
echo "$out" | grep -q "CELL MEMBERS VERIFIED (30/30)" && ok "green again after every probe is reverted" \
                                                      || bad "the overlay was left damaged"

note "G5 - MISSING: a member the manifest names but the overlay does not serve"
mv "$OV/$FI/android-x64-release/darwin-x64.zip" "$W/x64gs.bak" 2>/dev/null
mv "$OV/flutter_infra_release/flutter/$H2B/android-x64-release/darwin-x64.zip" "$W/x64gs.bak" 2>/dev/null
out=$(CELL_MANIFESTS="$MREG" bash "$HERE/verify_cell_members.sh" "$H2B" --overlay "$OV" 2>&1)
echo "$out" | grep -q "MISSING.*android-x64-release/darwin-x64.zip" && ok "reports MISSING, not a silent pass" \
                                                                    || bad "a missing member did not fail"
mv "$W/x64gs.bak" "$OV/flutter_infra_release/flutter/$H2B/android-x64-release/darwin-x64.zip"

# =============================================================================
note "H - transactional properties still hold at 30 members"
EV3="$W/ev3"
out=$(v2_transaction "$STAGE" "$POLICY" "$CELL" "$FB" "$OV" "$EV3" 2>&1); rc=$?
if [[ $rc -ne 0 ]] && echo "$out" | grep -q "destination already exists"; then
  ok "a second publish into an existing destination refuses"
else bad "second publish did not refuse: $out"; fi

OV2="$W/overlay2"
mkdir -p "$OV2/download.flutter.io/io/flutter/x86_64_release/1.0.0-$H2"
printf 'different\n' > "$OV2/download.flutter.io/io/flutter/x86_64_release/1.0.0-$H2/x86_64_release-1.0.0-$H2.pom"
S4=$(clone stage_collide)
out=$(v2_transaction "$S4" "$POLICY" "$CELL" "$FB" "$OV2" "$W/ev4" 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "a collision on a MAVEN root refuses the whole transaction" \
                || bad "published over a colliding Maven root"
[[ ! -d "$OV2/flutter_infra_release/flutter/$H2" ]] \
  && ok "no other root left behind by the refused transaction" || bad "partial publication left behind"
[[ "$(cat "$OV2/download.flutter.io/io/flutter/x86_64_release/1.0.0-$H2/x86_64_release-1.0.0-$H2.pom")" == "different" ]] \
  && ok "the pre-existing bytes were not overwritten" || bad "pre-existing bytes overwritten"
rm -rf "$S4"

S5=$(clone stage_incomplete)
rm -f "$S5/$MV/x86_64_release/1.0.0-%H/x86_64_release-1.0.0-%H.pom"
out=$(v2_transaction "$S5" "$POLICY" "$CELL" "$FB" "$W/ov5" "$W/ev5" --dry-run 2>&1); rc=$?
[[ $rc -ne 0 ]] && ok "a stage missing one Maven POM refuses before any address exists" \
                || bad "addressed an incomplete cell"
[[ ! -f "$W/ev5/cell_address.v2" ]] && ok "no address banked for the refused transaction" \
                                    || bad "an address was banked despite refusal"
rm -rf "$S5"

# =============================================================================
note "I - Caddy protection covers the new identity members"
python3 "$SELFHOST/cdn/check_protection_matchers.py" 2>&1 | sed 's/^/    /'
[[ ${PIPESTATUS[0]:-1} -eq 0 ]] && ok "matcher coverage OK" || bad "matcher coverage failed"
python3 - "$SELFHOST/cdn/Caddyfile" "$H2B" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
h = sys.argv[2]
res = [re.compile(l.strip()[len('path_regexp '):].strip())
       for l in text.splitlines() if l.strip().startswith('path_regexp ')]
want = []
for abi in ('arm', 'arm64', 'x64'):
    for obj in ('darwin-x64.zip', 'artifacts.zip'):
        want.append(f'/flutter_infra_release/flutter/{h}/android-{abi}-release/{obj}')
for art in ('arm64_v8a_release', 'armeabi_v7a_release', 'x86_64_release',
            'flutter_embedding_release'):
    for ext in ('jar', 'pom'):
        want.append(f'/download.flutter.io/io/flutter/{art}/1.0.0-{h}/{art}-1.0.0-{h}.{ext}')
missing = [p for p in want if not any(r.search(p) for r in res)]
print(f'    identity members checked: {len(want)}   unprotected: {len(missing)}')
for p in missing:
    print(f'    UNPROTECTED {p}')
sys.exit(1 if missing else 0)
PY
[[ $? -eq 0 ]] && ok "all 14 identity-bearing members are must-be-local at THIS address" \
               || bad "an identity member is still fallback-permitted"
# and the narrowness of that change
python3 - "$SELFHOST/cdn/Caddyfile" "$H2B" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
h = sys.argv[2]
res = [re.compile(l.strip()[len('path_regexp '):].strip())
       for l in text.splitlines() if l.strip().startswith('path_regexp ')]
clear = []
for abi in ('arm', 'arm64', 'x64'):
    clear.append(f'/flutter_infra_release/flutter/{h}/android-{abi}-profile/darwin-x64.zip')
    clear.append(f'/flutter_infra_release/flutter/{h}/android-{abi}-profile/artifacts.zip')
    clear.append(f'/flutter_infra_release/flutter/{h}/android-{abi}/artifacts.zip')
hit = [p for p in clear if any(r.search(p) for r in res)]
print(f'    cache/transport paths checked: {len(clear)}   wrongly protected: {len(hit)}')
for p in hit:
    print(f'    PROTECTED (should not be) {p}')
sys.exit(1 if hit else 0)
PY
[[ $? -eq 0 ]] && ok "the 10 cache/transport paths stay fallback-permitted (the fix is narrow)" \
               || bad "the fix over-reached into cache/transport paths"

# =============================================================================
note "Z - the LIVE overlay was never written"
[[ ! -d "$LIVE_OVERLAY/flutter_infra_release/flutter/$H2B" ]] \
  && ok "no scratch cell appeared in the live overlay" || bad "the live overlay was written"
[[ -z "$(find "$LIVE_OVERLAY/download.flutter.io" -name "*1.0.0-$H2B*" 2>/dev/null)" ]] \
  && ok "no scratch Maven module appeared in the live overlay" || bad "live Maven tree was written"
out=$(bash "$HERE/verify_cell_members.sh" "$DONOR" 2>&1)
echo "$out" | grep -q "CELL MEMBERS VERIFIED (16/16)" && ok "the donor cell still verifies 16/16, untouched" \
                                                      || bad "the donor cell was disturbed"

echo
echo "  scratch address : $H2"
echo "  scratch overlay : $OV"
echo "  evidence        : $EV2"
if [[ $fail -eq 0 ]]; then echo "RESULT: macos-ios-android CELL QUALIFIED"; else
  echo "RESULT: $fail FAILURE(S)"; exit 1; fi
