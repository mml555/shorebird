# shellcheck shell=bash
# Shared by the mint scripts. Source it. It runs nothing by itself.
#
# Every per-mint value comes from the env file named by MINT_ENV (see
# mint.env.example). Nothing about one engine or one cell is written in a script.

MINT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

say() { printf '== %s\n' "$*"; }
die() { echo "STOP: $*" >&2; exit 1; }
hex40() { [[ ${2:-} =~ ^[0-9a-f]{40}$ ]] || die "$1 must be 40 lowercase hex characters (got '${2:-}')"; }

# Read the env file and set the defaults. Sets E8, OUT, IN and the other derived values.
load_env() {
  [[ -n ${MINT_ENV:-} ]] || die "set MINT_ENV=<path to your mint env file> (copy mint.env.example)"
  [[ -f $MINT_ENV ]] || die "MINT_ENV=$MINT_ENV does not exist"
  # shellcheck disable=SC1090
  . "$MINT_ENV"
  hex40 E "${E:-}"; hex40 DART "${DART:-}"; hex40 FB "${FB:-}"
  [[ -z ${PREV:-} ]] || hex40 PREV "$PREV"
  [[ -n ${FLUTTER_LINE:-} ]] || die "FLUTTER_LINE is not set in $MINT_ENV (for example 3.50)"
  [[ ${WORK:-} == /* ]] || die "WORK must be an absolute path in $MINT_ENV"
  E8=${E:0:8}
  CELL=${CELL:-macos-ios-android}
  ENGINE_REPO=${ENGINE_REPO:-mml555/shorebird-flutter}
  CELL_REPO=${CELL_REPO:-mml555/shorebird}
  ENGINE_BRANCH=${ENGINE_BRANCH:-selfhost/$FLUTTER_LINE-up}
  FB_BRANCH=${FB_BRANCH:-flutter_release/$FLUTTER_LINE.0}
  OUT=${OUT:-$WORK/out}
  IN=${IN:-$WORK/in}
  MAC_STAGE=${MAC_STAGE:-$WORK/stage-mac/$E}
  LINUX_HALF=${LINUX_HALF:-$WORK/linux-half}
  LINUX_STAGE_REMOTE=${LINUX_STAGE_REMOTE:-/home/oem/engine-stage/$E}
  COMPILER_ZIP=${COMPILER_ZIP:-$IN/route-b-compiler-darwin-arm64.zip}
  PATCH_ZIPS_DIR=${PATCH_ZIPS_DIR:-$IN/patch}
  ENGINE_EXTRA=${ENGINE_EXTRA:-$IN/engine-extra}
  PSDK_ZIP=${PSDK_ZIP:-$LINUX_HALF/flutter_infra_release/flutter/$E/flutter_patched_sdk_product.zip}
  BASE_MANIFEST=${BASE_MANIFEST:-https://download.shorebird.dev/shorebird/$FB/artifacts_manifest.yaml}
  CI_HOST=${CI_HOST:-ci-build}
  CI_TMP=${CI_TMP:-/srv/ci-cache/shorebird-engine/tmp}
  CI_CDN=${CI_CDN:-/srv/ci-cache/shorebird-engine/cdn/selfhost/cdn}
  CONTAINER=${CONTAINER:-shorebird-cdn-cdn-cache-1}
  SELECTOR_BRANCH_PREFIX=${SELECTOR_BRANCH_PREFIX:-selfhost/$FLUTTER_LINE-cell-}
  SELECTOR_REMOTE=${SELECTOR_REMOTE:-origin}
  HEAVY_LOCK=${HEAVY_LOCK:-$HOME/Developer/shorebird-wt/tmp/heavy.lock}
  export E E8 FB DART CELL ENGINE_REPO CELL_REPO ENGINE_BRANCH FB_BRANCH FLUTTER_LINE
}

# Find the selfhost/ helpers (route_b scripts, cdn files, hydrate script).
# They are always exported from a commit, never read from a working tree, so a dirty or stale checkout
# cannot change the address. The default commit is fork/main (the local remote-tracking ref: run
# `git fetch fork` first). HELPERS_REF=<ref> in the env file picks another commit on purpose.
# Sets HELPERS, HELPERS_SHA, RB (route_b dir), CDN_SRC (selfhost/cdn), SCRIPTS (selfhost/scripts).
resolve_helpers() {
  local top ref main_sha; top=$(git -C "$MINT_DIR" rev-parse --show-toplevel) || die "$MINT_DIR is not in a git checkout"
  ref=${HELPERS_REF:-fork/main}
  HELPERS_SHA=$(git -C "$top" rev-parse --verify -q "$ref^{commit}") \
    || die "helper source $ref is not a commit in $top (run: git fetch fork), or set HELPERS_REF to another commit"
  if [[ -n ${HELPERS_REF:-} && $ref != fork/main ]]; then
    main_sha=$(git -C "$top" rev-parse --verify -q "fork/main^{commit}" || true)
    [[ $HELPERS_SHA == "$main_sha" ]] || echo "NOTE: helpers come from HELPERS_REF=$ref ($HELPERS_SHA), not fork/main (${main_sha:-unknown})" >&2
  fi
  HELPERS=$WORK/helpers-$HELPERS_SHA
  if [[ ! -d $HELPERS/selfhost ]]; then
    rm -rf "$HELPERS.tmp"; mkdir -p "$HELPERS.tmp"
    git -C "$top" archive "$HELPERS_SHA" selfhost | tar -x -C "$HELPERS.tmp"
    mv "$HELPERS.tmp" "$HELPERS"
  fi
  RB=$HELPERS/selfhost/engine/route_b; CDN_SRC=$HELPERS/selfhost/cdn; SCRIPTS=$HELPERS/selfhost/scripts
  [[ -f $RB/mint_route_b_cell.sh ]] || die "no selfhost/engine/route_b in $HELPERS ($ref)"
  export HELPERS HELPERS_SHA RB CDN_SRC SCRIPTS
}

# The hash that ends every Caddyfile protection group. Refuses when the groups disagree.
prev_from_caddyfile() { python3 -I "$MINT_DIR/cell_edits.py" derive "$1"; }

# Fill @NAME@ in a template from exported variables. Refuses on an unset name.
render_tmpl() {
  python3 -I -c '
import os, re, sys
t = open(sys.argv[1]).read()
def sub(m):
    k = m.group(1)
    if k not in os.environ:
        sys.exit("template %s: no value for @%s@" % (sys.argv[1], k))
    return os.environ[k]
sys.stdout.write(re.sub(r"@([A-Z][A-Z0-9_]*)@", sub, t))' "$1"
}

# One heavy job at a time on the shared Mac. Releases the lock when the script exits.
take_heavy_lock() { # <label>
  mkdir -p "$(dirname "$HEAVY_LOCK")"
  until mkdir "$HEAVY_LOCK" 2>/dev/null; do say "waiting for $HEAVY_LOCK"; sleep 60; done
  echo "$1 $$ $E" > "$HEAVY_LOCK/owner"
  trap 'rm -f "$HEAVY_LOCK/owner"; rmdir "$HEAVY_LOCK"' EXIT
}
