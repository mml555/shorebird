#!/usr/bin/env bash
# cspell:words ENVFILE PORTMAP jewgo
# prepare_ios_endpoint.sh — derive the iOS control-plane endpoint at RUN TIME
# and configure BOTH ends from the same detection.
#
# THE INVARIANT
#
#   The server URL and the fixture URL are generated together from the
#   currently reachable device-facing endpoint. Neither is ever a constant.
#
# Everything here exists because both ends drift independently:
#
#   2026-08-07  cps-ios still advertised a previous session's USB link-local
#               address. A warm run built a full IPA, created release 40, then
#               HUNG uploading artifacts to an unreachable host.
#   2026-08-07  the fixture's base_url said localhost, which the phone cannot
#               reach at all.
#
# MODES
#
#   --mode lan  (default)  the Mac's LAN IPv4. This is the CANONICAL iOS
#                          acceptance topology as of 2026-08-07.
#   --mode usb             the USB link-local address (169.254.x).
#
# WHY LAN IS CANONICAL, AND WHAT IT DOES NOT MEAN
#
# The USB-only topology is not viable on this rig, for a reason that has
# nothing to do with Shorebird: iOS refuses to launch a development-signed app
# it cannot verify online. With Wi-Fi off NO dev-signed app runs — including
# com.jewgo.assetprobe, which the earlier acceptance runs used successfully —
# and with Wi-Fi on the link-local endpoint received zero traffic. So the only
# configuration in which the app runs is also one where LAN works.
#
# This does NOT weaken the independence result. Apple code-signing is not an
# upstream SHOREBIRD dependency. The seal that matters is unchanged: the mirror
# refuses upstream Shorebird/GCS artifacts, build caches are isolated, the
# control plane and artifacts are ours, and nothing the phone can reach
# externally satisfies any Shorebird artifact request. External phone
# networking is permitted, and is not trusted as part of the Shorebird
# dependency graph.
#
#   prepare_ios_endpoint.sh [--mode lan|usb] [--container cps-ios]
#                           [--port 18080] [--force]
#
# Idempotent: if the container already advertises the detected endpoint and the
# preflight passes, it changes nothing.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
CONTAINER="cps-ios"
PORT=18080
MODE=lan
FORCE=0
STAMP="$HERE/../fixtures/airgap/endpoint.stamp"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:?}"; shift 2 ;;
    --container) CONTAINER="${2:?}"; shift 2 ;;
    --port) PORT="${2:?}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '3,46p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "$MODE" == "lan" || "$MODE" == "usb" ]] || die "--mode must be lan or usb"

command -v docker >/dev/null || die "docker is not on PATH"
docker inspect "$CONTAINER" >/dev/null 2>&1 || die "no container named $CONTAINER"

# --- 1. detect the device-facing endpoint ---------------------------------------
if [[ "$MODE" == "usb" ]]; then
  IFACE="$(ifconfig 2>/dev/null | awk '/^[a-z0-9]+:/{i=substr($1,1,length($1)-1)} /inet 169\.254\./{print i; exit}')"
  MAC_IP="$(ifconfig 2>/dev/null | awk '/^[a-z0-9]+:/{i=$1} /inet 169\.254\./{print $2; exit}')"
  [[ -n "$MAC_IP" ]] || die "no 169.254.x link-local address. Is the iPhone attached over USB?"
else
  IFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
  [[ -n "$IFACE" ]] || die "no default route interface; is the Mac on a network?"
  MAC_IP="$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)"
  [[ -n "$MAC_IP" ]] || die "no IPv4 on $IFACE"
fi
note "mode          : $MODE"
note "interface     : $IFACE"
note "Mac address   : $MAC_IP"

WANT="http://$MAC_IP:$PORT"
HAVE="$(docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
        | awk -F= '/^PUBLIC_BASE_URL=/{print substr($0, index($0,"=")+1)}')"
note "container has : ${HAVE:-<unset>}"
note "run needs     : $WANT"

# --- 2. recreate only if the endpoint moved -------------------------------------
if [[ "$HAVE" == "$WANT" && $FORCE -eq 0 ]]; then
  note "already correct; not recreating"
else
  note "endpoint differs — recreating $CONTAINER"
  # Preserve EVERYTHING except PUBLIC_BASE_URL: image, ports, mounts, and every
  # other env var (which include secrets). The env goes through a 0600 file so
  # no secret ever lands on a command line or in a transcript — a dev key was
  # leaked that way once and had to be rotated.
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  ENVFILE="$TMP/env"; umask 077
  docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | grep -vE '^(PUBLIC_BASE_URL=|PATH=|$)' > "$ENVFILE"
  echo "PUBLIC_BASE_URL=$WANT" >> "$ENVFILE"

  IMAGE="$(docker inspect "$CONTAINER" --format '{{.Config.Image}}')"
  # Bind mounts carry the app/release/patch history — preserved verbatim.
  MOUNTS=()
  while IFS= read -r m; do [[ -n "$m" ]] && MOUNTS+=(-v "$m"); done < <(
    docker inspect "$CONTAINER" --format '{{range .Mounts}}{{.Source}}:{{.Destination}}{{"\n"}}{{end}}')
  PORTMAP="$(docker inspect "$CONTAINER" \
    --format '{{range $p, $c := .HostConfig.PortBindings}}{{range $c}}{{.HostPort}}{{end}}:{{$p}}{{end}}' \
    | sed 's|/tcp||')"
  [[ -n "$IMAGE" && -n "$PORTMAP" ]] || die "could not read image/ports from $CONTAINER"
  note "image $IMAGE, ports $PORTMAP, ${#MOUNTS[@]} mount(s) preserved"

  docker rm -f "$CONTAINER" >/dev/null
  docker run -d --name "$CONTAINER" --restart unless-stopped \
    --env-file "$ENVFILE" -p "$PORTMAP" "${MOUNTS[@]}" "$IMAGE" >/dev/null \
    || die "recreate failed — the data mount is untouched, so re-running this is safe"
  note "recreated"
  sleep 3
