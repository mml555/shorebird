#!/usr/bin/env bash
# cspell:words COPYFILE xattr xattrs
# promo_clone.sh -- set up the promotion workspace for a new cell on ci-build by
# cloning the last one that passed, so the chain and arm B run exactly as they
# did for it (selfhost/TOOLCHAIN_PROMOTION.md).
#
# Run from the Mac. It reads the old workspace's env.r12 for the cell, selector
# and selector branch it was pinned to, copies its scripts, TLS and Flutter
# mirror into /srv/ci-cache/shorebird-engine/promo-<8hex of the new cell>, and
# swaps every pin for the new one. The old workspace is only read. evidence/
# and logs/ start empty, so chain step 4 banks fresh ledger rows for this cell.
# selfhost/ci comes from --repo-sha, the head of the PR that selects the cell:
# the chain proves that PR, which merges only after the chain and arm B pass.
#
# Step 7's gate in the cloned bin/chain.sh is selfhost/ci/r12/check_rp_arms.sh
# on the discovery log: the seal refused nothing, both detector self-tests
# fired, arms 1 and 2 passed, and arm 3's single-release exit 0 is the only
# failed check. Chains up to 9995f957 gated on "NOTHING refused by the seal"
# alone and read the arms from the log by hand; a donor with that gate has it
# replaced, and a donor whose gate is neither is refused.
#
# Preconditions it checks before writing anything: --repo-sha pins --selector
# (bin/internal/flutter.version), the live mirror (port 8085) serves the new
# cell's descriptor, the selector branch on shorebird-flutter points at
# --selector, and no workspace for the new cell exists yet. After fetching the
# selector it checks that its bin/internal/engine.version names --cell. The
# workspace is built as promo-<8hex>.partial and renamed only when complete;
# a failure removes it.
#
#   promo_clone.sh --from promo-<old> --cell <40 hex> --selector <40 hex> \
#                  --repo-sha <40 hex> [--host ci-build] [--dry-run]
#
# --dry-run prints what it would pin and changes nothing on ci-build.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
ROOT=/srv/ci-cache/shorebird-engine
HOST=ci-build
FROM="" CELL="" SEL="" RS="" DRY=0

usage() { sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }
while (($#)); do
  case "$1" in
    --from) FROM=${2:-}; shift 2 ;;
    --cell) CELL=${2:-}; shift 2 ;;
    --selector) SEL=${2:-}; shift 2 ;;
    --repo-sha) RS=${2:-}; shift 2 ;;
    --host) HOST=${2:-}; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h | --help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
hex40() { [[ "$2" =~ ^[0-9a-f]{40}$ ]] || { echo "$1 must be a full 40-hex sha, got '$2'" >&2; exit 2; }; }
hex40 --cell "$CELL"; hex40 --selector "$SEL"; hex40 --repo-sha "$RS"
[[ "$FROM" =~ ^promo-[0-9a-z]+$ ]] || { echo "--from must name a workspace like promo-f2458551" >&2; exit 2; }

git -C "$REPO" cat-file -e "$RS^{commit}" 2>/dev/null || { echo "$RS is not in $REPO: fetch it first" >&2; exit 1; }
pin=$(git -C "$REPO" show "$RS:bin/internal/flutter.version" | tr -d '[:space:]')
[[ $pin == "$SEL" ]] || { echo "$RS pins selector '$pin' in bin/internal/flutter.version, not $SEL" >&2; exit 1; }
N8=${CELL:0:8}

