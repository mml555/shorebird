#!/usr/bin/env bash
# cspell:words xcaddy darkweak GOBIN fullchain
#
# run_native.sh — run the CDN mirror without Docker.
#
# GitHub's macOS runners have no Docker, and an iOS or macOS build has to run
# on macOS. This runs the same two services as docker-compose.cdn.yaml as plain
# processes:
#
#   artifact_proxy  packages/artifact_proxy, AOT-compiled, on 127.0.0.1:8081
#   caddy           this directory's Caddyfile, built with the same plugins as
#                   ./Dockerfile, on the ports docker-compose publishes
#
# Usage:
#   run_native.sh start [--tls] [--state <dir>] [--overlay <dir>] [--map <file>]
#   run_native.sh stop  [--state <dir>]
#
#   --tls       Also serve https on HTTPS_PORT (like docker-compose.cdn.tlslocal.yaml).
#               Run tls/generate.sh first, and tls/trust.sh for the clients.
#   --state     Where the binaries, rewritten config, cache, logs and pids go.
#               Default: ./.native (git-ignored).
#   --overlay   Experimental engine overlay. Default: ./overlay.
#   --map       <expHash> -> <pinnedHash> table. Default: ./experimental_hashes.map.
#
# Environment:
#   HTTP_PORT   default 8085, the host port docker-compose maps to the container's 8080
#   HTTPS_PORT  default 8443
#   CADDY       an existing Caddy that has cache-handler and nuts storage; skips the build
#
# Needs go (for xcaddy, unless CADDY is set), dart and curl.
#
# The Caddyfile is not forked: a copy is rewritten in the state dir so the
# container paths point into it (/etc/caddy -> <state>/etc, /overlay,
# /var/cache/caddy/cdn -> <state>/cache, artifact-proxy:8080 -> 127.0.0.1:8081).
# start fails if any container path is left over after that.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd -- "$HERE/../.." && pwd)"

# Pinned so the build is the same on every runner. Keep the Caddy minor in
# step with ./Dockerfile's caddy:2.11 images.
CADDY_VERSION=v2.11.7
XCADDY_VERSION=v0.4.7
CACHE_HANDLER_VERSION=v0.17.0
NUTS_STORAGE_VERSION=v0.0.23

HTTP_PORT="${HTTP_PORT:-8085}"
HTTPS_PORT="${HTTPS_PORT:-8443}"
PROXY_PORT=8081

die() { echo "run_native.sh: $*" >&2; exit 1; }
note() { echo "==> $*"; }

cmd="${1:-}"; shift || true
TLS=0
STATE="$HERE/.native"
OVERLAY="$HERE/overlay"
MAP="$HERE/experimental_hashes.map"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tls) TLS=1; shift ;;
    --state) STATE="${2:?--state needs a dir}"; shift 2 ;;
    --overlay) OVERLAY="${2:?--overlay needs a dir}"; shift 2 ;;
    --map) MAP="${2:?--map needs a file}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

stop() {
  local name pid
  for name in caddy artifact_proxy; do
    [[ -f "$STATE/$name.pid" ]] || continue
    pid="$(cat "$STATE/$name.pid")"
    if kill "$pid" 2>/dev/null; then note "stopped $name ($pid)"; fi
    rm -f "$STATE/$name.pid"
  done
}

# Waits for a TCP listener; a fast exit of the process fails at once.
wait_up() {
  local name="$1" url="$2" pid="$3"
  for _ in $(seq 1 60); do
    kill -0 "$pid" 2>/dev/null || { tail -40 "$STATE/$name.log" >&2; die "$name exited"; }
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "$url" || true)" != "000" ]] && return 0
    sleep 0.5
  done
  tail -40 "$STATE/$name.log" >&2
  die "$name did not answer on $url"
}

build_caddy() {
  if [[ -n "${CADDY:-}" ]]; then
    cp "$CADDY" "$STATE/bin/caddy"
  elif [[ -x "$STATE/bin/caddy" ]] \
    && [[ "$(cat "$STATE/bin/caddy.stamp" 2>/dev/null)" == "$CADDY_VERSION $CACHE_HANDLER_VERSION $NUTS_STORAGE_VERSION" ]]; then
    note "caddy: reusing $STATE/bin/caddy"
    return
  else
    command -v go >/dev/null || die "go is needed to build Caddy (or set CADDY)"
    note "caddy: building $CADDY_VERSION with cache-handler $CACHE_HANDLER_VERSION, nuts $NUTS_STORAGE_VERSION"
    GOBIN="$STATE/bin" go install "github.com/caddyserver/xcaddy/cmd/xcaddy@$XCADDY_VERSION"
    "$STATE/bin/xcaddy" build "$CADDY_VERSION" \
      --with "github.com/caddyserver/cache-handler@$CACHE_HANDLER_VERSION" \
      --with "github.com/darkweak/storages/nuts/caddy@$NUTS_STORAGE_VERSION" \
      --output "$STATE/bin/caddy"
    echo "$CADDY_VERSION $CACHE_HANDLER_VERSION $NUTS_STORAGE_VERSION" > "$STATE/bin/caddy.stamp"
  fi
  "$STATE/bin/caddy" list-modules | grep -qx 'http.handlers.cache' \
    || die "$STATE/bin/caddy has no http.handlers.cache module"
}

