#!/usr/bin/env bash
# cspell:words xcaddy darkweak GOBIN GOTOOLCHAIN fullchain
#
# run_native.sh — run the CDN mirror without Docker.
#
# GitHub's macOS runners have no Docker, and an iOS or macOS build has to run
# on macOS. This runs the same two services as docker-compose.cdn.yaml as plain
# processes:
#
#   artifact_proxy  packages/artifact_proxy, AOT-compiled, on port 8081. It
#                   binds every interface (it has no bind-address setting),
#                   where compose keeps it inside the container network.
#   caddy           this directory's Caddyfile, built with the same plugins as
#                   ./Dockerfile, on the ports docker-compose publishes
#
# Usage:
#   run_native.sh start [--tls] [--sealed] [--state <dir>] [--overlay <dir>] [--map <file>]
#   run_native.sh stop  [--state <dir>]
#
#   --tls       Also serve https on HTTPS_PORT (like docker-compose.cdn.tlslocal.yaml).
#               Run tls/generate.sh first, and tls/trust.sh for the clients.
#   --sealed    Refuse every upstream fetch (like docker-compose.cdn.sealed.yaml).
#   --state     Where the binaries, rewritten config, cache, Caddy's own data,
#               logs and pids go. Default: ./.native (git-ignored).
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

# Pinned so the build is the same on every runner. ./Dockerfile uses the
# caddy:2.11 images with unpinned plugins, so keep the Caddy minor in step and
# expect the plugin versions to differ from a fresh image build.
CADDY_VERSION=v2.11.7
XCADDY_VERSION=v0.4.7
# Oldest Go that can build CADDY_VERSION (its go.mod `go` line). See build_caddy.
CADDY_GO_MIN=1.26.0
CACHE_HANDLER_VERSION=v0.17.0
NUTS_STORAGE_VERSION=v0.0.23

HTTP_PORT="${HTTP_PORT:-8085}"
HTTPS_PORT="${HTTPS_PORT:-8443}"
PROXY_PORT=8081

die() { echo "run_native.sh: $*" >&2; exit 1; }
note() { echo "==> $*"; }

cmd="${1:-}"; shift || true
TLS=0
SEALED=0
STATE="$HERE/.native"
OVERLAY="$HERE/overlay"
MAP="$HERE/experimental_hashes.map"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tls) TLS=1; shift ;;
    --sealed) SEALED=1; shift ;;
    --state) STATE="${2:?--state needs a dir}"; shift 2 ;;
    --overlay) OVERLAY="${2:?--overlay needs a dir}"; shift 2 ;;
    --map) MAP="${2:?--map needs a file}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# True when something accepts TCP connections on 127.0.0.1:<port>.
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# Stops what a pid file names, but only if it is still our binary: a stale pid
# file (a reboot, a long-lived runner) must not kill an unrelated process.
stop() {
  local name pid i
  for name in caddy artifact_proxy; do
    [[ -f "$STATE/$name.pid" ]] || continue
    pid="$(cat "$STATE/$name.pid")"
    rm -f "$STATE/$name.pid"
    [[ "$(ps -p "$pid" -o command= 2>/dev/null || true)" == "$STATE/bin/$name"* ]] || continue
    kill "$pid" 2>/dev/null || continue
    for i in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      [[ "$i" == 20 ]] && kill -9 "$pid" 2>/dev/null
      sleep 0.5
    done
    note "stopped $name ($pid)"
  done
}

# Waits for the process's port to accept connections. A TCP connect, not an
# HTTP request: every path of the mirror goes upstream on a miss, so an HTTP
# probe would make startup depend on reaching GCS. The ports were checked free
# before launch, so the listener is this process; it must still be alive too.
wait_up() {
  local name="$1" port="$2" pid="$3"
  for _ in $(seq 1 60); do
    kill -0 "$pid" 2>/dev/null || { tail -40 "$STATE/$name.log" >&2; die "$name exited"; }
    if port_busy "$port"; then
      sleep 0.5
      kill -0 "$pid" 2>/dev/null || { tail -40 "$STATE/$name.log" >&2; die "$name exited"; }
      return 0
    fi
    sleep 0.5
  done
  tail -40 "$STATE/$name.log" >&2
  die "$name is not listening on port $port"
}

