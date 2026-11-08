#!/bin/bash
# provision.sh: one-time build of the CI runner host (Ubuntu, run as root):
#     sudo bash selfhost/ci-host/provision.sh
# Packages, Rust, the pinned runner tarball, one unprivileged user per runner, the
# registry pull-through cache, then install.sh for the scripts, units and egress
# allowlist. Idempotent. It never enables or starts a runner and never registers one
# with GitHub; see README.md ("Add a runner") for that.
#   1. apt: packages jobs used to `sudo apt-get install`, the pull-through registry
#   2. Rust into a root-owned, read-only RUSTUP_HOME (/opt/rustup), cargo-ndk
#   3. pinned GitHub Actions runner tarball, sha256-verified, into /opt/gha
#   4. one unprivileged user per runner (no groups, nologin shell)
#   5. /etc/gha (root 0700) and per-runner config (/etc/gha-runners/<user>.conf)
#   6. pull-through Docker Hub cache on 127.0.0.1:5000 (root-owned, read-only to jobs)
#   7. install.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $0" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
export DEBIAN_FRONTEND=noninteractive

# ---- Pins --------------------------------------------------------------------
RUNNER_VERSION=2.338.2
# From the actions/runner v2.338.2 release notes (<!-- BEGIN SHA linux-x64 -->).
RUNNER_SHA256=baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40
RUST_VERSION=1.99.1
CARGO_NDK_VERSION=4.1.2
# name(user)  repo                              runner name   labels (as registered today)
RUNNERS=(
  "gha-sb1|mml555/shorebird|shorebird-1|self-hosted,linux,x64,docker,rust,shorebird"
  "gha-sb2|mml555/shorebird|shorebird-2|self-hosted,linux,x64,docker,rust,shorebird"
  "gha-sb3|mml555/shorebird|shorebird-3|self-hosted,linux,x64,docker,rust,shorebird"
  "gha-sb4|mml555/shorebird|shorebird-4|self-hosted,linux,x64,docker,rust,shorebird"
  "gha-sb5|mml555/shorebird|shorebird-5|self-hosted,linux,x64,docker,rust,shorebird"
  "gha-upd1|mml555/shorebird-updater-mirror|updater-1|self-hosted,linux,x64,docker,rust,updater"
)

step() { printf '\n== %s\n' "$*"; }

# ---- 1. Packages ---------------------------------------------------------------
step "apt packages"
# libsqlite3-dev, shellcheck: code_push_server.yaml. musl-tools, gh: the mirror's
# build_patch_artifacts.yaml. docker-registry: the pull-through cache. The rest
# is what rootless Docker needs, normally present already.
apt-get update -qq
# --no-upgrade: never bump packages that are already installed (docker-ce etc.).
apt-get install -y --no-install-recommends --no-upgrade \
  libsqlite3-dev shellcheck musl-tools gh jq curl ca-certificates \
  build-essential pkg-config git unzip uidmap slirp4netns docker-registry
for c in rootlesskit dockerd-rootless.sh newuidmap slirp4netns docker setpriv; do
  command -v "$c" >/dev/null || { echo "missing $c (Docker rootless extras?)" >&2; exit 1; }
done

# ---- 2. Rust, read-only --------------------------------------------------------
step "Rust $RUST_VERSION in /opt/rustup"
export RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
export PATH=/opt/cargo/bin:$PATH
if [[ ! -x /opt/cargo/bin/rustup ]]; then
  tmp=$(mktemp -d)
  curl -fsSL https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init -o "$tmp/rustup-init"
  curl -fsSL https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init.sha256 -o "$tmp/rustup-init.sha256"
  # The .sha256 file names a path; compare just the hash.
  [[ $(awk '{print $1}' "$tmp/rustup-init.sha256") == "$(sha256sum "$tmp/rustup-init" | awk '{print $1}')" ]] \
    || { echo "rustup-init checksum mismatch" >&2; exit 1; }
  chmod +x "$tmp/rustup-init"
  "$tmp/rustup-init" -y --no-modify-path --profile minimal --default-toolchain "$RUST_VERSION"
  rm -rf "$tmp"
fi
# Everything a job can ask rustup for, installed up front: the toolchain
# components named by vendor/updater/rust-toolchain.toml, plus the targets the
# updater mirror's workflows `rustup target add`. (Re-running these is a no-op.)
/opt/cargo/bin/rustup toolchain install "$RUST_VERSION" --profile minimal \
  -c rustfmt -c clippy -c llvm-tools-preview \
  -t x86_64-unknown-linux-musl -t aarch64-linux-android
/opt/cargo/bin/rustup default "$RUST_VERSION"
if ! /opt/cargo/bin/cargo-ndk --version 2>/dev/null | grep -q "$CARGO_NDK_VERSION"; then
  CARGO_HOME=$(mktemp -d) /opt/cargo/bin/cargo install --locked "cargo-ndk@$CARGO_NDK_VERSION" --root /opt/cargo
fi
# Root-owned, world-readable, nobody can write.
chown -R root:root /opt/rustup /opt/cargo
chmod -R go-w /opt/rustup /opt/cargo
chmod -R a+rX /opt/rustup /opt/cargo

