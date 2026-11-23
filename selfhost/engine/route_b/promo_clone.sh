#!/usr/bin/env bash
# cspell:words COPYFILE xattrs
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
# Preconditions it checks: the live mirror (port 8085) serves the new cell's
# descriptor, the selector branch on shorebird-flutter points at --selector,
# and no workspace for the new cell exists yet.
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

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }
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
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
git -C "$REPO" archive "$RS" selfhost/ci | tar -x -C "$T"
# Mac tar hides AppleDouble (._*) entries that GNU tar on ci-build extracts.
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -cf "$T/ci.tar" -C "$T/selfhost/ci" .
N8=${CELL:0:8}
if ((DRY == 0)); then
  scp -q "$T/ci.tar" "$HOST:$ROOT/tmp/promo-$N8-ci.tar"
fi

ssh "$HOST" bash -s -- "$ROOT" "$FROM" "$CELL" "$SEL" "$RS" "$DRY" "$HOST" <<'REMOTE'
set -euo pipefail
ROOT=$1 FROM=$2 NA=$3 NS=$4 RS=$5 DRY=$6 HOST=$7
N8=${NA:0:8} O=$ROOT/$FROM N=$ROOT/promo-${NA:0:8}
[[ -f $O/env.r12 ]] || { echo "no $O/env.r12"; exit 1; }
[[ ! -e $N ]] || { echo "$N exists; it is never overwritten"; exit 1; }
val() { sed -n "s/^export $1=//p" "$O/env.r12"; }
OA=$(val R12_PRODUCER_REVISION) OS=$(val R12_FLUTTER_REVISION) OLD_REF=$(val R12_FLUTTER_REF)
[[ $OA =~ ^[0-9a-f]{40}$ && $OS =~ ^[0-9a-f]{40}$ && $OLD_REF == refs/heads/*-cell-${OA:0:8} ]] ||
  { echo "cannot read the old pins from $O/env.r12 (cell '$OA', selector '$OS', ref '$OLD_REF')"; exit 1; }
NEW_REF=${OLD_REF%"${OA:0:8}"}$N8
OBR=${OLD_REF#refs/heads/} NBR=${NEW_REF#refs/heads/}
echo "from   $FROM: cell $OA, selector $OS, $OBR"
echo "to     promo-$N8: cell $NA, selector $NS, $NBR, repo $RS"

curl -fsS -o /dev/null -D - "http://localhost:8085/download.shorebird.dev/shorebird/cell-manifests/$NA.v2" |
  tr -d '\r' | grep -qi '^x-overlay: hit' || { echo "the live mirror does not serve cell $NA's descriptor"; exit 1; }
up=$(git -C "$O/mirrors/flutter.git" ls-remote origin "$NEW_REF" | awk '{print $1}')
[[ $up == "$NS" ]] || { echo "shorebird-flutter $NBR is '$up', expected $NS"; exit 1; }
if ((DRY)); then echo "DRY RUN: nothing written"; exit 0; fi

mkdir -p "$N/logs" "$N/evidence" "$N/secrets" "$N/ci"
cp -a "$O/bin" "$O/tls" "$O/compose.cold.yaml" "$O/env.r12" "$O/rename.sh" "$O/mirrors" "$N/"
rm -f "$N"/bin/*.orig "$N"/bin/*.bak*
tar -xf "$ROOT/tmp/promo-$N8-ci.tar" -C "$N/ci" && rm -f "$ROOT/tmp/promo-$N8-ci.tar"
files=("$N/env.r12" "$N/compose.cold.yaml" "$N"/bin/*.sh)
sed -i "s#$FROM#promo-$N8#g; s/$OA/$NA/g; s/$OS/$NS/g; s#$OBR#$NBR#g; s/^export R12_REPO_SHA=.*/export R12_REPO_SHA=$RS/" "${files[@]}"
sed -i "s/${OA:0:8}/$N8/g" "${files[@]}"
git -C "$N/mirrors/flutter.git" fetch -q origin "+$NEW_REF:$NEW_REF"
[[ $(git -C "$N/mirrors/flutter.git" rev-parse "$NEW_REF") == "$NS" ]] || { echo "mirror $NBR is not $NS"; exit 1; }
if grep -n -e "${OA:0:8}" -e "$OS" -e "$FROM" "${files[@]}"; then echo "old pins left above"; exit 1; fi
grep -E 'R12_(FLUTTER_REVISION|FLUTTER_REF|PRODUCER_REVISION|REPO_SHA)=' "$N/env.r12"
echo "promo-$N8 READY"
echo "chain:  ssh $HOST 'bash $N/bin/bg.sh chain $N/bin/chain.sh'"
echo "arm B:  ssh $HOST 'bash $N/bin/bg.sh armB $N/bin/armB_go.sh'   (after the chain prints CHAIN_DONE)"
REMOTE
