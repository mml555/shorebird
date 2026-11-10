#!/bin/bash
# Installs gha-watch for the user running this (oem on ci-build). No root, no sudo.
# Copies bin/gha-watch to ~/.local/bin and adds a cron entry, every 10 minutes.
# Idempotent: rerun after changing bin/gha-watch. Remove with: crontab -e (delete the
# line marked "# gha-watch") and rm ~/.local/bin/gha-watch.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
install -D -m 0755 "$here/bin/gha-watch" "$HOME/.local/bin/gha-watch"
line="*/10 * * * * $HOME/.local/bin/gha-watch >/dev/null 2>&1 # gha-watch"
{ crontab -l 2>/dev/null | grep -v '# gha-watch$' || true; echo "$line"; } | crontab -
echo "installed: $HOME/.local/bin/gha-watch, cron every 10 min; warnings in ~/.local/state/gha-watch/warnings.log"
