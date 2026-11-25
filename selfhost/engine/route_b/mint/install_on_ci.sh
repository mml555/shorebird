#!/bin/bash
# install_on_ci.sh -- OWNER-RUN, ON ci-build. publish_engine.sh and publish_cell.sh copy it next to its
# payload, with remote.env and cell_edits.py, and run it. Modes:
#   engine: payload overlay-<E>.tar + experimental_hashes-<E>.map + SHA256SUMS
#           -> overlay, map line, Caddyfile and checker protection for E
#   cell:   payload cell-<A>.tar + files.sha256 + names + tar.sha   (export ADDR=<A>)
#           -> overlay, map line A -> fallback, protection for A
#
#   bash install_on_ci.sh engine          # PLAN: verifies the payload, says what it would install
#   bash install_on_ci.sh engine --run    # installs
#
# Never overwrites an overlay file with different bytes. Validates the Caddyfile in the container
# before the restart, and restores the Caddyfile, checker and map if validation fails.
# The previous hash (the one each Caddyfile group ends with now) is PREV from remote.env (engine mode), or is derived
# from the live Caddyfile. It refuses when the groups do not all end in the same hash.
set -euo pipefail
export LC_ALL=C
MODE=${1:?usage: install_on_ci.sh engine|cell [--run]}
RUN=0; [[ "${2:-}" == --run ]] && RUN=1
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$HERE/remote.env"
: "${E:?remote.env has no E}" "${FB:?remote.env has no FB}" "${CI_CDN:?remote.env has no CI_CDN}" "${CONTAINER:?remote.env has no CONTAINER}"
CDN=$CI_CDN; OV=$CDN/overlay; cd "$HERE"
case $MODE in
  engine) ID=$E ;;
  cell) ID=${ADDR:?export ADDR=<full 40-hex cell address>} ;;
  *) echo "usage: install_on_ci.sh engine|cell [--run]"; exit 2 ;;
esac
[[ $ID =~ ^[0-9a-f]{40}$ ]] || { echo "STOP: $ID is not a 40-hex hash"; exit 1; }
echo "== verify ($MODE $ID)"
if [[ $MODE == engine ]]; then sha256sum -c --quiet SHA256SUMS; TAR=overlay-$E.tar
else sha256sum -c --quiet tar.sha; TAR=cell-$ID.tar; fi
rm -rf x; mkdir x; tar -tf "$TAR" | grep -v '/$' | sed 's#^\./##' | sort > names.clean
if [[ $MODE == cell ]]; then diff names names.clean || { echo "STOP: tar members differ from the names list"; exit 1; }; fi
if grep -Ev '^(flutter_infra_release|download\.flutter\.io|download\.shorebird\.dev)/' names.clean; then echo "STOP: unexpected path"; exit 1; fi
if grep -q '\.\./' names.clean; then echo "STOP: path escapes overlay"; exit 1; fi
if grep -q '\(^\|/\)\._' names.clean; then echo "STOP: AppleDouble entry in the tar"; exit 1; fi
tar -xf "$TAR" -C x --no-same-owner
if [[ $MODE == cell ]]; then (cd x && sha256sum -c --quiet ../files.sha256); fi
echo "$(wc -l < names.clean) files ok"

echo "== install (never overwrite)"
new=0; kept=0
while read -r p; do
  if [[ -e "$OV/$p" ]]; then
    cmp -s "$OV/$p" "x/$p" || { echo "STOP: overlay has a different $p"; exit 1; }
    kept=$((kept+1))
  else
    [[ $RUN == 1 ]] && (cd x && cp --parents -p "$p" "$OV/")
    new=$((new+1))
  fi
done < names.clean
echo "new $new, identical-present $kept"

echo "== map and protection"
cd "$CDN"; ts=$(date +%Y%m%d%H%M%S)
if grep -q "$ID" Caddyfile; then
  echo "Caddyfile already names $ID"
else
  if [[ $MODE == engine && -n "${PREV:-}" ]]; then prev=$PREV; else prev=$(python3 -I "$HERE/cell_edits.py" derive Caddyfile); fi
  # A cell follows its engine in each group, so PREV does not apply to a cell.
  if [[ $MODE == cell && $prev != "$E" ]]; then echo "STOP: Caddyfile groups end in $prev, not in engine $E (install the engine first)"; exit 1; fi
  if [[ $MODE == engine ]]; then LABEL="Flutter $FLUTTER_LINE engine"; else LABEL="Flutter $FLUTTER_LINE: minted cell over engine ${E:0:8}"; fi
  echo "protect $ID after $prev"
  if [[ $RUN == 1 ]]; then
    cp -p Caddyfile "Caddyfile.bak.$ts"; cp -p check_protection_matchers.py "check_protection_matchers.py.bak.$ts"; cp -p experimental_hashes.map "experimental_hashes.map.bak.$ts"
    python3 -I "$HERE/cell_edits.py" protect "$CDN" "$prev" "$ID=$LABEL"
  else
    python3 -I "$HERE/cell_edits.py" protect "$CDN" "$prev" "$ID=$LABEL" --dry-run
  fi
fi
if grep -q "^$ID " experimental_hashes.map; then echo "map already has $ID"
else
  echo "map line: $ID $FB"
  [[ $RUN == 1 ]] && printf '%s %s\n' "$ID" "$FB" >> experimental_hashes.map
fi
[[ $RUN == 1 ]] || { rm -rf "$HERE/x"; echo "PLAN ONLY. Add --run to install."; exit 0; }
python3 check_protection_matchers.py | tail -1

echo "== reload"
restore() {
  [[ -f Caddyfile.bak.$ts ]] || return 0
  cat "Caddyfile.bak.$ts" > Caddyfile; cat "check_protection_matchers.py.bak.$ts" > check_protection_matchers.py
  cat "experimental_hashes.map.bak.$ts" > experimental_hashes.map; echo "restored Caddyfile, checker and map"
}
if ! docker exec "$CONTAINER" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>"$HERE/validate.err"; then
  tail -5 "$HERE/validate.err"; restore; exit 1
fi
docker restart "$CONTAINER" >/dev/null
up=0; for _ in $(seq 1 180); do curl -s -o /dev/null --max-time 5 http://localhost:8085/ && { up=1; break; }; sleep 1; done
[[ $up == 1 ]] || { echo "STOP: mirror not answering after restart"; exit 1; }

echo "== serve check"
ok=0; bad=0
while read -r p; do
  hdr=$(curl -fsS -D - -o "$HERE/got" "http://localhost:8085/$p" | tr -d '\r') || { echo "FAIL fetch $p"; bad=$((bad+1)); continue; }
  if grep -qi '^x-overlay: hit' <<<"$hdr" && cmp -s "$HERE/got" "$OV/$p"; then ok=$((ok+1)); else echo "FAIL $p"; bad=$((bad+1)); fi
done < "$HERE/names.clean"
rm -f "$HERE/got"; echo "served from overlay and identical: $ok, failed: $bad"

echo "== audit"
if [[ $MODE == engine ]]; then cells="linux-android macos-ios macos-ios-android"; else cells="macos-ios macos-ios-android"; fi
for c in $cells; do
  if out=$("$CDN/audit_overlay.sh" --hash "$ID" --cell "$c" 2>&1); then :; else bad=$((bad+1)); fi
  echo "$ID $c: $(tail -1 <<<"$out")"
done
rm -rf "$HERE/x"
if [[ $bad == 0 ]]; then echo "INSTALL OK ($MODE $ID)"; else echo "INSTALL HAS FAILURES"; exit 1; fi