build_proxy() {
  command -v dart >/dev/null || die "dart is needed to build artifact_proxy"
  note "artifact_proxy: compiling"
  rm -rf "$STATE/artifact_proxy"
  cp -R "$REPO/packages/artifact_proxy" "$STATE/artifact_proxy"
  # As ./Dockerfile does: resolve the package on its own, outside the workspace.
  echo "resolution: null" > "$STATE/artifact_proxy/pubspec_overrides.yaml"
  (cd "$STATE/artifact_proxy" && dart pub get >/dev/null \
    && dart compile exe bin/server.dart -o "$STATE/bin/artifact_proxy" >/dev/null)
}

write_config() {
  local etc="$STATE/etc"
  rm -rf "$etc"; mkdir -p "$etc/tls" "$STATE/cache"
  [[ -d "$OVERLAY" ]] || die "no overlay dir at $OVERLAY"
  [[ -f "$MAP" ]] || die "no hash map at $MAP"
  cp "$MAP" "$etc/experimental_hashes.map"
  cp "$HERE/upstream/enabled.caddy" "$etc/upstream_gcs.caddy"
  if [[ "$TLS" == 1 ]]; then
    [[ -f "$HERE/tls/fullchain.crt" && -f "$HERE/tls/server.key" ]] \
      || die "--tls needs tls/fullchain.crt and tls/server.key; run tls/generate.sh first"
    cp "$HERE/tls/fullchain.crt" "$HERE/tls/server.key" "$etc/tls/"
    cp "$HERE/tls/listen-enabled.caddy" "$etc/tls_listen.caddy"
  else
    cp "$HERE/tls/listen-disabled.caddy" "$etc/tls_listen.caddy"
  fi
  local f
  for f in "$HERE/Caddyfile" "$etc/tls_listen.caddy"; do
    sed -e "s|/etc/caddy/|$etc/|g" \
        -e "s|/var/cache/caddy/cdn|$STATE/cache|g" \
        -e "s|^\([[:space:]]*root \* \)/overlay\$|\1$OVERLAY|" \
        -e "s|artifact-proxy:8080|127.0.0.1:$PROXY_PORT|g" \
        -e "s|^http://:8080 {|http://:$HTTP_PORT {|" \
        -e "s|^https://:8443 {|https://:$HTTPS_PORT {|" \
        "$f" > "$f.tmp.$$"
    mv "$f.tmp.$$" "$etc/$(basename "$f")"
  done
  # Anything still pointing into the container would fail at request time, not
  # at startup, so refuse here instead. Comments may mention the paths.
  if grep -vE '^[[:space:]]*#' "$etc/Caddyfile" "$etc/tls_listen.caddy" \
    | grep -nE '/etc/caddy|/var/cache/caddy|artifact-proxy:|[[:space:]]/overlay([[:space:]]|$)'; then
    die "container paths left in the rewritten config (above)"
  fi
  "$STATE/bin/caddy" validate --config "$etc/Caddyfile" --adapter caddyfile >/dev/null 2>"$STATE/validate.log" \
    || { cat "$STATE/validate.log" >&2; die "Caddy rejected the rewritten config"; }
}

case "$cmd" in
  start)
    mkdir -p "$STATE/bin"
    STATE="$(cd -- "$STATE" && pwd)"
    OVERLAY="$(cd -- "$OVERLAY" 2>/dev/null && pwd)" || die "no overlay dir"
    stop
    build_caddy
    build_proxy
    write_config

    PORT="$PROXY_PORT" MANIFEST_BASE_URL="http://127.0.0.1:$HTTP_PORT/download.shorebird.dev" \
      nohup "$STATE/bin/artifact_proxy" > "$STATE/artifact_proxy.log" 2>&1 < /dev/null &
    echo $! > "$STATE/artifact_proxy.pid"
    wait_up artifact_proxy "http://127.0.0.1:$PROXY_PORT/" "$(cat "$STATE/artifact_proxy.pid")"

    nohup "$STATE/bin/caddy" run --config "$STATE/etc/Caddyfile" --adapter caddyfile \
      > "$STATE/caddy.log" 2>&1 < /dev/null &
    echo $! > "$STATE/caddy.pid"
    wait_up caddy "http://127.0.0.1:$HTTP_PORT/" "$(cat "$STATE/caddy.pid")"

    note "mirror up: http://localhost:$HTTP_PORT$([[ "$TLS" == 1 ]] && echo " and https://localhost:$HTTPS_PORT")"
    note "logs: $STATE/caddy.log, $STATE/artifact_proxy.log; stop with: $0 stop --state $STATE"
    ;;
  stop) stop ;;
  *) die "usage: run_native.sh start|stop [options]; see the header" ;;
esac
