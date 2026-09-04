#!/usr/bin/env bash
# cspell:words armv seatbelt
# SELFHOST-DISTRIBUTION-1 gate 3 proof: the durable distribution is sufficient,
# and it is falsifiable.
#
# Every positive step downloads from the RELEASE. Nothing reads the repository's
# overlay -- and the last control proves that by making it unreadable.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/../.." >/dev/null 2>&1 && pwd)"
CELL=${CELL:-f85251f344600ae08196925a174e9cff8f0ff18e}
OTHER=cd848320d605ff8af5060cabf9a8d1b35853f752
BASEURL=${BASEURL:-https://github.com/mml555/shorebird/releases/download/cell-f85251f3}
W=${W:-/Volumes/build/route-b/sd1/proof}
PRODCDN=${PRODCDN:-http://localhost:8085}
fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
note(){ printf '\n\033[1m== %s\033[0m\n' "$1"; }
rm -rf "$W"; mkdir -p "$W"

note "1 - download into an EMPTY directory, anonymously"
D="$W/dist"; mkdir -p "$D"
for f in "cell-$CELL.tar" cell_manifest.v2 LAYOUT.txt MANIFEST.sha256 CELL.txt; do
  env -i PATH=/usr/bin:/bin HOME=/nonexistent \
    curl -fsSL "$BASEURL/$f" -o "$D/$f" || bad "could not download $f"
done
ls -la "$D" | tail -6 | sed 's/^/    /'
[[ -s "$D/cell-$CELL.tar" ]] && ok "the bundle downloaded ($(du -h "$D/cell-$CELL.tar" | cut -f1))" \
                             || bad "the bundle did not download"
GOT=$(shasum -a 256 "$D/cell-$CELL.tar" | cut -d' ' -f1)
WANT=$(sed -nE 's/^bundle_sha256 ([0-9a-f]+)/\1/p' "$D/CELL.txt")
[[ -n "$WANT" && "$GOT" == "$WANT" ]] && ok "the downloaded bundle matches the recorded sha256" \
                                      || bad "bundle sha256 $GOT != recorded $WANT"
# And against the digest committed in the RECORD, not just the one shipped
# beside the bundle -- a tampered release could rewrite both.
REC=$(sed -nE 's/^[[:space:]]*bundle_sha256:[[:space:]]*([0-9a-f]+).*/\1/p' \
       "$REPO/selfhost/engine/route_b/SUPPORTED_STATE.yaml" | head -1)
[[ "$GOT" == "$REC" ]] && ok "and it matches the digest committed in SUPPORTED_STATE.yaml" \
                       || bad "bundle does not match the committed digest $REC"

note "2 - hydrate, verify 30/30, recompute the address"
bash "$HERE/sd1_hydrate_cell.sh" --dist "$D" --overlay "$W/overlay" > "$W/hydrate.log" 2>&1
if grep -q "CELL HYDRATED FROM THE DURABLE DISTRIBUTION" "$W/hydrate.log"; then
  grep -E "PASS|CELL MEMBERS VERIFIED" "$W/hydrate.log" | sed 's/\x1b\[[0-9;]*m//g;s/^/    /'
  ok "hydrated and verified from the download alone"
else
  bad "hydration failed"; tail -8 "$W/hydrate.log" | sed 's/^/    /'
fi

note "3 - serve the reconstructed tree over HTTP, and compare it to the real CDN"
# WHAT THIS DOES AND DOES NOT ESTABLISH, stated because the intended form of
# this step did not run. A second Caddy instance over the hydrated overlay could
# not be started: the compose build never completed and `docker ps` stopped
# answering, so the daemon on this host is degraded. Rather than assert the
# result, two measurements that together carry the same claim:
#
#   3a the reconstructed hierarchy is directly serveable over HTTP and the bytes
#      survive the round trip;
#   3b every member fetched through the REAL production CDN is byte-identical to
#      the reconstructed file -- so that same configuration pointed at this tree
#      returns identical bytes.
#
# NOT established here: the hydrated tree exercised through Caddy's own rewrite
# and @must_be_local rules. Those were proven for this cell in
# ANDROID-CELL-SUPPLY-2 gate 5, against a tree these measurements show is
# byte-identical.
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
( cd "$W/overlay" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 40); do
  curl -fsS -o /dev/null "http://127.0.0.1:$PORT/flutter_infra_release/flutter/$CELL/engine_stamp.json" 2>/dev/null && break
  sleep 0.25
done
n=0; served=0; same=0
while read -r rel want bytes; do
  [[ "$rel" == \#* || -z "$rel" ]] && continue
  n=$((n+1))
  h=$(curl -fsSL "http://127.0.0.1:$PORT/$rel" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
  [[ "$h" == "$want" ]] && served=$((served+1)) || echo "    NOT SERVEABLE: $rel"
  # 3b: the same path through the production CDN, compared to the local file.
  p=$(curl -fsSL "$PRODCDN/$rel" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
  [[ -n "$p" && "$p" == "$want" ]] && same=$((same+1)) || echo "    PRODUCTION CDN DIFFERS: $rel"
done < "$D/LAYOUT.txt"
kill $SRV 2>/dev/null
[[ "$served" == "$n" && "$n" -gt 0 ]] \
  && ok "3a: $served of $n members serveable over HTTP from the reconstructed tree" \
  || bad "3a: $served of $n serveable"
[[ "$same" == "$n" ]] \
  && ok "3b: $same of $n identical to what the production CDN serves" \
  || bad "3b: $same of $n identical to the production CDN"

note "4 - NEGATIVE: a missing distribution part must fail"
cp -R "$D" "$W/d_missing"; rm -f "$W/d_missing/LAYOUT.txt"
if bash "$HERE/sd1_hydrate_cell.sh" --dist "$W/d_missing" --overlay "$W/o_missing" >"$W/n1.log" 2>&1; then
  bad "hydration SUCCEEDED with LAYOUT.txt missing"
else
  grep -m1 "missing" "$W/n1.log" | sed 's/\x1b\[[0-9;]*m//g;s/^/      /'
  ok "refused: the distribution is incomplete"
fi

note "5 - NEGATIVE: one mutated byte must fail"
cp -R "$D" "$W/d_mutated"
python3 - "$W/d_mutated/cell-$CELL.tar" <<'PY'
import sys
with open(sys.argv[1], 'r+b') as f:
    f.seek(4096); b = f.read(1); f.seek(4096); f.write(bytes([b[0] ^ 0x01]))
PY
if bash "$HERE/sd1_hydrate_cell.sh" --dist "$W/d_mutated" --overlay "$W/o_mutated" >"$W/n2.log" 2>&1; then
  bad "hydration SUCCEEDED with a mutated bundle byte"
else
  grep -mE1 "MANIFEST|BYTES DIFFER|does not match" "$W/n2.log" 2>/dev/null | head -1 | sed 's/\x1b\[[0-9;]*m//g;s/^/      /'
  grep -m1 "FAIL" "$W/n2.log" | sed 's/\x1b\[[0-9;]*m//g;s/^/      /'
  ok "refused: a single flipped byte is detected"
fi

note "6 - NEGATIVE: the WRONG cell's descriptor must fail"
cp -R "$D" "$W/d_wrong"
cp "$REPO/selfhost/engine/route_b/cell_manifests/$OTHER.v2" "$W/d_wrong/cell_manifest.v2"
( cd "$W/d_wrong" && shasum -a 256 "cell-$CELL.tar" cell_manifest.v2 LAYOUT.txt > MANIFEST.sha256 )
if bash "$HERE/sd1_hydrate_cell.sh" --dist "$W/d_wrong" --overlay "$W/o_wrong" >"$W/n3.log" 2>&1; then
  bad "hydration SUCCEEDED with another cell's descriptor"
else
  grep -m1 "recomputes to" "$W/n3.log" | sed 's/\x1b\[[0-9;]*m//g;s/^/      /'
  ok "refused: the descriptor does not authenticate this address"
fi
# Note this control regenerated MANIFEST.sha256 on purpose, so it could not
# pass merely because the checksum file disagreed -- the refusal has to come
# from the descriptor not recomputing to the address.

note "7 - and it must succeed with the LOCAL OVERLAY UNREADABLE"
# The whole point of the lane. A Seatbelt profile denies the repository's
# overlay; the hydration must still work, because it reads only the download.
PROF="$W/deny_overlay.sb"
{
  echo '(version 1)'
  echo '(allow default)'
  echo "(deny file-read* (subpath \"$REPO/selfhost/cdn/overlay\"))"
  echo "(deny file-read* (subpath \"$REPO/selfhost/cdn/mirrors\"))"
} > "$PROF"
if sandbox-exec -f "$PROF" /bin/ls "$REPO/selfhost/cdn/overlay" >/dev/null 2>&1; then
  bad "the overlay is still readable inside the sandbox — this control proves nothing"
else
  ok "the repository overlay is provably unreadable inside the sandbox"
fi
if sandbox-exec -f "$PROF" /bin/bash "$HERE/sd1_hydrate_cell.sh" \
     --dist "$D" --overlay "$W/o_sandboxed" > "$W/n4.log" 2>&1; then
  grep -m1 "CELL MEMBERS VERIFIED" "$W/n4.log" | sed 's/^/      /'
  ok "hydration SUCCEEDS with the local overlay denied — the distribution is self-sufficient"
else
  bad "hydration failed when the local overlay was denied"; tail -6 "$W/n4.log" | sed 's/^/      /'
fi

note "RESULT"
if [[ $fail -eq 0 ]]; then echo "  GATE 3 PROVEN"; else echo "  GATE 3: $fail FAILURE(S)"; exit 1; fi
