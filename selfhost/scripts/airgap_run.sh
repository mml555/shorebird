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
#   Linux : iptables OUTPUT rules in a dedicated AIRGAP chain — NOT a network
#           namespace. The build host reaches the mirror and control plane
#           through SSH REVERSE TUNNELS bound to 127.0.0.1, and a netns cannot
#           see those listeners, so sealing that way makes the mirror
#           unreachable and reports HARNESS FAILURE. Blocking new outbound
#           80/443/9418 to anything except loopback is the equivalent seal for
#           this topology, and mirrors what the pf rules do on macOS (skip lo0).
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
IPT_CHAIN=SHOREBIRD_AIRGAP
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
  # AIRGAP_ASSUME_SEALED=1: the operator applied the seal themselves (macOS
  # caches sudo per-tty, so a credential primed in the operator's terminal
  # does not authorize a run launched from elsewhere). Everything that
  # VERIFIES the seal still runs — preflight probes, cache isolation, the
  # report — so this weakens nothing except who types the pfctl command.
  if [[ "${AIRGAP_ASSUME_SEALED:-}" == "1" ]]; then
    note "AIRGAP_ASSUME_SEALED=1 — not applying the seal; preflight will verify it"
    return 0
  fi
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
  else
    note "sealing: iptables chain $IPT_CHAIN (block new out tcp 80/443/9418 except loopback)"
    sudo iptables -N "$IPT_CHAIN" 2>/dev/null || sudo iptables -F "$IPT_CHAIN"
    sudo iptables -A "$IPT_CHAIN" -o lo -j RETURN
    sudo iptables -A "$IPT_CHAIN" -d 127.0.0.0/8 -j RETURN
    sudo iptables -A "$IPT_CHAIN" -p tcp -m multiport --dports 80,443,9418 \
      -j REJECT --reject-with tcp-reset
    # Idempotent insert: drop any prior jump first.
    sudo iptables -D OUTPUT -j "$IPT_CHAIN" 2>/dev/null || true
    sudo iptables -I OUTPUT 1 -j "$IPT_CHAIN"
  fi
}

