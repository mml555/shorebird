#!/usr/bin/env bash
# install.sh [--dry-run]
#
# Links the versioned scripts into ~/shorebird-engine so bin/sync, bin/build etc. keep their
# paths. Run it from the checkout you want them to follow (a checkout of main, normally).
# Each link is made under a temporary name and renamed into place, so a script that is
# being run, or started a moment later, always finds a complete file. Re-running is safe;
# re-run it from the new checkout if you move or delete this one.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
W="${SHOREBIRD_ENGINE_DIR:-$HOME/shorebird-engine}"
dry=0; [[ "${1:-}" == --dry-run ]] && dry=1
mkdir -p "$W/bin"
link() { # SRC DEST
  echo "link $2 -> $1"
  [[ "$dry" == 1 ]] && return 0
  ln -s "$1" "$2.new.$$" && mv -f "$2.new.$$" "$2"
}
for f in "$here"/bin/*; do
  [[ "$(basename "$f")" == README.md ]] && continue
  link "$f" "$W/bin/$(basename "$f")"
done
link "$here/bin/README.md" "$W/bin/README.md"
link "$here/env.sh" "$W/env.sh"
link "$here/bootstrap.sh" "$W/bootstrap.sh"
