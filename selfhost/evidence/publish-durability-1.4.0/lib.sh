# shellcheck shell=bash
# Shared by run.sh, kill.sh and pause.sh. Source it; do not run it.
# Sets N, P, C (container), V (volume) from the first two arguments, refusing anything
# that could name another project's container, volume or port.
set -euo pipefail
N=${1:?name}; P=${2:?port}
[[ $N =~ ^[a-z0-9-]+$ ]] || { echo "name must match ^[a-z0-9-]+$" >&2; exit 2; }
[[ $P =~ ^[0-9]+$ ]] || { echo "port must be a number" >&2; exit 2; }
[[ $P != 8090 ]] || { echo "8090 is cps-ios" >&2; exit 2; }
if ss -ltn "sport = :$P" | grep -q LISTEN; then echo "port $P is already in use" >&2; exit 2; fi
C=vanish-repro-$N
V=vanish-repro-$N-data
HOST_IP=${HOST_IP:-10.0.0.41}
DIR=${REPRO_DIR:-$HOME/vanish-repro}
[[ -f $DIR/drive.py && -f $DIR/verify.py ]] || { echo "copy drive.py and verify.py into $DIR first" >&2; exit 2; }
cd "$DIR"
# Fresh start: remove this run's own container and named volume, by exact name.
docker rm -f "$C" >/dev/null 2>&1 || true
docker volume rm "$V" >/dev/null 2>&1 || true

# start_server CPU_AND_MEMORY_ARGS... ; MOUNT is a volume name or a directory under $DIR.
start_server() {
  local mount=${MOUNT:-$V}
  docker run -d --name "$C" -p "$P:8080" "$@" -v "$mount:/data" -e DATA_DIR=/data \
    -e "API_KEY=sb_api_repro_$N" -e "URL_SIGNING_SECRET=$(openssl rand -hex 32)" \
    -e "PUBLIC_BASE_URL=http://$HOST_IP:$P" -e "SHOREBIRD_JWT_ISSUER=http://$HOST_IP:$P" \
    -e RATE_LIMIT_PER_MINUTE=1000000 -e RATE_LIMIT_IP_PER_MINUTE=1000000 \
    -e TRUSTED_PROXIES=127.0.0.1 -e "UPLOAD_METHOD=${UPLOAD_METHOD:-multipart}" \
    ghcr.io/mml555/code-push-server:1.4.0 >/dev/null
  # Wait on this container's own state and port, not on whatever answers on the port.
  for _ in $(seq 1 60); do
    [[ $(docker inspect -f '{{.State.Running}}' "$C") == true ]] || { docker logs "$C" >&2; return 1; }
    curl -sf "localhost:$P/healthz" >/dev/null && return 0
    sleep 1
  done
  return 1
}

# Counts 5xx and unhandled errors in the server log (printed, and checked by hand).
log_summary() {
  echo "5xx in log: $(docker logs "$C" 2>&1 | grep -c -- '-> 5[0-9][0-9]' || true)  unhandled: $(docker logs "$C" 2>&1 | grep -ci 'unhandled request error' || true)"
}

# read_back: copy /data out of the container and verify it.
read_back() {
  rm -rf "db-$N"; mkdir "db-$N"
  docker cp "$C:/data/." "db-$N/"
  python3 verify.py "out-$N.json" "db-$N"
}