remote() {
  ssh "$HOST" bash -s -- "$1" "$ROOT" "$FROM" "$CELL" "$SEL" "$RS" "$HOST" <<'REMOTE'
set -euo pipefail
MODE=$1 ROOT=$2 FROM=$3 NA=$4 NS=$5 RS=$6 HOST=$7
N8=${NA:0:8} O=$ROOT/$FROM N=$ROOT/promo-${NA:0:8}
P=$N.partial TAR=$ROOT/tmp/promo-$N8-ci.tar
[[ -f $O/env.r12 ]] || { echo "no $O/env.r12"; exit 1; }
[[ ! -e $N ]] || { echo "$N exists; it is never overwritten"; exit 1; }
[[ ! -e $P ]] || { echo "$P is left from an interrupted run; remove it first"; exit 1; }
val() { sed -n "s/^export $1=//p" "$O/env.r12"; }
OA=$(val R12_PRODUCER_REVISION) OS=$(val R12_FLUTTER_REVISION) OLD_REF=$(val R12_FLUTTER_REF) ORS=$(val R12_REPO_SHA)
[[ $OA =~ ^[0-9a-f]{40}$ && $OS =~ ^[0-9a-f]{40}$ && $ORS =~ ^[0-9a-f]{40}$ && $OLD_REF == refs/heads/*-cell-${OA:0:8} ]] ||
  { echo "cannot read the old pins from $O/env.r12 (cell '$OA', selector '$OS', ref '$OLD_REF', repo '$ORS')"; exit 1; }
NEW_REF=${OLD_REF%"${OA:0:8}"}$N8
OBR=${OLD_REF#refs/heads/} NBR=${NEW_REF#refs/heads/}

if [[ $MODE == check ]]; then
  echo "from   $FROM: cell $OA, selector $OS, $OBR, repo $ORS"
  echo "to     promo-$N8: cell $NA, selector $NS, $NBR, repo $RS"
  curl -fsS -o /dev/null -D - "http://localhost:8085/download.shorebird.dev/shorebird/cell-manifests/$NA.v2" |
    tr -d '\r' | grep -qi '^x-overlay: hit' || { echo "the live mirror does not serve cell $NA's descriptor"; exit 1; }
  up=$(git -C "$O/mirrors/flutter.git" ls-remote origin "$NEW_REF" | awk '{print $1}')
  [[ $up == "$NS" ]] || { echo "shorebird-flutter $NBR is '$up', expected $NS"; exit 1; }
  echo "preconditions OK"
  exit 0
fi

trap 'rc=$?; rm -f "$TAR"; if ((rc)); then rm -rf "$P"; echo "FAILED: $P removed"; fi' EXIT
mkdir -p "$P/logs" "$P/evidence" "$P/secrets" "$P/ci"
cp -a "$O/bin" "$O/tls" "$O/compose.cold.yaml" "$O/env.r12" "$O/rename.sh" "$O/mirrors" "$P/"
rm -f "$P"/bin/*.orig "$P"/bin/*.bak*
tar -xf "$TAR" -C "$P/ci"
git -C "$P/mirrors/flutter.git" fetch -q origin "+$NEW_REF:$NEW_REF"
[[ $(git -C "$P/mirrors/flutter.git" rev-parse "$NEW_REF") == "$NS" ]] || { echo "mirror $NBR is not $NS"; exit 1; }
ev=$(git -C "$P/mirrors/flutter.git" show "$NS:bin/internal/engine.version" | tr -d '[:space:]')
[[ $ev == "$NA" ]] || { echo "selector $NS selects '$ev', not cell $NA"; exit 1; }
files=("$P/env.r12" "$P/compose.cold.yaml" "$P"/bin/*.sh)
# Workspace paths are rewritten to the FINAL name; the rename below makes them true.
sed -i "s#$FROM#promo-$N8#g; s/$OA/$NA/g; s/$OS/$NS/g; s/$ORS/$RS/g; s#$OBR#$NBR#g" "${files[@]}"
sed -i "s/${OA:0:8}/$N8/g" "${files[@]}"
if grep -n -e "${OA:0:8}" -e "${OS:0:8}" -e "${ORS:0:8}" -e "$FROM" "${files[@]}"; then echo "old pins left above"; exit 1; fi
# Step 7 gates on the arms block, not on the seal alone (check_rp_arms.sh).
C=$P/bin/chain.sh
OLD_GATE='tail -4 $L/rp.log; grep -q "NOTHING refused by the seal" $L/rp.log || die "release/patch discovery: closure not reached"'
NEW_GATE='tail -4 $L/rp.log; bash $P/ci/r12/check_rp_arms.sh $L/rp.log > $L/rp_arms.txt 2>&1; rc=$?; cp $L/rp_arms.txt $E/rp_arms.txt; cat $L/rp_arms.txt; [ $rc = 0 ] || die "release/patch discovery: check_rp_arms.sh exit $rc (logs/rp_arms.txt)"'
OLD_NOTE='# PROMOTION_d12e29ec.md). The gate is the closure: the last iteration refused nothing.'
NEW_NOTE='# PROMOTION_d12e29ec.md). The gate is check_rp_arms.sh: the seal refused nothing, the self-tests fired, arms 1 and 2 passed, and arm 3 is the only failed check.'
[[ -f $P/ci/r12/check_rp_arms.sh ]] || { echo "selfhost/ci at $RS has no r12/check_rp_arms.sh"; exit 1; }
if [[ $(grep -cxF "$NEW_GATE" "$C") != 1 ]]; then
  [[ $(grep -cxF "$OLD_GATE" "$C") == 1 ]] || { echo "$C: step 7's gate is not the known line, so check_rp_arms.sh cannot be put in"; exit 1; }
  awk -v og="$OLD_GATE" -v ng="$NEW_GATE" -v on="$OLD_NOTE" -v nn="$NEW_NOTE" \
    '$0 == og { print ng; next } $0 == on { print nn; next } { print }' "$C" > "$C.new"
  cat "$C.new" > "$C"; rm -f "$C.new"
fi
[[ $(grep -cxF "$NEW_GATE" "$C") == 1 ]] || { echo "$C: step 7 does not gate on check_rp_arms.sh"; exit 1; }
if grep -n 'NOTHING refused by the seal' "$C"; then echo "$C: the line above still gates on the seal alone"; exit 1; fi
bash -n "$C"
grep -qx "export R12_REPO_SHA=$RS" "$P/env.r12" || { echo "env.r12 has no R12_REPO_SHA=$RS"; exit 1; }
mv "$P" "$N"
grep -E 'R12_(FLUTTER_REVISION|FLUTTER_REF|PRODUCER_REVISION|REPO_SHA)=' "$N/env.r12"
echo "promo-$N8 READY"
echo "chain:  ssh $HOST 'bash $N/bin/bg.sh chain $N/bin/chain.sh'"
echo "arm B:  ssh $HOST 'bash $N/bin/bg.sh armB $N/bin/armB_go.sh'   (after the chain prints CHAIN_DONE)"
REMOTE
}

remote check
if ((DRY)); then echo "DRY RUN: nothing written"; exit 0; fi
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
git -C "$REPO" archive "$RS" selfhost/ci | tar -x -C "$T"
# Mac tar adds AppleDouble (._*) entries that GNU tar on ci-build extracts as
# files, and xattr headers (com.apple.provenance) it warns about once per file.
COPYFILE_DISABLE=1 tar --no-xattrs -cf "$T/ci.tar" -C "$T/selfhost/ci" .
scp -q "$T/ci.tar" "$HOST:$ROOT/tmp/promo-$N8-ci.tar"
remote build
