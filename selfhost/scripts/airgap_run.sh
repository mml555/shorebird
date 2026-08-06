#!/usr/bin/env bash
# airgap_run.sh — enforcement wrapper for the air-gap acceptance run.
#
# Seals the machine at the packet level, poisons the known upstream hosts as a
# fast tripwire, verifies the seal with preflight probes, exports ISOLATED
# cache homes, then runs the payload (normally airgap_acceptance.sh). Always
# unseals afterward, even on failure.
#
#   sudo -v && selfhost/scripts/airgap_run.sh -- selfhost/scripts/airgap_acceptance.sh --ios
#
# Blocking, by platform:
#   macOS : a pf anchor (airgap.pf.conf) blocks outbound 80/443/9418 except
#           loopback + link-local (mirror, control plane and USB device all
#           live there). Requires sudo.
#   Linux : run the payload inside a network namespace that has ONLY a veth
#           route to the mirror/control-plane host. Construction of the netns
#           is site-specific; this wrapper expects it to already exist and be
#           named "airgap" (ip netns add airgap; wire the veth to the tunnel
#           host). Requires sudo.
#
# Cache isolation: an empty Shorebird bin/cache is NOT enough — Gradle, pub,
# XDG and temp caches survive on the host and can mask a network dependency.
# This wrapper exports fresh homes for all of them. Deliberate exception:
# $HOME itself is kept on macOS, because code signing needs the login keychain
# and Xcode's toolchain is classed as a PREINSTALLED SYSTEM TOOL, not a
# network-fetched cache (see the acceptance criteria in
# selfhost/UPSTREAM_INDEPENDENCE.md). On Linux, HOME is isolated too.
#
# The seeded pub cache is the ONE cache allowed in: point AIRGAP_PUB_CACHE at
# a directory populated by the warm (unsealed) run.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ANCHOR=shorebird_airgap
POISON_HOSTS=(
  pub.dev
  storage.googleapis.com
  download.shorebird.dev
  api.shorebird.dev
  cdn.shorebird.cloud
  github.com
  objects.githubusercontent.com
  chrome-infra-packages.appspot.com
  maven.google.com
)

die() { echo "AIRGAP ERROR: $*" >&2; exit 2; }
note() { echo "==> $*"; }

[[ "${1:-}" == "--" ]] && shift
[[ $# -ge 1 ]] || die "usage: airgap_run.sh -- <payload command...>"

[[ -n "${AIRGAP_PUB_CACHE:-}" ]] || die "AIRGAP_PUB_CACHE must point at the seeded pub cache (from the warm run)"
[[ -d "$AIRGAP_PUB_CACHE" ]] || die "AIRGAP_PUB_CACHE does not exist: $AIRGAP_PUB_CACHE"

OS="$(uname -s)"
HOSTS_BAK=""

seal() {
  note "sealing: /etc/hosts tripwire (${#POISON_HOSTS[@]} hosts)"
  HOSTS_BAK="$(mktemp /tmp/hosts.airgap.XXXXXX)"
  sudo cp /etc/hosts "$HOSTS_BAK"
  {
    echo ""
    echo "# --- shorebird airgap tripwire (removed by airgap_run.sh) ---"
    for h in "${POISON_HOSTS[@]}"; do echo "127.0.0.1 $h"; done
  } | sudo tee -a /etc/hosts >/dev/null

  if [[ "$OS" == "Darwin" ]]; then
    note "sealing: pf anchor $ANCHOR (block out tcp 80/443/9418 except loopback + link-local)"
    sudo pfctl -a "$ANCHOR" -f "$HERE/airgap.pf.conf" 2>/dev/null
    sudo pfctl -e 2>/dev/null || true   # already enabled is fine
  fi
}

unseal() {
  note "unsealing"
  if [[ -n "$HOSTS_BAK" && -f "$HOSTS_BAK" ]]; then
    sudo cp "$HOSTS_BAK" /etc/hosts && rm -f "$HOSTS_BAK"
  fi
  if [[ "$OS" == "Darwin" ]]; then
    sudo pfctl -a "$ANCHOR" -F all 2>/dev/null || true
  fi
}
trap unseal EXIT INT TERM

preflight() {
  note "preflight: blocked hosts must FAIL, local services must SUCCEED"
  local leak=0
  for h in storage.googleapis.com github.com pub.dev; do
    if curl -s -o /dev/null --max-time 8 "https://$h/"; then
      echo "  LEAK: https://$h/ is still reachable" >&2; leak=1
    else
      echo "  blocked: $h"
    fi
  done
  [[ "$leak" == "0" ]] || die "the seal leaks — aborting before any build runs"

  local mirror="${FLUTTER_STORAGE_BASE_URL:-http://localhost:8085}"
  curl -s -o /dev/null --max-time 10 "$mirror/" \
    || die "mirror unreachable at $mirror"
  echo "  mirror ok: $mirror"
  if [[ -n "${SHOREBIRD_HOSTED_URL:-}" ]]; then
    curl -s -o /dev/null --max-time 10 -X POST \
      "$SHOREBIRD_HOSTED_URL/api/v1/patches/check" \
      -d '{}' -H 'content-type: application/json' \
      || die "control plane unreachable at $SHOREBIRD_HOSTED_URL"
    echo "  control plane ok: $SHOREBIRD_HOSTED_URL"
  fi
}

# --- isolated cache homes ----------------------------------------------------
ISO="$(mktemp -d /tmp/airgap-iso.XXXXXX)"
note "isolated cache homes under $ISO (seeded pub cache: $AIRGAP_PUB_CACHE)"
export PUB_CACHE="$AIRGAP_PUB_CACHE"
export GRADLE_USER_HOME="$ISO/gradle"
export XDG_CACHE_HOME="$ISO/xdg-cache"
export TMPDIR="$ISO/tmp"
mkdir -p "$GRADLE_USER_HOME" "$XDG_CACHE_HOME" "$TMPDIR"
if [[ "$OS" == "Linux" ]]; then
  export HOME="$ISO/home"
  mkdir -p "$HOME"
else
  echo "  HOME kept (macOS keychain/codesign — preinstalled system tool, see header)"
fi

seal
preflight

note "running payload: $*"
set +e
if [[ "$OS" == "Linux" ]]; then
  sudo ip netns exec airgap sudo -u "$(id -un)" --preserve-env "$@"
else
  "$@"
fi
RC=$?
set -e

note "payload exit=$RC"
exit $RC
