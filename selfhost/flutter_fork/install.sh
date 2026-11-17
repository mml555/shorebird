#!/usr/bin/env bash
# install.sh [--dry-run]
#
# Links the versioned scripts into ~/shorebird-engine so bin/sync, bin/build etc. keep their
# paths. Run it from the checkout you want them to follow: a checkout of main that nobody
# switches branches in, since the links follow that checkout's files. Re-run it from the new
# checkout if you move or delete this one (a removed checkout leaves dangling links).
#
# Each link is made under a temporary name and renamed into place, so a script that is
# running, or started a moment later, always finds a complete file. A real (non-symlink) file
# at a destination is moved to NAME.bak.<timestamp> first, never overwritten. --dry-run changes
# nothing. Unknown arguments are refused. Links for scripts removed from the repo are not
# pruned; delete them by hand.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
W="${SHOREBIRD_ENGINE_DIR:-$HOME/shorebird-engine}"
dry=0
case "${1:-}" in
  "") ;;
  --dry-run) dry=1 ;;
  *) echo "usage: install.sh [--dry-run]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "usage: install.sh [--dry-run]" >&2; exit 2; }
ts="$(date +%Y%m%d-%H%M%S)"
link() { # SRC DEST
  local src="$1" dest="$2" tmp="$2.new.$$"
  if [[ -e "$dest" && ! -L "$dest" ]]; then
    echo "backup $dest -> $dest.bak.$ts (a real file; not overwritten)"
    [[ "$dry" == 1 ]] || cp -p "$dest" "$dest.bak.$ts"
  fi
  echo "link $dest -> $src"
  [[ "$dry" == 1 ]] && return 0
  ln -s "$src" "$tmp"
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; echo "error: could not link $dest" >&2; return 1; }
}
[[ "$dry" == 1 || -d "$W/bin" ]] || mkdir -p "$W/bin"
for f in "$here"/bin/*; do
  link "$f" "$W/bin/$(basename "$f")"
done
link "$here/env.sh" "$W/env.sh"
link "$here/bootstrap.sh" "$W/bootstrap.sh"