build_caddy() {
  if [[ -n "${CADDY:-}" ]]; then
    cp "$CADDY" "$STATE/bin/caddy"
  elif [[ -x "$STATE/bin/caddy" ]] \
    && [[ "$(cat "$STATE/bin/caddy.stamp" 2>/dev/null)" == "$CADDY_VERSION $CACHE_HANDLER_VERSION $NUTS_STORAGE_VERSION" ]]; then
    note "caddy: reusing $STATE/bin/caddy"
  else
    command -v go >/dev/null || die "go is needed to build Caddy (or set CADDY)"
    note "caddy: building $CADDY_VERSION with cache-handler $CACHE_HANDLER_VERSION, nuts $NUTS_STORAGE_VERSION"
    # Build with the Go that is installed. GOTOOLCHAIN=auto would let go download
    # whatever toolchain a module's go.mod names at build time, so the compiler
    # behind the CDN binary would depend on the network and on the day. Local
    # plus a floor is reproducible and fails with a message instead. The floor is
    # Caddy's own go.mod ("go 1.26.0" at v2.11.7); raise CADDY_GO_MIN with
    # CADDY_VERSION. Set CADDY=<binary> to skip the build entirely.
    export GOTOOLCHAIN=local
    local have; have="$(go env GOVERSION 2>/dev/null)"; have="${have#go}"
    if [[ -z "$have" || "$(printf '%s\n%s\n' "$CADDY_GO_MIN" "${have%%[^0-9.]*}" | sort -V | head -1)" != "$CADDY_GO_MIN" ]]; then
      die "go ${have:-?} is older than the $CADDY_GO_MIN that Caddy $CADDY_VERSION needs. Install a newer Go (GOTOOLCHAIN is pinned to local on purpose), or set CADDY=<a built caddy binary>"
    fi
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
  local src="$REPO/packages/artifact_proxy" bin="$STATE/bin/artifact_proxy"
  if [[ -x "$bin" ]] && [[ -z "$(find "$src" -type f -newer "$bin" -print -quit)" ]]; then
    note "artifact_proxy: reusing $bin"
    return
  fi
  command -v dart >/dev/null || die "dart is needed to build artifact_proxy"
  note "artifact_proxy: compiling"
  rm -rf "$STATE/artifact_proxy"
  cp -R "$src" "$STATE/artifact_proxy"
  # As ./Dockerfile does: resolve the package on its own, outside the workspace.
  echo "resolution: null" > "$STATE/artifact_proxy/pubspec_overrides.yaml"
  (cd "$STATE/artifact_proxy" && dart pub get && dart compile exe bin/server.dart -o "$bin") \
    > "$STATE/build_proxy.log" 2>&1 \
    || { tail -40 "$STATE/build_proxy.log" >&2; die "artifact_proxy did not build"; }
}