fi

# --- 3. preflight: Mac, then the device ------------------------------------------
code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$WANT/" || echo FAIL)"
[[ "$code" == "200" ]] || die "Mac cannot reach $WANT (got $code)"
note "preflight: Mac -> control plane   200"

# The phone. For LAN this is a real check — same subnet AND answering — which is
# what "the device can reach the endpoint" means at the layer testable from
# here. End-to-end proof is still the beacon during the run.
# Find the phone's address for the chosen path. The USB arp entry is the
# reliable way to learn its mDNS NAME even when we want its LAN address: a
# tethered iPhone always shows up there, and .local then resolves to whatever
# it holds on the network we care about.
phone_hostname() {
  arp -a 2>/dev/null | grep -oiE '[a-z0-9-]*iphone[a-z0-9-]*\.local' | head -1
}
PHONE_IP=""
if [[ "$MODE" == "usb" ]]; then
  PHONE_IP="$(arp -a -i "$IFACE" 2>/dev/null | grep -oE '169\.254\.[0-9]+\.[0-9]+' \
              | grep -v "^$MAC_IP$" | head -1 || true)"
else
  host="$(phone_hostname || true)"
  if [[ -n "$host" ]]; then
    # dns-sd returns SEVERAL records for one name: a 0.0.0.0 "No Such Record"
    # placeholder, the USB link-local, and the LAN address. Take IPs by shape
    # (a header row puts the word "Address" in the same column as the value, so
    # field position lies), drop the placeholder and link-local, and PREFER one
    # on the Mac's own /24 — that is the address that can actually reach us.
    ips="$(timeout 8 dns-sd -G v4 "$host" 2>/dev/null \
           | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
           | grep -vE '^(0\.0\.0\.0|169\.254\.)' | sort -u || true)"
    PHONE_IP="$(printf '%s\n' "$ips" | grep "^${MAC_IP%.*}\." | head -1 || true)"
    [[ -n "$PHONE_IP" ]] || PHONE_IP="$(printf '%s\n' "$ips" | head -1 || true)"
  fi
  # Fall back to the arp table, which is populated once the phone has talked.
  [[ -n "$PHONE_IP" ]] || PHONE_IP="$(arp -a 2>/dev/null | grep -i iphone \
      | grep -oE '\([0-9.]+\)' | tr -d '()' | grep -v '^169\.254\.' | head -1 || true)"
  # Same-subnet check: a phone on a different network can reach the Mac only if
  # the two networks route to each other, which is not something to assume.
  if [[ -n "$PHONE_IP" ]]; then
    if [[ "${PHONE_IP%.*}" != "${MAC_IP%.*}" ]]; then
      echo "WARN: phone $PHONE_IP and Mac $MAC_IP are on different /24s." >&2
      echo "      They may still route, but do not assume it." >&2
    fi
  fi
fi

if [[ -n "$PHONE_IP" ]] && ping -c 2 -t 3 "$PHONE_IP" >/dev/null 2>&1; then
  note "preflight: device $PHONE_IP reachable"
else
  echo "WARN: no reachable phone address found on $MODE yet." >&2
  echo "      The address populates once the phone talks to the network; if the" >&2
  echo "      run sees no beacon, re-check this first." >&2
fi

# --- 4. keep the fixture consistent with the SAME detection ----------------------
ios_app_id="$(awk -F= '/^IOS_APP_ID=/{print $2}' "$HERE/../fixtures/airgap/acceptance.env" 2>/dev/null | tr -d '[:space:]')"
if [[ -n "$ios_app_id" && -x "$HERE/prepare_airgap_fixture.sh" ]]; then
  "$HERE/prepare_airgap_fixture.sh" --leg ios --app-id "$ios_app_id" \
    --hosted-url "$WANT" --skip-seed >/dev/null
  "$HERE/prepare_airgap_fixture.sh" --activate ios --skip-seed >/dev/null
  note "fixture iOS config regenerated and activated against $WANT"
else
  die "no IOS_APP_ID in fixtures/airgap/acceptance.env — cannot keep the fixture
       consistent with the server, which is the whole invariant here."
fi

# --- 5. stamp it, so a drift between prep and launch is caught -------------------
# base_url is baked into flutter_assets. If the endpoint moves after the fixture
# is built, the IPA silently carries a dead address — which is exactly how a
# 15-minute build was wasted. The harness re-reads this and refuses to launch a
# build made for a different endpoint.
mkdir -p "$(dirname "$STAMP")"
printf '%s\n' "$WANT" > "$STAMP"
note "endpoint stamped: $STAMP"

echo
echo "iOS endpoint ready: $WANT"
echo "REMINDER: base_url is baked into flutter_assets — build AFTER this script."
