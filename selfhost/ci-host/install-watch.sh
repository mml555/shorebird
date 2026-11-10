#!/bin/bash
# Installs gha-watch for the user running this (oem on ci-build). No root, no sudo.
# Copies bin/gha-watch to ~/.local/bin, adds a cron entry (every 10 minutes), makes an
# empty 0600 ~/.config/gha-watch.env for the optional GH_TOKEN, and adds a login snippet
# that prints the current warnings. Idempotent: rerun after changing bin/gha-watch.
# Remove: delete the "# gha-watch" cron line (crontab -e), the "# gha-watch begin/end"
# block in ~/.profile or ~/.bash_profile, and ~/.local/bin/gha-watch.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
install -D -m 0755 "$here/bin/gha-watch" "$HOME/.local/bin/gha-watch"

# Never rewrite a crontab we could not read: only "no crontab" means start empty.
if cur=$(crontab -l 2>&1); then
  :
elif [[ $cur == *"no crontab for"* ]]; then
  cur=
else
  echo "install-watch: crontab -l failed ($cur); not touching the crontab" >&2
  exit 1
fi
line="*/10 * * * * $HOME/.local/bin/gha-watch >/dev/null 2>&1 # gha-watch"
{ grep -v '# gha-watch$' <<<"$cur" || true; echo "$line"; } | crontab -

cfg=${XDG_CONFIG_HOME:-$HOME/.config}/gha-watch.env
if [[ ! -e $cfg ]]; then
  mkdir -p "$(dirname "$cfg")"
  (umask 077; : >"$cfg")
fi

# Show the warnings to a human at login (interactive shells only).
prof=$HOME/.profile; [[ -e $HOME/.bash_profile ]] && prof=$HOME/.bash_profile
touch "$prof"
if ! grep -q '^# gha-watch begin' "$prof"; then
  cat >>"$prof" <<'SNIP'
# gha-watch begin
case $- in *i*) [ -s "$HOME/.local/state/gha-watch/current" ] && { echo "gha-watch: CI warnings (newest run):"; cat "$HOME/.local/state/gha-watch/current"; } ;; esac
# gha-watch end
SNIP
fi
echo "installed: $HOME/.local/bin/gha-watch, cron every 10 min, warnings in ~/.local/state/gha-watch/{current,warnings.log}"
