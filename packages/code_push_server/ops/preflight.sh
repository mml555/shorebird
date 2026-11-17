#!/usr/bin/env bash
#
# preflight.sh — check that the server image you are about to start accepts
# this deployment's .env, BEFORE the running container is replaced.
#
# Why: the server refuses to boot on a config it rejects (exit 78), and a
# release can add a rule. 2.0.0 made IDP_ISSUER mandatory in production when an
# IdP is configured; `up -d server` then replaced the working container with
# one that crash-looped, taking login, the CLI and device check-ins down with
# it. This runs the new image's own Config.validate against the exact
# environment compose would give it (.env, compose defaults and overrides), in
# a throwaway container that touches no database, object store or port.
#
# It never boots a real server: an image without `--check-config` (older than
# this script) would ignore the flag and start normally, so the binary is
# probed for the flag first and the run is cut off after PREFLIGHT_TIMEOUT
# seconds (default 60). .env is not sourced as shell: compose reads it with
# --env-file, so the checked environment is exactly the one `up -d` uses.
#
# Usage (between pulling/building the new image and `up -d`):
#   ./ops/preflight.sh
#   docker compose -f docker-compose.prod.yaml up -d server   # only if it passed
#
# Exit: 0 config accepted; 1 could not run the check; 78 config rejected (the
# reasons are printed). CPS_IMAGE, COMPOSE_FILE and ENV_FILE apply as for the
# other ops scripts.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"

COMPOSE_FILE="${COMPOSE_FILE:-${ROOT_DIR}/docker-compose.prod.yaml}"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"
TIMEOUT="${PREFLIGHT_TIMEOUT:-60}"
NAME="cps-preflight-$$"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "${COMPOSE_FILE}" ]] || die "no such compose file: ${COMPOSE_FILE}"
[[ -f "${ENV_FILE}" ]]     || die "no .env at ${ENV_FILE} (run ./setup.sh, or set ENV_FILE)"

DC=(docker compose --progress quiet -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}")

# A compose file that does not parse would otherwise fail halfway through `up`.
"${DC[@]}" config -q || die "docker compose could not resolve ${COMPOSE_FILE}"

IMAGE="$("${DC[@]}" config --images | grep -m1 'code-push-server' || true)"
echo "==> Checking config against ${IMAGE:-the server image}"

cleanup() { docker rm -f "${NAME}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Does this image know --check-config? The flag is a string in the compiled
# binary. Nothing is started: grep is the only process, with the server's
# entrypoint replaced.
if ! "${DC[@]}" run --rm --no-deps -T --name "${NAME}-probe" --entrypoint grep server \
     -qa -e '--check-config' /app/bin/server >/dev/null 2>&1; then
  die "this image has no --check-config (it predates it), or it is not present.
   Pull or build the new image first (and check CPS_IMAGE); refusing to run an
   older one, which would boot the real server against the real database."
fi

# --no-deps: no postgres/seaweedfs start. The entrypoint is the server binary,
# which exits after validating. Run in the background so a hang can be cut off.
"${DC[@]}" run --rm --no-deps -T --name "${NAME}" server --check-config &
pid=$!
waited=0
while kill -0 "${pid}" 2>/dev/null; do
  if (( waited >= TIMEOUT )); then
    kill "${pid}" 2>/dev/null || true
    cleanup
    die "the check did not finish in ${TIMEOUT}s and was stopped; nothing was replaced."
  fi
  sleep 1
  waited=$(( waited + 1 ))
done
set +e
wait "${pid}"
status=$?
set -e

if [[ ${status} -eq 78 ]]; then
  echo "==> REJECTED: the new image will not boot with this .env. Fix it, then re-run." >&2
  echo "    The running container has not been touched." >&2
  exit 78
elif [[ ${status} -ne 0 ]]; then
  die "the check itself failed (exit ${status}); is the image present? Pull or build it first."
fi
echo "==> OK: safe to replace the container."