unseal() {
  if [[ "${AIRGAP_ASSUME_SEALED:-}" == "1" ]]; then
    note "AIRGAP_ASSUME_SEALED=1 — leaving the seal in place for the operator to remove"
    [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    return 0
  fi
  note "unsealing"
  if [[ -n "$HOSTS_BAK" && -f "$HOSTS_BAK" ]]; then
    sudo cp "$HOSTS_BAK" /etc/hosts && rm -f "$HOSTS_BAK"
  fi
  if [[ "$OS" == "Darwin" ]]; then
    sudo pfctl -a "$ANCHOR" -F all 2>/dev/null || true
  else
    sudo iptables -D OUTPUT -j "$IPT_CHAIN" 2>/dev/null || true
    sudo iptables -F "$IPT_CHAIN" 2>/dev/null || true
    sudo iptables -X "$IPT_CHAIN" 2>/dev/null || true
  fi
  [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
  return 0
}
trap unseal EXIT INT TERM

# Keep the sudo timestamp warm for the whole run. Without this a long build can
# outlive the cached credential, and then the UNSEAL at the end silently fails
# — leaving the machine firewalled after the script exits. That is the one
# failure mode of this wrapper that hurts the user rather than the run.
if [[ "${AIRGAP_ASSUME_SEALED:-}" != "1" ]]; then
  sudo -v 2>/dev/null || die "sudo credentials required: run 'sudo -v' first, or use AIRGAP_ASSUME_SEALED=1"
  ( while true; do sudo -n true 2>/dev/null || exit; sleep 45; done ) &
  SUDO_KEEPALIVE_PID=$!
fi

PREFLIGHT_LOG=""
preflight() {
  note "preflight: blocked hosts must FAIL, local services must SUCCEED"
  PREFLIGHT_LOG="$ISO/preflight.txt"; : > "$PREFLIGHT_LOG"
  local leak=0
  # Every host the toolchain could reach for artifacts, code, or packages —
  # not just Shorebird's. A probe that SUCCEEDS here means the seal has a hole
  # and any subsequent PASS would be meaningless.
  for h in storage.googleapis.com github.com pub.dev download.shorebird.dev \
           api.shorebird.dev maven.google.com objects.githubusercontent.com; do
    if curl -s -o /dev/null --max-time 8 "https://$h/"; then
      echo "  LEAK: https://$h/ is still reachable" | tee -a "$PREFLIGHT_LOG" >&2; leak=1
    else
      echo "  blocked (as required): $h" | tee -a "$PREFLIGHT_LOG"
    fi
  done
  [[ "$leak" == "0" ]] || die "the seal leaks — aborting before any build runs"

  # The seal must NOT block the two things the build legitimately needs. If
  # either is unreachable the rules are wrong (harness failure), which is a
  # different diagnosis from a missing artifact.
  local mirror="${FLUTTER_STORAGE_BASE_URL:-http://localhost:8085}"
  curl -sk -o /dev/null --max-time 10 "$mirror/" \
    || die "HARNESS FAILURE: mirror unreachable at $mirror through the seal"
  echo "  mirror reachable: $mirror" | tee -a "$PREFLIGHT_LOG"
  if [[ -n "${SHOREBIRD_HOSTED_URL:-}" ]]; then
    curl -s -o /dev/null --max-time 10 -X POST \
      "$SHOREBIRD_HOSTED_URL/api/v1/patches/check" \
      -d '{}' -H 'content-type: application/json' \
      || die "HARNESS FAILURE: control plane unreachable at $SHOREBIRD_HOSTED_URL through the seal"
    echo "  control plane reachable: $SHOREBIRD_HOSTED_URL" | tee -a "$PREFLIGHT_LOG"
  fi
}

# --- isolated cache homes ----------------------------------------------------
# Capture the real HOME before the Linux branch below overrides it, so the
# isolation tripwire can still find the host's global caches to watch.
REAL_HOME="$HOME"
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

# --- isolation tripwire -------------------------------------------------------
# Exporting fresh cache homes only PROVES isolation if nothing reaches the real
# ones anyway. Snapshot the global caches, then compare after the run: a
# mutation means some tool ignored its env override and used the host's cache,
# which is a REAL failure (a sealed PASS that quietly depended on a warm global
# cache is not independence).
GLOBAL_CACHES=("$REAL_HOME/.gradle" "$REAL_HOME/.pub-cache" "$REAL_HOME/.m2"
               "$REAL_HOME/Library/Caches/CocoaPods" "$REAL_HOME/.dartServer")
snapshot_globals() {  # snapshot_globals <outfile>
  : > "$1"
  local c
  for c in "${GLOBAL_CACHES[@]}"; do
    [[ -e "$c" ]] || continue
    # Newest mtime inside each cache, cheaply: no full checksum, just the
    # signal that something wrote there.
    # stat is not portable: BSD/macOS wants -f '%m', GNU/Linux wants -c '%Y'.
    printf '%s %s\n' "$c" \
      "$(find "$c" -type f -newermt '-400 days' -print0 2>/dev/null |
         { xargs -0 stat -f '%m' 2>/dev/null || xargs -0 stat -c '%Y' 2>/dev/null; } |
         sort -rn | head -1)" >> "$1"
  done
}
ISO_BEFORE="$ISO/globals.before"; ISO_AFTER="$ISO/globals.after"
note "snapshotting global caches for the isolation tripwire"
snapshot_globals "$ISO_BEFORE"

seal
preflight

note "running payload: $*"
set +e
# No netns exec: the seal is iptables on Linux (see header), so the payload
# runs as the invoking user in the host namespace, where the reverse-tunnel
# listeners on 127.0.0.1 are reachable.
"$@"
RC=$?
set -e

note "payload exit=$RC"

# --- isolation verdict ---------------------------------------------------------
snapshot_globals "$ISO_AFTER"
echo ""
echo "===== CACHE ISOLATION ====="
echo "isolated roots: PUB_CACHE=$PUB_CACHE (seeded)"
echo "                GRADLE_USER_HOME=$GRADLE_USER_HOME"
echo "                XDG_CACHE_HOME=$XDG_CACHE_HOME"
echo "                TMPDIR=$TMPDIR"
[[ "$OS" == "Linux" ]] && echo "                HOME=$HOME"
if diff -q "$ISO_BEFORE" "$ISO_AFTER" >/dev/null 2>&1; then
  echo "ISOLATION: OK — no global cache under $REAL_HOME was written during the run"
  ISO_RC=0
else
  echo "ISOLATION: VIOLATED — a tool wrote outside the isolated roots:"
  diff "$ISO_BEFORE" "$ISO_AFTER" | sed 's/^/  /'
  echo "  (a sealed PASS that depended on a warm global cache is not independence)"
  ISO_RC=1
fi
echo ""
echo "===== PREFLIGHT (seal verification, before any build) ====="
[[ -s "${PREFLIGHT_LOG:-}" ]] && cat "$PREFLIGHT_LOG" || echo "  (no preflight record)"

if [[ $RC -eq 0 && $ISO_RC -ne 0 ]]; then
  echo "SEALED RESULT: FAIL (payload passed but cache isolation was violated)"
  exit 1
fi
exit $RC
