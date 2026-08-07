#!/usr/bin/env bash
# cspell:words ENVFILE PORTMAP
# prepare_ios_usb_endpoint.sh — make the iOS control-plane endpoint RUN
# configuration, derived from the USB link that exists right now.
#
# THE BUG THIS REPLACES
#
# cps-ios stored PUBLIC_BASE_URL as long-lived server state. The iPhone's USB
# link-local address changes on reconnect, so on 2026-08-07 a warm acceptance
# run built a full IPA, created release 40, and then HUNG uploading artifacts
# to 169.254.189.3 — an address from a previous session — while the Mac was
# actually on 169.254.94.102.
#
# Re-pointing the container at today's address would only reschedule that
# failure. The 169.254 network is inherently reconnect-sensitive and forcing a
# stable assignment would be another fragile rig assumption. So the rule is:
#
#   whatever USB address exists now, prove it works and configure BOTH ends
#   consistently — never "make today's address permanent".
#
# WHY THE ADDRESS AT ALL: the iPhone has no `adb reverse`. It reaches the Mac
# over the USB link, which is an ordinary interface with IPv4 link-local on
# both ends, so localhost is unreachable from the device. One URL has to
# satisfy the Mac (uploading) and the phone (fetching), and only the
# link-local address does.
#
#   prepare_ios_usb_endpoint.sh [--container cps-ios] [--port 18080] [--force]
#
# Idempotent: if the container already advertises the current address and the
# preflight passes, it changes nothing.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
CONTAINER="cps-ios"
PORT=18080
FORCE=0

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container) CONTAINER="${2:?}"; shift 2 ;;
    --port) PORT="${2:?}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '3,31p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v docker >/dev/null || die "docker is not on PATH"
docker inspect "$CONTAINER" >/dev/null 2>&1 || die "no container named $CONTAINER"

# --- 1. the USB link that exists right now --------------------------------------
IFACE="$(ifconfig 2>/dev/null | awk '/^[a-z0-9]+:/{i=substr($1,1,length($1)-1)} /inet 169\.254\./{print i; exit}')"
MAC_IP="$(ifconfig 2>/dev/null | awk '/^[a-z0-9]+:/{i=$1} /inet 169\.254\./{print $2; exit}')"
[[ -n "$MAC_IP" ]] || die "no 169.254.x link-local address found. Is the iPhone attached over USB?
       (A tethered iPhone appears as an ordinary network interface.)"
note "USB interface : ${IFACE:-unknown}"
note "Mac address   : $MAC_IP"

WANT="http://$MAC_IP:$PORT"
HAVE="$(docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
        | awk -F= '/^PUBLIC_BASE_URL=/{print substr($0, index($0,"=")+1)}')"
note "container has : ${HAVE:-<unset>}"
note "run needs     : $WANT"

# --- 2. recreate only if the address moved --------------------------------------
if [[ "$HAVE" == "$WANT" && $FORCE -eq 0 ]]; then
  note "already correct; not recreating"
else
  note "address differs — recreating $CONTAINER with the current one"

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
    || die "recreate failed — the data mount is untouched, so re-running this script is safe"
  note "recreated"
  sleep 3
fi

# --- 3. preflight ----------------------------------------------------------------
# Mac -> control plane.
code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$WANT/" || echo FAIL)"
[[ "$code" == "200" ]] || die "Mac cannot reach $WANT (got $code)"
note "preflight: Mac -> control plane        200"

# Device link. Proving the PHONE can reach the Mac needs code running on the
# phone, which is what the release itself does — so this checks the layer we
# CAN check here: the peer is up and routable over the same USB interface. The
# end-to-end proof is the server-side /patches/check during the run (step 4).
if [[ -n "$IFACE" ]]; then
  # `|| true` is load-bearing: under `set -e` a command substitution whose
  # pipeline finds nothing (grep exits 1) aborts the whole script — which it
  # did, silently skipping the fixture regeneration below and leaving the
  # config pointing at localhost.
  peer="$(arp -a -i "$IFACE" 2>/dev/null | grep -oE '169\.254\.[0-9]+\.[0-9]+' \
          | grep -v "^$MAC_IP$" | head -1 || true)"
  if [[ -n "$peer" ]] && ping -c 2 -t 3 "$peer" >/dev/null 2>&1; then
    note "preflight: device peer $peer          reachable"
  else
    echo "WARN: no reachable 169.254 peer on $IFACE yet." >&2
    echo "      The link often populates only once the phone talks to the Mac;" >&2
    echo "      it is not fatal here, but if the run cannot fetch a patch, this" >&2
    echo "      is the first thing to re-check." >&2
  fi
fi

# --- 4. keep the fixture consistent with the same address ------------------------
if [[ -x "$HERE/prepare_airgap_fixture.sh" ]]; then
  ios_app_id="$(awk -F= '/^IOS_APP_ID=/{print $2}' "$HERE/../fixtures/airgap/acceptance.env" 2>/dev/null | tr -d '[:space:]')"
  if [[ -n "$ios_app_id" ]]; then
    "$HERE/prepare_airgap_fixture.sh" --leg ios --app-id "$ios_app_id" \
      --hosted-url "$WANT" --skip-seed >/dev/null
    "$HERE/prepare_airgap_fixture.sh" --activate ios --skip-seed >/dev/null
    note "fixture iOS config regenerated and activated against $WANT"
  else
    echo "WARN: no IOS_APP_ID in fixtures/airgap/acceptance.env; regenerate the" >&2
    echo "      fixture config yourself with --hosted-url $WANT" >&2
  fi
fi

echo
echo "iOS endpoint ready: $WANT"
echo "REMINDER: base_url is baked into flutter_assets, so the release must be"
echo "built AFTER this script — an older build still carries the old address."
