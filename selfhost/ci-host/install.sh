#!/bin/bash
# install.sh: install the runner host's scripts, units, squid config, allowlists and
# runner configs from this directory. Run as root on the host:
#     sudo bash selfhost/ci-host/install.sh
# Idempotent. Safe while jobs run: it never restarts or starts a runner, only reloads
# systemd, reconfigures squid (no dropped tunnels) and, when the firewall script or a
# runner config changed, re-applies the egress table (atomic). It writes no secrets;
# the registration token files in /etc/gha are the owner's (see README.md).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $0" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
changed_egress=0 changed_squid=0 changed_units=0

# put <mode> <src> <dst> <flag-var>: install when the content differs.
put() {
  local mode=$1 src=$2 dst=$3 flag=${4:-}
  if [[ -e $dst ]] && cmp -s "$src" "$dst"; then
    chmod "$mode" "$dst"; return 0
  fi
  install -D -m "$mode" -o root -g root "$src" "$dst"
  echo "installed $dst"
  [[ -z $flag ]] || printf -v "$flag" 1
}

for f in gha-prep gha-run gha-dockerd gha-egress-denied; do put 0755 "$here/bin/$f" "/usr/local/sbin/$f"; done
put 0755 "$here/bin/gha-egress-apply" /usr/local/sbin/gha-egress-apply changed_egress

put 0644 "$here/systemd/gha-runner@.service" /etc/systemd/system/gha-runner@.service changed_units
put 0644 "$here/systemd/gha-egress.service" /etc/systemd/system/gha-egress.service changed_units
put 0644 "$here/systemd/gha-runner@.service.d/egress.conf" /etc/systemd/system/gha-runner@.service.d/egress.conf changed_units
put 0644 "$here/systemd/squid.service.d/egress.conf" /etc/systemd/system/squid.service.d/egress.conf changed_units

install -d -m 0755 -o root -g root /etc/gha-runners
put 0644 "$here/runners/proxy.env" /etc/gha-runners/proxy.env
for conf in "$here"/runners/gha-*.conf; do
  u=$(basename "$conf" .conf)
  if id "$u" >/dev/null 2>&1; then
    put 0644 "$conf" "/etc/gha-runners/$u.conf" changed_egress
  else
    echo "skipping $u.conf: no such user (run provision.sh first)" >&2
  fi
done
install -d -m 0700 -o root -g root /etc/gha

# squid: keep the distribution's config once, then check the new one before using it.
command -v squid >/dev/null || { echo "squid is not installed (provision.sh installs it)" >&2; exit 1; }
[[ -e /etc/squid/squid.conf.dist ]] || cp -a /etc/squid/squid.conf /etc/squid/squid.conf.dist
put 0644 "$here/squid/gha-allowlist.txt" /etc/squid/gha-allowlist.txt changed_squid
put 0644 "$here/squid/gha-allowlist.regex" /etc/squid/gha-allowlist.regex changed_squid
put 0644 "$here/squid/squid.conf" /etc/squid/squid.conf changed_squid

[[ $changed_units == 0 ]] || systemctl daemon-reload
systemctl enable gha-egress.service >/dev/null 2>&1
# Fail closed: the table must exist before squid and any runner start. Loaded once
# if absent, and again when the script or a runner config changed.
if [[ $changed_egress == 1 ]] || ! nft list table inet gha_egress >/dev/null 2>&1; then
  /usr/local/sbin/gha-egress-apply
fi
systemctl is-active --quiet gha-egress.service || systemctl start gha-egress.service

squid -k parse >/dev/null 2>&1 || { squid -k parse; echo "squid.conf does not parse; not reloading" >&2; exit 1; }
if systemctl is-active --quiet squid; then
  [[ $changed_squid == 0 ]] || { squid -k reconfigure; echo "squid reconfigured"; }
else
  systemctl enable --now squid
fi

# Log rotation: Debian's /etc/logrotate.d/squid covers /var/log/squid/*.log.
logrotate -d /etc/logrotate.d/squid >/dev/null 2>&1 || echo "warning: logrotate -d /etc/logrotate.d/squid failed" >&2

echo "done. Runners were not touched; enable one with: systemctl enable --now gha-runner@<user>"