# ---- 3. Runner tarball -----------------------------------------------------------
step "runner $RUNNER_VERSION"
install -d -m 0755 -o root -g root /opt/gha
if ! { [[ -f /opt/gha/runner.tar.gz ]] && echo "$RUNNER_SHA256  /opt/gha/runner.tar.gz" | sha256sum --check --status; }; then
  curl -fsSL "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz" -o /opt/gha/runner.tar.gz.new
  echo "$RUNNER_SHA256  /opt/gha/runner.tar.gz.new" | sha256sum --check --status \
    || { echo "runner tarball checksum mismatch" >&2; rm -f /opt/gha/runner.tar.gz.new; exit 1; }
  mv /opt/gha/runner.tar.gz.new /opt/gha/runner.tar.gz
fi
echo "$RUNNER_SHA256  runner.tar.gz" > /opt/gha/runner.tar.gz.sha256
echo "$RUNNER_VERSION" > /opt/gha/runner.version
chmod 0644 /opt/gha/runner.tar.gz /opt/gha/runner.tar.gz.sha256 /opt/gha/runner.version

# ---- 4/5. Users and config -------------------------------------------------------
step "job users and /etc/gha"
install -d -m 0700 -o root -g root /etc/gha
# Outside /etc/gha (0700): the job user must read its own conf.
install -d -m 0755 -o root -g root /etc/gha-runners
make_user() {
  local u=$1
  if ! id "$u" >/dev/null 2>&1; then
    # Regular user (gets /etc/subuid and /etc/subgid ranges for rootless
    # Docker), its own group, no password, nologin shell: not a login account.
    useradd --create-home --user-group --shell /usr/sbin/nologin --comment "ephemeral CI job user" "$u"
  fi
  usermod --shell /usr/sbin/nologin "$u"
  passwd -l "$u" >/dev/null
  # Primary group only. Remove any supplementary group someone added.
  for g in $(id -nG "$u"); do [[ $g == "$u" ]] || gpasswd -d "$u" "$g" >/dev/null; done
  if ! { grep -q "^$u:" /etc/subuid && grep -q "^$u:" /etc/subgid; }; then echo "no subuid/subgid for $u" >&2; exit 1; fi
  # No cron or at jobs for job users (jobs would outlive the runner's cgroup).
  grep -qxF "$u" /etc/cron.deny 2>/dev/null || echo "$u" >> /etc/cron.deny
  if [[ -d /etc/at.deny || -f /etc/at.deny ]] || command -v at >/dev/null; then
    grep -qxF "$u" /etc/at.deny 2>/dev/null || echo "$u" >> /etc/at.deny
  fi
  # A job user must never get a sudoers entry.
  if grep -rqsE "^[^#]*\b$u\b" /etc/sudoers /etc/sudoers.d; then
    echo "$u appears in sudoers; remove it" >&2; exit 1
  fi
}
k=0
for r in "${RUNNERS[@]}"; do
  IFS='|' read -r u repo name labels <<<"$r"
  make_user "$u"
  tokfile=/etc/gha/${repo#*/}.token
  # Not overwritten when present: install.sh installs the files kept in runners/.
  [[ -e "/etc/gha-runners/$u.conf" ]] || cat > "/etc/gha-runners/$u.conf" <<CONF
# Written by install.sh. Sourced by gha-prep and gha-run (bash syntax).
GHA_REPO=$repo
GHA_NAME=$name
GHA_LABELS=$labels
GHA_TOKEN_FILE=$tokfile
# Docker host-port slice, distinct per runner (see gha-dockerd). Below 32768 so
# it never overlaps the host ephemeral range outbound connections draw from.
GHA_PORT_RANGE="$((20000 + 1000 * k)) $((20999 + 1000 * k))"
CONF
  [[ -e "/etc/gha-runners/$u.conf" ]] && chmod 0644 "/etc/gha-runners/$u.conf"
  k=$((k + 1))
done
chmod 0644 /etc/cron.deny

# ---- 6. Pull-through registry cache ----------------------------------------------
step "pull-through Docker Hub cache on 127.0.0.1:5000"
cat > /etc/docker/registry/config.yml.new <<'YAML'
# Written by install.sh. A pull-through cache of Docker Hub, on loopback only.
# Proxy registries are read-only: a push is refused, so a job cannot plant an
# image here. Rootless Docker daemons use it as a mirror.
version: 0.1
log:
  level: warn
storage:
  filesystem:
    rootdirectory: /var/lib/docker-registry
  delete:
    enabled: false
  maintenance:
    uploadpurging:
      enabled: false
http:
  addr: 127.0.0.1:5000
proxy:
  remoteurl: https://registry-1.docker.io
  # Tags such as redis-stack-server:latest are re-checked daily.
  ttl: 24h
YAML
install -d -o docker-registry -g docker-registry /var/lib/docker-registry 2>/dev/null || true
systemctl enable docker-registry >/dev/null 2>&1 || true
# Restart only on a change: a running job may be pulling through it.
if cmp -s /etc/docker/registry/config.yml.new /etc/docker/registry/config.yml; then
  rm /etc/docker/registry/config.yml.new
else
  mv /etc/docker/registry/config.yml.new /etc/docker/registry/config.yml
  systemctl restart docker-registry
fi

# ---- 7. Scripts, units, squid, egress table -------------------------------------
step "install.sh (scripts, units, squid, egress)"
bash "$here/install.sh"

step "done"
echo "Provisioned. Nothing is enabled, started or registered. Next: README.md, \"Add a runner\"."