write_config() {
  local etc="$STATE/etc" p
  # These paths are substituted into sed replacements and Caddyfile tokens.
  for p in "$STATE" "$OVERLAY"; do
    [[ "$p" =~ [[:space:]\|\&\\] ]] && die "path has a space, |, & or backslash, which the rewrite cannot carry: $p"
  done
  rm -rf "$etc"; mkdir -p "$etc/tls" "$STATE/cache"
  [[ -f "$MAP" ]] || die "no hash map at $MAP"
  cp "$MAP" "$etc/experimental_hashes.map"
  if [[ "$SEALED" == 1 ]]; then
    cp "$HERE/upstream/sealed.caddy" "$etc/upstream_gcs.caddy"
  else
    cp "$HERE/upstream/enabled.caddy" "$etc/upstream_gcs.caddy"
  fi
  if [[ "$TLS" == 1 ]]; then
    [[ -f "$HERE/tls/fullchain.crt" && -f "$HERE/tls/server.key" ]] \
      || die "--tls needs tls/fullchain.crt and tls/server.key; run tls/generate.sh first"
    cp "$HERE/tls/fullchain.crt" "$etc/tls/"
    install -m 600 "$HERE/tls/server.key" "$etc/tls/server.key"
    cp "$HERE/tls/listen-enabled.caddy" "$etc/tls_listen.caddy"
  else
    cp "$HERE/tls/listen-disabled.caddy" "$etc/tls_listen.caddy"
  fi
  local f out
  for f in "$HERE/Caddyfile" "$etc/tls_listen.caddy"; do
    out="$etc/$(basename "$f")"
    sed -e "s|/etc/caddy/|$etc/|g" \
        -e "s|/var/cache/caddy/cdn|$STATE/cache|g" \
        -e "s|^\([[:space:]]*root \* \)/overlay\$|\1$OVERLAY|" \
        -e "s|artifact-proxy:8080|127.0.0.1:$PROXY_PORT|g" \
        -e "s|^http://:8080 {|http://:$HTTP_PORT {|" \
        -e "s|^https://:8443 {|https://:$HTTPS_PORT {|" \
        "$f" > "$out.tmp.$$"
    mv "$out.tmp.$$" "$out"
  done
  # Anything still pointing into the container would fail at request time, not
  # at startup, so refuse here instead. Comments may mention the paths.
  local left=""
  for f in "$etc/Caddyfile" "$etc/tls_listen.caddy" "$etc/upstream_gcs.caddy"; do
    left+="$(sed -e 's/^[[:space:]]*#.*//' "$f" \
      | grep -nE '/etc/caddy|/var/cache/caddy|artifact-proxy:|[[:space:]]/overlay([[:space:]/]|$)' \
      | sed "s|^|$f:|" || true)"
  done
  [[ -z "$left" ]] || { echo "$left" >&2; die "container paths left in the rewritten config (above)"; }
  "$STATE/bin/caddy" validate --config "$etc/Caddyfile" --adapter caddyfile >/dev/null 2>"$STATE/validate.log" \
    || { cat "$STATE/validate.log" >&2; die "Caddy rejected the rewritten config"; }
}

case "$cmd" in
  start)
    mkdir -p "$STATE/bin"
    STATE="$(cd -- "$STATE" && pwd)"
    OVERLAY="$(cd -- "$OVERLAY" 2>/dev/null && pwd)" || die "no overlay dir at $OVERLAY"
    stop
    ports=("$PROXY_PORT" "$HTTP_PORT")
    [[ "$TLS" == 1 ]] && ports+=("$HTTPS_PORT")
    for p in "${ports[@]}"; do
      port_busy "$p" && die "port $p is already in use (another mirror? stop it first)"
    done
    build_caddy
    build_proxy
    write_config

    # From here a failure must not leave half a mirror running.
    trap stop EXIT

    PORT="$PROXY_PORT" MANIFEST_BASE_URL="http://127.0.0.1:$HTTP_PORT/download.shorebird.dev" \
      nohup "$STATE/bin/artifact_proxy" > "$STATE/artifact_proxy.log" 2>&1 < /dev/null &
    echo $! > "$STATE/artifact_proxy.pid"
    wait_up artifact_proxy "$PROXY_PORT" "$(cat "$STATE/artifact_proxy.pid")"

    # XDG_*: Caddy's own data (storage locks, autosave) stays in the state dir.
    XDG_DATA_HOME="$STATE/data" XDG_CONFIG_HOME="$STATE/config" \
      nohup "$STATE/bin/caddy" run --config "$STATE/etc/Caddyfile" --adapter caddyfile \
      > "$STATE/caddy.log" 2>&1 < /dev/null &
    echo $! > "$STATE/caddy.pid"
    wait_up caddy "$HTTP_PORT" "$(cat "$STATE/caddy.pid")"
    [[ "$TLS" == 1 ]] && wait_up caddy "$HTTPS_PORT" "$(cat "$STATE/caddy.pid")"

    trap - EXIT
    note "mirror up: http://localhost:$HTTP_PORT$([[ "$TLS" == 1 ]] && echo " and https://localhost:$HTTPS_PORT")$([[ "$SEALED" == 1 ]] && echo " (sealed)")"
    note "logs: $STATE/caddy.log, $STATE/artifact_proxy.log; stop with: $0 stop --state $STATE"
    ;;
  stop) stop ;;
  *) die "usage: run_native.sh start|stop [options]; see the header" ;;
esac
