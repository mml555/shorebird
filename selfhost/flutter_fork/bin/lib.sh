# Shared helpers for ~/shorebird-engine/bin/*. Source it; do not run it.
# shellcheck shell=bash
W="${SHOREBIRD_ENGINE_DIR:-$HOME/shorebird-engine}"
WT="${SHOREBIRD_WT_DIR:-$HOME/Developer/shorebird-wt}"
HEAVY_LOCK="$WT/tmp/heavy.lock"
FROZEN_TREE="$W/flutter"          # d0714887, the supported cell's engine. Never modified.
# out/ configs the supported cell needs; `clean` keeps them unless --include-supported.
# shellcheck disable=SC2034  # read by clean
SUPPORTED_CONFIGS="ios_release ios_release_rb ios_release_rb_gen host_release_arm64_ddm host_release_arm64 engine_stamp.json"

# shellcheck disable=SC1091
source "$W/env.sh"

say()  { echo "==> $*"; }
warn() { echo "warning: $*" >&2; }
die()  { echo "error: $*" >&2; exit 1; }

# tree_dir NAME: 347|flutter -> frozen tree, 350|flutter-350, anything else -> flutter-NAME.
tree_dir() {
  case "$1" in
    347|flutter) echo "$W/flutter" ;;
    350|flutter-350) echo "$W/flutter-350" ;;
    /*) echo "$1" ;;
    flutter-*) echo "$W/$1" ;;
    *) echo "$W/flutter-$1" ;;
  esac
}
# Fails closed: if either path cannot be resolved, the tree counts as frozen.
is_frozen() {
  local a b
  a="$(cd "$1" 2>/dev/null && pwd -P)" || return 0
  b="$(cd "$FROZEN_TREE" 2>/dev/null && pwd -P)" || return 0
  [[ -n "$a" && -n "$b" ]] || return 0
  [[ "$a" == "$b" ]]
}
require_tree() { [[ -d "$1/engine/src" && -e "$1/.git" ]] || die "not a Flutter source tree: $1"; }

free_gb() { df -g / | awk 'NR==2 {print $4}'; }
need_disk() {
  local have; have="$(free_gb)"
  say "free disk: ${have} GB (need ${1:-20})"
  # Time Machine local snapshots can make df understate free space; macOS purges them
  # under pressure. Do not delete snapshots. Stop and report instead.
  [[ "$have" -ge "${1:-20}" ]] || die "less than ${1:-20} GB free; stop and report (do not delete snapshots)"
}

# Heavy work (gclient sync, ninja) is serialized across agents by a mkdir lock.
HEAVY_OWNED=0
heavy_acquire() {
  local waited=0
  mkdir -p "$(dirname "$HEAVY_LOCK")"
  while ! mkdir "$HEAVY_LOCK" 2>/dev/null; do
    if (( waited % 300 == 0 )); then say "waiting for $HEAVY_LOCK (${waited}s)"; fi
    sleep 30; waited=$((waited + 30))
    if [[ -n "${HEAVY_TIMEOUT:-}" && "$waited" -ge "$HEAVY_TIMEOUT" ]]; then die "heavy lock still held after ${waited}s"; fi
  done
  HEAVY_OWNED=1
  trap heavy_release EXIT
  say "holding $HEAVY_LOCK"
}
heavy_release() {
  if [[ "$HEAVY_OWNED" == 1 ]]; then rmdir "$HEAVY_LOCK" 2>/dev/null || true; HEAVY_OWNED=0; say "released $HEAVY_LOCK"; fi
}

# Effective Dart fork revision: .gclient custom_vars wins over DEPS.
dart_rev_effective() {
  local tree="$1" v
  v="$(python3 - "$tree" <<'PY'
import re, sys
tree = sys.argv[1]
g = open(tree + "/.gclient").read()
m = re.search(r'"dart_sdk_revision"\s*:\s*"([^"]+)"', g)
if m:
    print(m.group(1)); sys.exit()
d = open(tree + "/DEPS").read()
m = re.search(r'"dart_sdk_revision"\s*:\s*"([^"]+)"', d)
print(m.group(1) if m else "")
PY
)"
  echo "$v"
}
