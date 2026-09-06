#!/usr/bin/env bash
# cspell:words imagetools spp buildx pubspec DPORT REGPORT VOLNAME containerimage dhealth setimg gittag
# SERVER-IMAGE-PROVENANCE-1 — certification pass.
#
# One invariant: a server version names ONE source revision, ONE multi-arch
# manifest digest, and one permanently retrievable set of bytes.
#
# Everything runs against a throwaway local registry. The published :1.3.0 is
# NOT touched: it is preserved deliberately as evidence of the release-process
# defect this lane repairs.
#
# Two real releases are built from real source trees and pushed per
# architecture exactly the way the workflow does (buildx push-by-digest,
# provenance off), so the manifest-list mechanics under test are the real ones.
set -uo pipefail
REPO=${REPO:-/Users/mendell/shorebird}
PKG="$REPO/packages/code_push_server"
WORK=${WORK:-/Volumes/build/spp1}
REGPORT=${REGPORT:-5555}
REG="127.0.0.1:${REGPORT}/cps"
BUILDER=${BUILDER:-spp1builder}
PASS=0; FAIL=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
chk(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (want '$3', got '$2')"; fi; }
step(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
dig(){ docker buildx imagetools inspect "$1" 2>/dev/null | awk '/^Digest:/{print $2; exit}' || true; }

# LEGACY=1 substitutes the publisher this lane replaces, copied from the merge
# job of the workflow as it was: the version comes from whatever pubspec.yaml
# the built ref happens to carry, every tag is applied unconditionally, and
# `latest` follows any tag push. It is here so the same checks can be run
# against it -- a provenance suite that passes both ways would be measuring
# nothing.
legacy_publish(){ # commit git_tag children
  local commit=$1 gittag=$2 children=$3 version args=()
  version="$(git -C "$REPO" show "${commit}:packages/code_push_server/pubspec.yaml" \
    | sed -n 's/^version: *//p' | head -1)"
  args=(--tag "${REG}:${version}")
  [[ -n "$gittag" ]] && args+=(--tag "${REG}:${gittag}")
  [[ -n "$gittag" ]] && args+=(--tag "${REG}:latest")
  for d in $children; do args+=("${REG}@${d}"); done
  docker buildx imagetools create "${args[@]}" >/dev/null 2>&1
  echo "legacy publish: ${REG}:${version} <- ${children%% *}"
}

publish(){ # MODE VERSION COMMIT GIT_TAG "child…" OUT
  if [[ "${LEGACY:-0}" == 1 ]]; then
    legacy_publish "$3" "$4" "$5"
    # The old publisher produced no provenance record. Synthesise the minimum
    # the later steps read, so they fail on the registry state rather than on
    # a missing file.
    python3 - "$6" "$REG" "$3" <<'PY'
import json, subprocess, sys
out, image, commit = sys.argv[1:4]
try:
    d = subprocess.run(["docker","buildx","imagetools","inspect",f"{image}:latest"],
                       capture_output=True, text=True).stdout
    dig = [l.split()[1] for l in d.splitlines() if l.startswith("Digest:")][0]
except Exception:
    dig = ""
json.dump({"image": image, "manifest_digest": dig, "commit": commit,
           "semantic_tag": "", "retention_ref": "", "git_tag": "",
           "child_digests": []}, open(out, "w"))
PY
    return 0
  fi
  IMAGE="$REG" MODE=$1 VERSION=$2 COMMIT=$3 GIT_TAG=$4 CHILD_DIGESTS="$5" OUT=$6 \
    bash "$PKG/ops/release/publish_release.sh" 2>&1 | grep -vE '^#[0-9]'
}
build_children(){ # srcdir prefix -> echoes "amd64digest arm64digest"
  local src=$1 pre=$2 a b
  for p in amd64 arm64; do
    docker buildx build --builder "$BUILDER" --platform "linux/$p" --provenance=false \
      --output "type=image,name=${REG},push-by-digest=true,name-canonical=true,push=true" \
      --metadata-file "$WORK/${pre}_$p.json" "$src" >/dev/null 2>&1 \
      || { echo ""; return 1; }
  done
  a=$(python3 -c "import json;print(json.load(open('$WORK/${pre}_amd64.json'))['containerimage.digest'])")
  b=$(python3 -c "import json;print(json.load(open('$WORK/${pre}_arm64.json'))['containerimage.digest'])")
  echo "$a $b"
}

step "0. a throwaway registry, and two real releases built from real trees"
docker rm -f spp1reg >/dev/null 2>&1
docker run -d --name spp1reg -p "127.0.0.1:${REGPORT}:5000" registry:2 >/dev/null 2>&1
for _ in $(seq 1 30); do curl -fsS "http://127.0.0.1:${REGPORT}/v2/" >/dev/null 2>&1 && break; sleep 1; done
chk "the registry is up" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${REGPORT}/v2/")" "200"

COMMIT_A=$(git -C "$REPO" rev-list -n1 code_push_server-v1.3.0)
COMMIT_B=$(git -C "$REPO" rev-parse HEAD)
rm -rf "$WORK/srcA" "$WORK/srcB"; mkdir -p "$WORK/srcA" "$WORK/srcB"
git -C "$REPO" archive code_push_server-v1.3.0 packages/code_push_server | tar x -C "$WORK/srcA" --strip-components=2
git -C "$REPO" archive HEAD packages/code_push_server | tar x -C "$WORK/srcB" --strip-components=2
read -r A_AMD A_ARM <<<"$(build_children "$WORK/srcA" chA)"
read -r B_AMD B_ARM <<<"$(build_children "$WORK/srcB" chB)"
[[ -n "$A_AMD" && -n "$A_ARM" && -n "$B_AMD" && -n "$B_ARM" ]] \
  && ok "both releases built for amd64 and arm64 ($A_AMD / $A_ARM, $B_AMD / $B_ARM)" \
  || { no "could not build both architectures"; echo "  aborting"; exit 2; }

step "1. version is bound to source, and a disagreement refuses"
out=$(bash "$PKG/ops/release/resolve_release.sh" code_push_server-v1.3.0 2>&1)
printf '%s' "$out" | grep -q "^mode=release" && ok "code_push_server-v1.3.0 is a release" || no "not recognised as a release: $out"
printf '%s' "$out" | grep -q "^commit=$COMMIT_A" && ok "and resolves to exactly one commit" || no "wrong commit"
out=$(bash "$PKG/ops/release/resolve_release.sh" selfhost-v1.1.1 2>&1)
printf '%s' "$out" | grep -q "^mode=traceability" \
  && ok "selfhost-v1.1.1 is traceability only, and claims no version" || no "selfhost tag was treated as a release"
# The historical cause: that tag's pubspec says 1.3.0. Reading the version was
# never enough to know which release was being cut.
printf '%s' "$out" | grep -q "^pubspec_version=1.3.0" \
  && ok "  even though its pubspec still says 1.3.0" || no "  expected its pubspec to say 1.3.0"

step "2. release A publishes, and every reference the release claims resolves to it"
publish release 1.3.0 "$COMMIT_A" code_push_server-v1.3.0 "$A_AMD $A_ARM" "$WORK/relA.json" | sed 's/^/  /'
DA=$(python3 -c "import json;print(json.load(open('$WORK/relA.json'))['manifest_digest'])" 2>/dev/null || echo "")
[[ -n "$DA" ]] && ok "release A published as $DA" || { no "release A did not publish"; }
chk "  :1.3.0 resolves to it" "$(dig "${REG}:1.3.0")" "$DA"
chk "  :latest follows the release" "$(dig "${REG}:latest")" "$DA"
chk "  the retention reference resolves to it" "$(dig "${REG}:source-${COMMIT_A}")" "$DA"
kids=$(docker buildx imagetools inspect --raw "${REG}@${DA}" | python3 "$PKG/ops/release/manifest_children.py" | awk '{print $1}')
printf '%s\n' "$kids" | grep -qx "$A_AMD" && printf '%s\n' "$kids" | grep -qx "$A_ARM" \
  && ok "  and both architecture digests are bound into it" || no "  the manifest does not carry both children"

step "3. the historical failure, replayed through the repaired publisher"
# selfhost-v1.1.1's pubspec says 1.3.0. Under the old publisher that is what
# overwrote :1.3.0 and moved :latest. Here it must be able to do neither.
publish traceability "" "$COMMIT_B" selfhost-v1.1.1 "$B_AMD $B_ARM" "$WORK/relT.json" | sed 's/^/  /'
chk "  :1.3.0 still resolves to release A" "$(dig "${REG}:1.3.0")" "$DA"
chk "  :latest still resolves to release A" "$(dig "${REG}:latest")" "$DA"
DT=$(dig "${REG}:selfhost-v1.1.1")
[[ -n "$DT" && "$DT" != "$DA" ]] && ok "  and the distribution tag published its own bytes ($DT)" \
  || no "  the traceability tag did not publish"

step "4. a semantic version is write-once"
out=$(publish release 1.3.0 "$COMMIT_B" code_push_server-v1.3.0 "$B_AMD $B_ARM" "$WORK/relX.json")
if printf '%s' "$out" | grep -q "write-once"; then ok "republishing 1.3.0 from a different commit is refused"
else no "1.3.0 was republished from a different commit: $(printf '%s' "$out" | grep -vE '^\s*$' | tail -2 | tr '\n' ' ')"; fi
chk "  and :1.3.0 is unmoved" "$(dig "${REG}:1.3.0")" "$DA"
out=$(publish release 1.3.0 "$COMMIT_A" code_push_server-v1.3.0 "$A_AMD $A_ARM" "$WORK/relA2.json")
printf '%s' "$out" | grep -q "already released" && ok "re-running the SAME release is idempotent" \
  || no "a rerun was not recognised as idempotent"
chk "  and still :1.3.0" "$(dig "${REG}:1.3.0")" "$DA"

step "5. a manual build cannot mutate a semantic tag or latest"
publish dispatch "" "$COMMIT_B" "" "$B_AMD $B_ARM" "$WORK/relD.json" | sed 's/^/  /'
chk "  :1.3.0 unmoved by a dispatch build" "$(dig "${REG}:1.3.0")" "$DA"
chk "  :latest unmoved by a dispatch build" "$(dig "${REG}:latest")" "$DA"
DD=$(dig "${REG}:source-${COMMIT_B}")
[[ -n "$DD" ]] && ok "  but its bytes are retained under their source reference" || no "  the dispatch build kept nothing"

step "6. a later release does not disturb the earlier one's bytes"
# Release B as a NEW version, the way a real successor would be cut.
publish release 1.4.0 "$COMMIT_B" code_push_server-v1.4.0 "$B_AMD $B_ARM" "$WORK/relB.json" | sed 's/^/  /'
DB=$(python3 -c "import json;print(json.load(open('$WORK/relB.json'))['manifest_digest'])" 2>/dev/null || echo "")
chk "  :latest moves to the new release" "$(dig "${REG}:latest")" "$DB"
chk "  :1.3.0 still names release A" "$(dig "${REG}:1.3.0")" "$DA"
chk "  A's retention reference is untouched" "$(dig "${REG}:source-${COMMIT_A}")" "$DA"

step "7. release A is still RETRIEVABLE from a clean store, by its recorded identity alone"
# Clear by image ID for every entry whose REPOSITORY is this registry. A
# `--filter reference=` sweep left two behind, which would have made the pull
# below a no-op against a cached image -- the check would have passed without
# retrieving anything.
docker images --format '{{.Repository}} {{.ID}}' \
  | awk -v r="127.0.0.1:${REGPORT}/cps" '$1==r{print $2}' | sort -u \
  | while read -r id; do docker rmi -f "$id" >/dev/null 2>&1; done
chk "  the local store no longer holds it" \
  "$(docker images --format '{{.Repository}}' | grep -c "^127.0.0.1:${REGPORT}/cps\$")" "0"
if docker pull -q "${REG}@${DA}" >/dev/null 2>&1; then ok "  pulled by digest from a clean store"
else no "  could not pull release A by its recorded digest"; fi
bash "$PKG/ops/release/verify_release.sh" "$WORK/relA.json" 2>&1 | sed 's/^/  /'
bash "$PKG/ops/release/verify_release.sh" "$WORK/relA.json" >/dev/null 2>&1 \
  && ok "  and it verifies against its banked provenance record" \
  || no "  release A no longer verifies against its record"

step "8. the rollback contract still holds across a later release"
# This is the tie-back. UPGRADE-ROLLBACK-1 made restore refuse anything but the
# recorded build; that is only half of recoverability. The other half is that
# the recorded build is still THERE after later releases have moved every
# human-facing alias.
DEP="$WORK/deploy"; DPORT=18095
rm -rf "$DEP"; mkdir -p "$DEP/ops/lib"
cp "$PKG/setup.sh" "$PKG/docker-compose.yaml" "$DEP/"
cp "$PKG"/ops/lib/*.sh "$DEP/ops/lib/"
cat > "$DEP/.env" <<ENV
API_KEY=sb_api_spp1
URL_SIGNING_SECRET=$(openssl rand -hex 32)
LOGIN_EMAIL=spp1@self-host.local
PUBLIC_BASE_URL=http://localhost:${DPORT}
HOST_BIND=127.0.0.1
PORT=${DPORT}
ENV
setimg(){ sed -i '' "s|^    image: .*|    image: $1|" "$DEP/docker-compose.yaml"; }
dhealth(){ curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${DPORT}/healthz" 2>/dev/null; }
docker pull -q "${REG}:1.3.0" >/dev/null 2>&1
setimg "${REG}:1.3.0"
( cd "$DEP" && docker compose up -d >/dev/null 2>&1 )
for _ in $(seq 1 120); do [[ "$(dhealth)" == 200 ]] && break; sleep 1; done
chk "  a deployment running release A by its tag" "$(dhealth)" "200"
BASE="http://127.0.0.1:${DPORT}" KEY=sb_api_spp1 OUT="$DEP/seed" TAG=spp1   bash "$REPO/selfhost/scripts/br1_seed.sh" >/dev/null 2>&1 && ok "  seeded" || no "  seeding failed"
( cd "$DEP" && bash setup.sh --backup >/dev/null 2>&1 )
BKF=$(ls -t "$DEP"/backups/*.tgz 2>/dev/null | head -1)
REC_ID=$(tar xzOf "$BKF" ./MANIFEST.json 2>/dev/null | sed -n 's/.*"server_image_id": "\([^"]*\)".*/\1/p' | head -1)
chk "  the backup records release A's manifest digest" "$REC_ID" "${REG}@${DA}"
# Remove the container as well as the image: a stopped container still holds
# its image, so `docker rmi -f` only untagged it and the "is it gone" arm
# passed while the image was still resolvable. This is also the honest shape of
# the scenario -- months later, on a different host, nothing local remains.
( cd "$DEP" && docker compose down >/dev/null 2>&1 )
docker images --format '{{.Repository}} {{.ID}}' \
  | awk -v r="127.0.0.1:${REGPORT}/cps" '$1==r{print $2}' | sort -u \
  | while read -r id; do docker rmi -f "$id" >/dev/null 2>&1; done
chk "  nothing local is left of that registry" \
  "$(docker images --format '{{.Repository}}' | grep -c "^127.0.0.1:${REGPORT}/cps\$")" "0"

# With no container to resolve the volume from, the operator names it -- the
# documented escape hatch from BACKUP-RESTORE-1.
VOLNAME=$(docker volume ls -q | grep 'cps_data$' | head -1)
echo "  (volume resolved as: '${VOLNAME:-<empty>}')"
out=$( cd "$DEP" && bash setup.sh --restore "$BKF" --volume "$VOLNAME" 2>&1 ); rc=$?
printf '%s\n' "$out" > "$WORK/dbg_gone.txt"
if (( rc != 0 )) && printf '%s' "$out" | grep -q "cannot resolve"; then
  ok "  with the image gone, restore refuses rather than guessing"
else no "  restore did not fail closed on an unresolvable image: $(printf '%s' "$out" | grep -vE '^\s*$' | tail -2 | tr '\n' ' ')"; fi

# Reacquire using ONLY what the backup and the release record carry.
docker pull -q "${REG}@${DA}" >/dev/null 2>&1 \
  && ok "  release A is reacquirable by its recorded digest alone" \
  || no "  release A could not be pulled by digest"
setimg "${REG}@${DA}"
out=$( cd "$DEP" && bash setup.sh --restore "$BKF" --volume "$VOLNAME" 2>&1 ); rc=$?
printf '%s\n' "$out" > "$WORK/dbg_accept.txt"
if (( rc == 0 )); then ok "  and the digest-enforced restore accepts it"
else no "  the restore was refused: $(printf '%s' "$out" | grep -vE '^\s*$' | tail -2 | tr '\n' ' ')"; fi
( cd "$DEP" && docker compose up -d >/dev/null 2>&1 )
for _ in $(seq 1 120); do [[ "$(dhealth)" == 200 ]] && break; sleep 1; done
chk "  the recovered deployment serves" "$(dhealth)" "200"

# And the control: a different release is not accepted in its place.
( cd "$DEP" && docker compose stop server >/dev/null 2>&1 )
docker pull -q "${REG}@${DT}" >/dev/null 2>&1
setimg "${REG}@${DT}"
out=$( cd "$DEP" && bash setup.sh --restore "$BKF" --volume "$VOLNAME" 2>&1 ); rc=$?
if (( rc != 0 )) && printf '%s' "$out" | grep -q "a different build"; then
  ok "  and a different release is refused in its place"
else no "  a different release was accepted for release A's backup"; fi
( cd "$DEP" && docker compose down -v >/dev/null 2>&1 )

step "RESULT"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ))
